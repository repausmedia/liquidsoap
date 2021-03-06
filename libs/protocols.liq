register(name="Protocol Settings","protocol",())

register(name="Replay_gain protocol settings","protocol.replay_gain",())
register(name="Replay_gain path","protocol.replay_gain.path","#{configure.bindir}/extract-replaygain")

# Register the replaygain protocol.
# @flag hidden
def replaygain_protocol(~rlog,~maxtime,arg)
 delay = maxtime - time()
 # The extraction program
 extract_replaygain =
   get(default="#{configure.bindir}/extract-replaygain","protocol.replay_gain.path")
 ret = exec_replaygain(delay=delay,extract_replaygain=extract_replaygain,arg)
 if ret != "" then
  ["annotate:replay_gain=\"#{ret}\":#{arg}"]
 else
  [arg]
 end
end
add_protocol("replay_gain", replaygain_protocol,
             syntax="replay_gain:uri",
             doc="Compute replaygain value using the extract-replaygain script. \
                  Adds returned value as `\"replay_gain\"` metadata")

register(name="Process protocol settings","protocol.process",())
register(name="Process Environment",
         descr="List of environment variables \
                passed down to the executed process.",
         "protocol.process.env",
         [])
register(name="Inherit Environment",
         descr="Inherit calling process's environment when `env` parameter is empty.",
         "protocol.process.inherit_env",
         true)

# Register the process protocol. Syntax:
# process:<output ext>,<cmd>:uri where <cmd> is interpolated with:
# [("input",<input file>),("output",<output file>),("colon",":")]
# See say: protocol for an example.
# @flag hidden
def process_protocol(~rlog,~maxtime,arg)
  log.info("Processing #{arg}")

  x = string.split(separator=":",arg)
  uri = string.concat(separator=":",list.tl(x))
  x = string.split(separator=",",list.hd(default="",x))
  extname = list.hd(default="liq",x)
  cmd = string.concat(separator=",",list.tl(x))

  output = file.temp("liq-process", ".#{extname}")

  def resolve(input) =
    cmd = cmd % [("input",string.quote(input)),
                 ("output",string.quote(output)),
                 ("colon",":")]

    log.info("Executing #{cmd}")

    env_vars = get(default=[],"protocol.process.env")
    env = environment()
    def get_env(k) = (k,env[k]) end
    env = list.map(get_env,env_vars)
    inherit_env = get(default=true,"protocol.process.inherit_env")

    delay = maxtime - time()
    p = process.run(timeout=delay,env=env,inherit_env=inherit_env,cmd)
    if "exit" == p.status then
      [output]
    else
      log.important("Failed to execute #{cmd}: #{p.status}")
      log.info("Standard output:\n#{p.stdout}")
      log.info("Error output:\n#{p.stderr}")
      log.info("Removing #{output}.")
      file.remove(output)
      []
    end
  end

  if uri == "" then
    resolve("")
  else
    r = request.create(uri)
    delay = maxtime - time()
    if request.resolve(timeout=delay,r) then
      res = resolve(request.filename(r))
      request.destroy(r)
      res
    else
      log(level=3,"Failed to resolve #{uri}")
      []
    end
  end
end
add_protocol(temporary=true, "process", process_protocol,
             doc="Resolve a request using an arbitrary process. \
                  `<cmd>` is interpolated with: \
                  `[(\"input\",<input>),(\"output\",<output>),\
                  (\"colon\",\":\")]`. `uri` is an optional child request, \
                  `<output>` is the name of a fresh temporary file and has \
                  extension `.<extname>`. `<input>` is an optional input \
                  file name as returned while resolving `uri`.",
             syntax="process:<extname>,<cmd>[:uri]")

# Create a process: uri, replacing `:` with `$(colon)`
# @category Liquidsoap
# @param cmd Command line to execute
# @param ~extname Output file extension (with no leading '.')
# @param ~uri Input uri
def process_uri(~extname,~uri="",cmd) =
  cmd = string.replace(pattern=":",fun (_) -> "$(colon)",cmd)
  uri = if uri != "" then ":#{uri}" else "" end
  "process:#{extname},#{cmd}#{uri}"
end

register(name="External download protocol","protocol.external",true)
register(name="Path to curl","protocol.external.curl","curl")
register(name="External protocols","protocol.external.protocols",["http","https","ftp"])

# Resolve download protocols using curl
# @flag hidden
def download_protocol(proto,~rlog,~maxtime,arg) =
  curl = get(default="curl","protocol.external.curl")
  uri = "#{proto}:#{arg}"

  log = log(label="procol.external")

  def log(~level,s) =
    rlog(s)
    log(level=level,s)
  end

  env_vars = get(default=[],"protocol.process.env")
  env = environment()
  def get_env(k) =
    (k,env[k])
  end
  env = list.map(get_env,env_vars)
  inherit_env = get(default=true,"protocol.process.inherit_env")

  timeout = maxtime - time()

  # First define using curl.
  def get_mime() =
    cmd = "#{curl} -sLI -X HEAD #{string.quote(uri)} | grep -i '^content-type' | tail -n 1 | cut -d':' -f 2 | cut -d';' -f 1"
    log(level=4,"Running #{cmd}")
    p = process.run(timeout=timeout,env=env,inherit_env=inherit_env,cmd)
    if "exit" != p.status or p.status.code != 0 then
      log(level=3,"Failed to fetch mime-type for #{uri} via curl.")
      log(level=4,"Process return status: #{p.status.code}")
      ""
    else
      lines = string.split(separator="\\n", p.stdout)
      string.case(lower=true,string.trim(list.hd(default="",lines)))
    end
  end

  def head_mime(~name, ret) =
    def get_mime() =
      if 200 <= ret.status_code and ret.status_code < 300 then
        ret.headers["content-type"]
      else
        log(level=3,"Failed to fetch mime-type for #{uri}.")
        log(level=4,"Request response: #{ret}")
        ""
      end
    end
    get_mime
  end

  sub = string.sub(uri,start=0,length=5)

%ifdef https.head
  get_mime =
    if sub == "https" then
      log(level=4,"Fetching https head for #{uri}")
      head_mime(name="https",https.head(timeout=timeout,uri))
    else
      get_mime
    end
%endif

  get_mime =
    if sub != "https" then
      log(level=4,"Fetching http head for #{uri}")
      head_mime(name="http",http.head(timeout=timeout,uri))
    else
      get_mime
    end

  mime = get_mime()

  extname =
    if list.mem(mime, ["audio/mpeg", "audio/mp3"]) then
      "mp3"
    elsif list.mem(mime,["application/ogg", "application/x-ogg",
                         "audio/x-ogg", "audio/ogg", "video/ogg"]) then
      "ogg"
    elsif list.mem(mime, ["audio/flac", "audio/x-flac"]) then
      "flac"
    elsif list.mem(mime,["audio/mp4", "application/mp4"]) then
      "mp4"
    elsif list.mem(mime,["audio/vnd.wave", "audio/wav",
                         "audio/wave", "audio/x-wav"]) then
      "wav"
    else
      log(level=3,"No known file extension for mime: #{mime}")
      "osb"
    end
  [process_uri(extname=extname,"#{curl} -sL #{string.quote(uri)} -o $(output)")]
end

# Register download protocol
# @flag hidden
def add_download_protocol(proto) =
  add_protocol(syntax="#{proto}://...",doc="Download files using curl",proto,download_protocol(proto))
end
if get(default=true,"protocol.external") then
  list.iter(add_download_protocol,get(default=["http","https","ftp"],"protocol.external.protocols"))
end

register(name="Youtube_dl protocol settings","protocol.youtube-dl",())
register(name="Youtube-dl path","protocol.youtube-dl.path","youtube-dl")

# Register the youtube-dl protocol, using youtube-dl.
# Syntax: youtube-dl:<ID>
# @flag hidden
def youtube_dl_protocol(~rlog,~maxtime,arg)
  binary = get(default="youtube-dl","protocol.youtube-dl.path")

  log = log(label="protocol.youtube-dl")

  def log(~level,s) =
    rlog(s)
    log(level=level,s)
  end

  delay = maxtime - time()
  cmd = "#{binary} --get-title --get-filename -- #{string.quote(arg)}"
  log(level=4,"Executing #{cmd}")
  x = process.read.lines(timeout=delay,cmd)

  x =
    if list.length(x) >= 2 then
      x
    else
      ["",".osb"]
    end

  title = list.hd(default="",x)
  ext   = file.extension(leading_dot=false,list.nth(default="",x,1))

  cmd   = "rm -f $(output) && #{binary} -q -f best --no-playlist -o $(output) -- #{string.quote(arg)}"
  process = process_uri(extname=ext,cmd)

  if title != "" then
    ["annotate:title=#{string.quote(title)}:#{process}"]
  else
    [process]
  end
end
add_protocol("youtube-dl", youtube_dl_protocol,
              doc="Resolve a request using youtube-dl.",
              syntax="youtube-dl:uri")

# Register the youtube-pl protocol.
# Syntax: youtube-pl:<ID>
# @flag hidden
def youtube_pl_protocol(~rlog,~maxtime,arg)
  tmp = file.temp("youtube-pl","")
  ignore(file.write(data="youtube-pl:#{arg}",tmp))
  [tmp]
end
add_protocol("youtube-pl", youtube_pl_protocol,
              doc="Resolve a request as a youtube playlist using youtube-dl.",
              temporary=true,syntax="youtube-pl:uri") 

# Register tmp
# @flag hidden
def tmp_protocol(~rlog,~maxtime,arg) =
  [arg]
end
add_protocol("tmp",tmp_protocol,
             doc="Mark the given uri as temporary. Useful when chaining protocols",
             temporary=true,syntax="tmp:uri")

register(name="ffmpeg protocol settings","protocol.ffmpeg",())
register(name="Path to ffmpeg","protocol.ffmpeg.path","ffmpeg")
register(name="Number of channels","protocol.ffmpeg.channels",2)
register(name="Extract metadata","protocol.ffmpeg.metadata",true)
register(name="Adjust replaygain","protocol.ffmpeg.replaygain",false)

# Register ffmpeg
# @flag hidden
def ffmpeg_protocol(~rlog,~maxtime,arg) =
  ffmpeg   = get(default="ffmpeg","protocol.ffmpeg.path")
  channels = get(default=2,"protocol.ffmpeg.channels")
  metadata = get(default=true,"protocol.ffmpeg.metadata")
  replaygain = get(default=false,"protocol.ffmpeg.replaygain")

  log = log(label="protocol.ffmpeg")

  def log(~level,s) =
    rlog(s)
    log(level=level,s)
  end

  def annotate(m) =
    def f(x) =
      let (key,value) = x
      "#{key}=#{string.quote(value)}"
    end
    m = string.concat(separator=",",list.map(f,m))
    if string.length(m) > 0 then
      "annotate:#{m}:"
    else
      ""
    end
  end

  def parse_metadata(file) =
    cmd = "#{ffmpeg} -i #{string.quote(file)} -f ffmetadata - 2>/dev/null | grep -v '^;'"
    delay = maxtime - time()
    log(level=4,"Executing #{cmd}")
    lines = process.read.lines(timeout=delay,cmd)
    def f(cur,line) =
      m = string.split(separator="=",line)
      if list.length(m) >= 2 then
        key = list.hd(default="",m)
        value = string.concat(separator="=",list.tl(m))
        list.add((key,value),cur)
      else
        cur
      end
    end
    list.fold(f,[],lines)
  end

  def replaygain_filter(file) =
    if replaygain then
      # The extraction program
      extract_replaygain =
        get(default="#{configure.libdir}/extract-replaygain","protocol.replay_gain.path")
      delay = maxtime - time()
      ret = exec_replaygain(delay=delay,extract_replaygain=extract_replaygain,file)
      if ret != "" then
        "-af \"volume=#{ret}\""
      else
        ""
      end
    else
      ""
    end
  end

  def cue_points(m) =
    cue_in = float_of_string(default=0., list.assoc(default="0.","liq_cue_in",m))
    cue_out = float_of_string(default=0., list.assoc(default="","liq_cue_out",m))

    args =
      if cue_in > 0. then
        "-ss #{cue_in}"
      else
        ""
      end

    if cue_out > cue_in then
      "#{args} -t #{cue_out-cue_in}"
    else
      args
    end
  end

  def fades(r) =
    m = request.metadata(r)

    fade_type = list.assoc(default="","liq_fade_type",m)
    fade_in = list.assoc(default="","liq_fade_in",m)
    cue_in = list.assoc(default="","liq_cue_in",m)
    fade_out = list.assoc(default="","liq_fade_out",m)
    cue_out = list.assoc(default="","liq_cue_out",m)

    curve =
      if fade_type == "lin" then
        ":curve=tri"
      elsif fade_type == "sin" then
        ":curve=qsin"
      elsif fade_type == "log" then
        ":curve=log"
      elsif fade_type == "exp" then
        ":curve=exp"
      else
        ""
      end
      

    args =
      if fade_in != "" then
        fade_in = float_of_string(default=0.,fade_in)
        start_time =
          if cue_in != "" then
            float_of_string(default=0.,cue_in)
          else
            0.
        end
        if fade_in > 0. then
          ["afade=in:st=#{start_time}:d=#{fade_in}#{curve}"]
        else
          []
        end
      else
        []
      end

    args =
      if fade_out != "" then
        fade_out = float_of_string(default=0.,fade_out)
        end_time =
          if cue_out != "" then
            float_of_string(default=0.,cue_out)
          else
            request.duration(request.filename(r))
          end
        if fade_out > 0. then
          list.append(args,["afade=out:st=#{end_time-fade_out}:d=#{fade_out}#{curve}"])
        else
          args
        end
      else
        args
      end

    if list.length(args) > 0 then
      args = string.concat(separator=",",args)
      "-af #{args}"
    else
      ""
    end
  end

  r = request.create(arg)
  delay = maxtime - time()
  if request.resolve(timeout=delay,r) then
    filename = request.filename(r)
    m = request.metadata(r)

    m = if metadata then
      list.append(m,parse_metadata(filename))
    else
      m
    end

    annotate = annotate(m)
    request.destroy(r)

    # Now parse the audio
    wav = file.temp("liq-process", ".wav")

    cue_points = cue_points(request.metadata(r))
    fades = fades(r)
    replaygain_filter = replaygain_filter(filename)

    cmd = "#{ffmpeg} -y -i $(input) -ac #{channels} #{cue_points} #{fades} #{replaygain_filter} #{string.quote(wav)}"

    uri = process_uri(extname="wav",uri=filename,cmd)

    wav_r = request.create(uri)
    delay = maxtime - time()
    if request.resolve(timeout=delay,wav_r) then
      request.destroy(wav_r)
      ["#{annotate}tmp:#{wav}"]
    else
      log(level=3,"Failed to resolve #{uri}")
      []
    end
  else
    log(level=3,"Failed to resolve #{arg}")
    []
  end
end
add_protocol("ffmpeg",ffmpeg_protocol,
             doc="Decode any file to wave using ffmpeg",
             syntax="ffmpeg:uri")

# Register stereo protocol which converts a file to stereo (currently decodes as
# wav).
# @flag hidden
def stereo_protocol(~rlog, ~maxtime, arg)
  file = file.temp("liq-stereo", ".wav")
  source.dump(%wav, file, audio_to_stereo(once(single(arg))))
  [file]
end
add_protocol(static=true, temporary=true, "stereo", stereo_protocol, doc="Convert a file to stereo (currently decodes to wav).", syntax="stereo:<uri>")

register(name="Text2wave protocol settings","protocol.text2wave",())
register(name="Text2wave path","protocol.text2wave.path","text2wave")

# Register the text2wave: protocol using text2wav
# @flag hidden
def text2wave_protocol(~rlog,~maxtime,arg) =
  binary = get(default="text2wave", "protocol.text2wave.path")
  [process_uri(extname="wav", "echo #{string.quote(arg)} | #{binary} -scale 1.9 > $(output)")]
end
add_protocol(static=true,"text2wave",text2wave_protocol,
             doc="Generate speech synthesis using text2wave. Result may be mono.",
             syntax="text2wave:Text to read")

register(name="gTTS protocol settings", "protocol.gtts",())
register(name="gtts-cli binary path", "protocol.gtts.path", "gtts-cli")

# Register the gtts: protocol using gtts
# @flag hidden
def gtts_protocol(~rlog,~maxtime,arg) =
  binary = get(default="gtts-cli","protocol.gtts.path")
  [process_uri(extname="mp3","#{binary} -o $(output) #{string.quote(arg)}")]
end
add_protocol(static=true,"gtts",gtts_protocol,
             doc="Generate speech synthesis using Google translate's text-to-speech API. This requires the `gtts-cli` binary.  Result may be mono.",
             syntax="gtts:Text to read")

# Register the legacy say: protocol using text2wave and sox
# @flag hidden
def say_protocol(~rlog,~maxtime,arg) =
  ["stereo:gtts:#{arg}", "stereo:text2wave:#{arg}"]
end
add_protocol(static=true,"say",say_protocol,
             doc="Generate speech synthesis using text2wave and sox. Result is always stereo.",
             syntax="say:Text to read")

register(name="AWS protocols settings","protocol.aws",())
register(name="Profile",descr="Use a specific profile from your credential file.",
         "protocol.aws.profile","")
register(name="Endpoint URL",descr="Alternative endpoint URL (useful for other S3 implementations).",
         "protocol.aws.endpoint","")
register(name="Region",descr="AWS Region",
         "protocol.aws.region","")
register(name="Binary",descr="Path to aws CLI binary",
         "protocol.aws.path","aws")
register(name="Polly protocol settings","protocol.aws.polly",())
register(name="Format",descr="Output format",
         "protocol.aws.polly.format","mp3")
register(name="Voice",descr="Voice ID",
         "protocol.aws.polly.voice","Joanna")

# Build a aws base call
# @flag hidden
def aws_base() =
  aws = get(default="aws","protocol.aws.path")

  region = get(default="","protocol.aws.region")

  aws =
    if region !="" then
      "#{aws} --region #{region}"
    else
      aws
    end

  endpoint = get(default="","protocol.aws.endpoint")

  aws =
    if endpoint !="" then
      "#{aws} --endpoint-url #{string.quote(endpoint)}"
    else
      aws
    end

  profile = get(default="","protocol.aws.profile")

  if profile !="" then
    "#{aws} --profile #{string.quote(profile)}"
  else
    aws
  end
end

# Register the s3:// protocol 
# @flag hidden
def s3_protocol(~rlog,~maxtime,arg) =
  extname = file.extension(leading_dot=false,dir_sep="/",arg)
  [process_uri(extname=extname,"#{aws_base()} s3 cp s3:#{arg} $(output)")]
end
add_protocol("s3",s3_protocol,doc="Fetch files from s3 using the AWS CLI",
             syntax="s3://uri")

# Register the polly: protocol using AWS Polly
# speech synthesis services. Syntax: polly:<text>
# @flag hidden
def polly_protocol(~rlog,~maxtime,text) =
  aws = aws_base()

  format = get(default="mp3","protocol.aws.polly.format")

  extname =
    if format == "mp3" then
      "mp3"
    elsif format == "ogg_vorbis" then
      "ogg"
    else
      "wav"
    end

  aws = "#{aws} polly synthesize-speech --output-format #{format}"

  voice_id = get(default="Joanna","protocol.aws.polly.voice")

  cmd = "#{aws} --text #{string.quote(text)} --voice-id #{string.quote(voice_id)} $(output)"

  [process_uri(extname=extname,cmd)]
end
add_protocol(static=true,"polly",polly_protocol,
             doc="Generate speech synthesis using AWS polly service. \
                  Result might be mono, needs aws binary in the path.",
             syntax="polly:Text to read")

# Protocol to synthesize audio.
# @flag hidden
def synth_protocol(~rlog,~maxtime,text) =
  log.debug(label="synth", "Synthesizing request: #{text}")
  args = string.split(separator=",", text)
  args = list.map(string.split(separator="="), args)
  if list.exists(fun(l)-> list.length(l) != 2, args) then
    []
  else
    args = list.map(fun(l) -> (list.hd(default="",l), list.hd(default="",list.tl(l))), args)
    shape = ref("sine")
    duration = ref(10.)
    frequency = ref(440.)
    def set(p)
      let (k,v) = p
      if k == "duration" then duration := float_of_string(v)
      elsif k == "frequency" then frequency := float_of_string(v)
      elsif k == "shape" then shape := v
      end
    end
    list.iter(set, args)
    def synth(s)
      file = file.temp("liq-synth",".wav")
      log.info(label="synth", "Synthesizing #{!shape} in #{file}.")
      source.dump(%wav, file, once(s))
      [file]
    end
    if !shape == "sine" then
      synth(sine(duration=!duration, !frequency))
    elsif !shape == "saw" then
      synth(saw(duration=!duration, !frequency))
    elsif !shape == "square" then
      synth(square(duration=!duration, !frequency))
    elsif !shape == "blank" then
      synth(blank(duration=!duration))
    else
      []
    end
  end
end

add_protocol(static=true, temporary=true, "synth", synth_protocol,
doc="Syntesize audio. Parameters are optional.",
syntax="synth:shape=sine,frequency=440.,duration=10.")

# File protocol
# @flag hidden
def file_protocol(~rlog,~maxtime,arg) =
  path = list.nth(default="", string.split(separator=":",arg), 1)
  segments = string.split(separator="/",path)

  segments =
    if list.length(segments) > 3 and
       list.nth(default="foo",segments,0) == "" and
       list.nth(default="foo",segments,1) == ""
    then
      list.tl(list.tl(segments))
    else
      segments
    end

  [url.decode(string.concat(separator="/",segments))]
end

add_protocol(static=true, temporary=false, "file", file_protocol,
             doc="File protocol. Only local files are supported",
             syntax="file:///path/to/file")
