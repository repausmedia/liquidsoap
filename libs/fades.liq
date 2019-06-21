# Make a fade function based on a source's clock.
# @category Math
# @param ~type Fade shape. One of: "sin", "exp", "log", "lin"
# @param ~start Start value.
# @param ~stop Stop value.
# @param ~duration Duration in seconds.
# @param ~on_done Function to execute when the fade is finished
def mkfade(~type="lin",~start=0.,~stop=1.,~duration=3.,~on_done={()},s) =
  log = log(label="mkfade")

  # Shape functions must map 0. -> 0. and 1. -> 1.
  pi = acos(-1.)
  def sin_shape(x) =
    (1. + sin((x-0.5)*pi))/2.
  end

  curve = 2.
  m = exp(curve-1.) - exp(-1.)
  def exp_shape(x) =
    (exp((curve*x)-1.) - exp(-1.))/m
  end

  curve = 10.
  m = log_e(1.+curve)
  def log_shape(x) =
    log_e(1.+10.*x)/m
  end

  def lin_shape(x) =
    x
  end

  shape =
    if type == "sin" then
      sin_shape
    elsif type == "exp" then
      exp_shape
    elsif type == "log" then
      log_shape
    elsif type == "lin" then
      lin_shape
    else 
      log("Invalid type #{type}, using \"lin\"")
      lin_shape
    end

  start_time = source.time(s)
  def fade() =
    t = source.time(s) - start_time
    if t >= duration then
      on_done ()
      stop
    else
      if start <= stop then
        start + shape(t/duration)*(stop-start)
      else
        stop + shape(1.-t/duration)*(start-stop)
      end
    end
  end

  fade
end

# Fade the end of tracks.
# @category Source / Sound Processing
# @param ~id Force the value of the source ID.
# @param ~duration Duration of the fading. This value can be set on a per-file basis using the metadata field passed as override.
# @param ~override_duration Metadata field which, if present and containing a float, overrides the 'duration' parameter for current track.
# @param ~override_type Metadata field which, if present and correct, overrides the 'type' parameter for current track.
# @param ~type Fader shape (lin|sin|log|exp): linear, sinusoidal, logarithmic or exponential.
def fade.out(~id="fade.out",~duration=3.,
             ~override_duration="liq_fade_out",
             ~override_type="liq_fade_type",
             ~type="lin",s) =
  log = log(label=source.id(s),level=4)
  fn = ref (fun () -> 1.)
  type = ref type
  duration = ref duration
  start_time = ref (-1.)

  def start_fade(d,_) =
    log("Fading out with #{d}s remaining..")
    start_time := source.time(s)
    duration = if d < !duration then d else !duration end
    fn := mkfade(start=1.,stop=0.,type=!type,duration=duration,s)
  end

  def apply() =
    fn = !fn
    fn()
  end

  def stop_fade(_) =
    fn := fun () -> 1.
  end

  def update_fade(m) =
    if m[override_duration] != "" then
      duration := float_of_string(default=!duration,m[override_duration])
      log("New fade duration: #{!duration}")
    end

    if m[override_type] != "" then
      type := m[override_type]
      log("New fade type: #{!type}")
    end
  end

  s = on_metadata(update_fade,s)
  delay = fun () -> !duration
  s = on_end(delay=delay,start_fade,s)
  s = on_track(stop_fade,s)
  amplify(id=id,override="",apply,s)
end

# Fade when the metadata trigger is received and then skip.
# @category Source / Sound Processing
# @param ~id Force the value of the source ID.
# @param ~duration Duration of the fading. This value can be set on a per-file basis using the metadata field passed as override.
# @param ~override_duration Metadata field which, if present and containing a float, overrides the 'duration' parameter for current track.
# @param ~override_type Metadata field which, if present and correct, overrides the 'type' parameter for current track.
# @param ~type Fader shape (lin|sin|log|exp): linear, sinusoidal, logarithmic or exponential.
def fade.skip(~id="fade.skip",~duration=5.,
             ~override_duration="liq_fade_skip",
             ~override_type="liq_fade_skip",
             ~override_skip="liq_skip_meta",
             ~type="lin",s) =
  log = log(label=source.id(s),level=4)
  fn = ref (fun () -> 1.)
  type = ref type
  duration = ref duration  

  def apply() =
    fn = !fn
    fn()
  end

  def stop_fade(_) =
    fn := fun () -> 1.
  end

  def skip()
    log("Fade finished executing. Calling skip now") 
    source.skip(s);
  end

  def update_fade(m) = 
    if m[override_skip] == "true" then
      remaining = source.remaining(s)
      duration = if remaining < !duration then remaining else !duration end  
      log("Skip fade executed for: #{duration}s")      
      fn := mkfade(start=1.,stop=0.,type=!type,duration=duration, on_done=skip,s)       
    end

    if m[override_duration] != "" then
      duration := float_of_string(default=!duration,m[override_duration])
      log("New fade duration: #{!duration}")
    end

    if m[override_type] != "" then
      type := m[override_type]
      log("New fade type: #{!type}")
    end
  end

  s = on_metadata(update_fade,s)  
  s = on_track(stop_fade,s)
  amplify(id=id,override="",apply,s)
end

# Fade a stream to silence.
# @category Source / Sound Processing
# @param ~id Force the value of the source ID.
# @param ~duration Duration of the fading. This value can be set on a per-file basis using the metadata field passed as override.
# @param ~override_duration Metadata field which, if present and containing a float, overrides the 'duration' parameter for current track.
# @param ~override_type Metadata field which, if present and correct, overrides the 'type' parameter for current track.
# @param ~type Fader shape (lin|sin|log|exp): linear, sinusoidal, logarithmic or exponential.
def fade.final(~id="fade.out",~duration=3.,
             ~override_duration="liq_fade_out",
             ~override_type="liq_fade_type",
             ~type="lin",s) =
  max_duration(id=id,duration,
    fade.out(duration=duration,override_duration=override_duration,
             override_type=override_type,type=type,s))
end


# Fade the beginning of tracks.
# @category Source / Sound Processing
# @param ~id Force the value of the source ID.
# @param ~duration Duration of the fading. This value can be set on a per-file basis using the metadata field passed as override.
# @param ~override_duration Metadata field which, if present and containing a float, overrides the 'duration' parameter for current track.
# @param ~override_type Metadata field which, if present and correct, overrides the 'type' parameter for current track.
# @param ~type Fader shape (lin|sin|log|exp): linear, sinusoidal, logarithmic or exponential.
def fade.in(~id="fade.in",~duration=3.,
            ~override_duration="liq_fade_in",
            ~override_type="liq_fade_type",
            ~type="lin",s) =
  log = log(label=source.id(s),level=4)
  fn = ref (fun () -> 0.)
  duration = ref duration
  type = ref type

  def apply() =
    fn = !fn
    fn()
  end

  def start_fade(_) =
    log("Fading in..")
    fn := mkfade(start=0.,stop=1.,type=!type,duration=!duration,s)
  end

  def update_fade(m) =
    if m[override_duration] != "" then
      duration := float_of_string(default=!duration,m[override_duration])
      log("New fade duration: #{!duration}")
    end

    if m[override_type] != "" then
      type := m[override_type]
      log("New fade type: #{!type}")
    end
  end

  s = on_track(start_fade,s)
  s = on_metadata(update_fade,s)

  amplify(id=id,override="",apply,s)
end

# Fade the beginning of a stream.
# @category Source / Sound Processing
# @param ~id Force the value of the source ID.
# @param ~duration Duration of the fading. This value can be set on a per-file basis using the metadata field passed as override.
# @param ~override_duration Metadata field which, if present and containing a float, overrides the 'duration' parameter for current track.
# @param ~override_type Metadata field which, if present and correct, overrides the 'type' parameter for current track.
# @param ~type Fader shape (lin|sin|log|exp): linear, sinusoidal, logarithmic or exponential.
def fade.initial(~id="fade.in",~duration=3.,
            ~override_duration="liq_fade_initial",
            ~override_type="liq_fade_type",
            ~type="lin",s) =
  map_first_track(id=id,
    fade.in(duration=duration,override_duration=override_duration,
            override_type=override_type,type=type),s)
end

# Crossfade between tracks, taking the respective volume levels into account in
# the choice of the transition.
# @category Source / Track Processing
# @param ~start_next   Crossing duration, if any.
# @param ~override_duration \
#                      Metadata field which, if present and containing a \
#                      float, overrides the 'duration' parameter for current \
#                      track. 
# @param ~fade_in      Fade-in duration, if any.
# @param ~fade_out     Fade-out duration, if any.
# @param ~width        Width of the volume analysis window.
# @param ~conservative Always prepare for a premature end-of-track.
# @param ~default      Transition used when no rule applies \
#                      (default: sequence).
# @param ~high         Value, in dB, for loud sound level.
# @param ~medium       Value, in dB, for medium sound level.
# @param ~margin       Margin to detect sources that have too different \
#                      sound level for crossing.
# @param s             The input source.
def crossfade(~start_next=5.,~override_duration="liq_cross_duration",
              ~fade_in=3.,~fade_out=3.,
              ~default=(fun (a,b) -> sequence([a, b])),
              ~high=-15., ~medium=-32., ~margin=4.,
              ~width=2.,~conservative=true,s)
  fade.out = fade.out(type="sin",duration=fade_out)
  fade.in  = fade.in(type="sin",duration=fade_in)
  add = fun (a,b) -> add(normalize=false,[b, a])
  log = log(label="crossfade")

  def transition(a,b,ma,mb,sa,sb)

    list.iter(fun(x)-> log(level=4,"Before: #{x}"),ma)
    list.iter(fun(x)-> log(level=4,"After : #{x}"),mb)

    if
      # If A and B are not too loud and close, fully cross-fade them.
      a <= medium and b <= medium and abs(a - b) <= margin
    then
      log("Old <= medium, new <= medium and |old-new| <= margin.")
      log("Old and new source are not too loud and close.")
      log("Transition: crossed, fade-in, fade-out.")
      add(fade.out(sa),fade.in(sb))

    elsif
      # If B is significantly louder than A, only fade-out A.
      # We don't want to fade almost silent things, ask for >medium.
      b >= a + margin and a >= medium and b <= high
    then
      log("new >= old + margin, old >= medium and new <= high.")
      log("New source is significantly louder than old one.")
      log("Transition: crossed, fade-out.")
      add(fade.out(sa),sb)

    elsif
      # Opposite as the previous one.
      a >= b + margin and b >= medium and a <= high
    then
      log("old >= new + margin, new >= medium and old <= high")
      log("Old source is significantly louder than new one.")
      log("Transition: crossed, fade-in.")
      add(sa,fade.in(sb))

    elsif
      # Do not fade if it's already very low.
      b >= a + margin and a <= medium and b <= high
    then
      log("new >= old + margin, old <= medium and new <= high.")
      log("Do not fade if it's already very low.")
      log("Transition: crossed, no fade.")
      add(sa,sb)

    # What to do with a loud end and a quiet beginning ?
    # A good idea is to use a jingle to separate the two tracks,
    # but that's another story.

    else
      # Otherwise, A and B are just too loud to overlap nicely, or the
      # difference between them is too large and overlapping would completely
      # mask one of them.
      log("No transition: using default.")
      default(sa, sb)
    end
  end

  cross(width=width, duration=start_next, conservative=conservative,
        transition,s)
end

# Mixes two streams, with faded transitions between the state when only the
# normal stream is available and when the special stream gets added on top of
# it.
# @category Source / Track Processing
# @param ~delay   Delay before starting the special source.
# @param ~p       Portion of amplitude of the normal source in the mix.
# @param ~normal  The normal source, which could be called the carrier too.
# @param ~special The special source.
def smooth_add(~delay=0.5,~p=float_getter(0.2),~normal,~special)
  p = to_float_getter(p)
  last_p = ref p()

  def c(fn,s) =
    def v() =
      fn = !fn
      fn()
    end
    amplify(override="",v,s)
  end

  special_volume = ref fun () -> 0.
  special = c(special_volume,special)

  normal_volume = ref fun () -> 1.
  normal = c(normal_volume,normal)

  def to_special(b,special) =
    last_p := p()
    q = 1. - !last_p
    normal_volume := mkfade(start=1.,stop=!last_p,normal)
    special_volume := mkfade(stop=q,special)
    special
  end

  def to_blank(special,b)
    normal_volume := mkfade(start=!last_p,normal)
    special_volume := mkfade(start=1.-!last_p,special)
    sequence([special,b])
  end

  special = fallback(track_sensitive=false,
               transitions=[to_special,to_blank],
               [special,blank()])

  add(normalize=false,[normal,special])
end