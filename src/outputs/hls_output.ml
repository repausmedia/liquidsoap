(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2020 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

(** HLS output. *)

let log = Log.make ["hls"; "output"]

let hls_proto kind =
  let segment_name_t =
    Lang.fun_t
      [
        (false, "position", Lang.int_t);
        (false, "extname", Lang.string_t);
        (false, "", Lang.string_t);
      ]
      Lang.string_t
  in
  let default_name =
    Lang.val_fun
      [
        ("position", "position", None);
        ("extname", "extname", None);
        ("", "", None);
      ] (fun p ->
        let position = Lang.to_int (List.assoc "position" p) in
        let extname = Lang.to_string (List.assoc "extname" p) in
        let sname = Lang.to_string (List.assoc "" p) in
        Lang.string (Printf.sprintf "%s_%d.%s" sname position extname))
  in
  let stream_info_t =
    Lang.product_t Lang.string_t
      (Lang.tuple_t [Lang.int_t; Lang.string_t; Lang.string_t])
  in
  Output.proto
  @ [
      ( "playlist",
        Lang.string_t,
        Some (Lang.string "stream.m3u8"),
        Some "Playlist name (m3u8 extension is recommended)." );
      ( "segment_duration",
        Lang.float_t,
        Some (Lang.float 10.),
        Some "Segment duration (in seconds)." );
      ( "segment_name",
        segment_name_t,
        Some default_name,
        Some
          "Segment name. Default: `fun (~position,~extname,stream_name) -> \
           \"#{stream_name}_#{position}.#{extname}\"`. Initial segment, when \
           required, has position `-1`." );
      ( "segments_overhead",
        Lang.int_t,
        Some (Lang.int 5),
        Some
          "Number of segments to keep after they have been featured in the \
           live playlist." );
      ( "segments",
        Lang.int_t,
        Some (Lang.int 10),
        Some "Number of segments per playlist." );
      ( "encode_metadata",
        Lang.bool_t,
        Some (Lang.bool false),
        Some
          "Insert metadata into encoded stream. Note: Some HLS players (in \
           particular android native HLS player) expect a single mpegts \
           stream. Encoding metadata will break that assumption." );
      ( "perm",
        Lang.int_t,
        Some (Lang.int 0o644),
        Some
          "Permission of the created files, up to umask. You can and should \
           write this number in octal notation: 0oXXX. The default value is \
           however displayed in decimal (0o666 = 6*8^2 + 4*8 + 4 = 412)." );
      ( "on_file_change",
        Lang.fun_t
          [(false, "state", Lang.string_t); (false, "", Lang.string_t)]
          Lang.unit_t,
        Some (Lang.val_cst_fun [("state", None); ("", None)] Lang.unit),
        Some
          "Callback executed when a file changes. `state` is one of: \
           `\"opened\"`, `\"closed\"` or `\"deleted\"`, second argument is \
           file path. Typical use: upload files to a CDN when done writting \
           (`\"close\"` state and remove when `\"deleted\"`." );
      ( "streams_info",
        Lang.list_t stream_info_t,
        Some (Lang.list []),
        Some
          "Additional information about the streams. Should be a list of the \
           form: `[(stream_name, (bandwidth, codec, extname)]`. See RFC 6381 \
           for info about codec. Stream info are required when they cannot be \
           inferred from the encoder." );
      ( "persist_at",
        Lang.nullable_t Lang.string_t,
        Some Lang.null,
        Some
          "Location of the configuration file used to restart the output. \
           Relative paths are assumed to be with regard to the directory for \
           generated file." );
      ("", Lang.string_t, None, Some "Directory for generated files.");
      ( "",
        Lang.list_t (Lang.product_t Lang.string_t (Lang.format_t kind)),
        None,
        Some "List of specifications for each stream: (name, format)." );
      ("", Lang.source_t kind, None, None);
    ]

type segment = {
  id : int;
  discontinuous : bool;
  current_discontinuity : int;
  filename : string;
  mutable out_channel : out_channel option;
  mutable len : int;
}

(* We marshal segments so we're not using
   Queue for them. *)
type segments = segment list ref

let push_segment segment segments = segments := !segments @ [segment]

let remove_segment segments =
  match !segments with
    | [] -> assert false
    | s :: l ->
        segments := l;
        s

type init_state = [ `Todo | `No_init | `Has_init of string ]

(** A stream in the HLS (which typically contains many, with different qualities). *)
type stream = {
  name : string;
  format : Encoder.format;
  encoder : Encoder.encoder;
  bandwidth : int;
  codec : string;  (** codec (see RFC 6381) *)
  extname : string;
  mutable init_state : init_state;
  mutable position : int;
  mutable current_segment : segment option;
  mutable discontinuity_count : int;
}

type hls_state = [ `Idle | `Started | `Stopped | `Restarted | `Streaming ]

open Extralib

let ( ^^ ) = Filename.concat

type file_state = [ `Opened | `Closed | `Deleted ]

let string_of_file_state = function
  | `Opened -> "opened"
  | `Closed -> "closed"
  | `Deleted -> "deleted"

class hls_output p =
  let on_start =
    let f = List.assoc "on_start" p in
    fun () -> ignore (Lang.apply f [])
  in
  let encode_metadata = Lang.to_bool (List.assoc "encode_metadata" p) in
  let on_stop =
    let f = List.assoc "on_stop" p in
    fun () -> ignore (Lang.apply f [])
  in
  let on_file_change =
    let f = List.assoc "on_file_change" p in
    fun ~state filename ->
      ignore
        (Lang.apply f
           [
             ("state", Lang.string (string_of_file_state state));
             ("", Lang.string filename);
           ])
  in
  let autostart = Lang.to_bool (List.assoc "start" p) in
  let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
  let directory = Lang.to_string (Lang.assoc "" 1 p) in
  let () =
    if (not (Sys.file_exists directory)) || not (Sys.is_directory directory)
    then
      raise
        (Lang_errors.Invalid_value
           (Lang.assoc "" 1 p, "The target directory does not exist"))
  in
  let persist_at =
    Option.map
      (fun filename ->
        let filename = Lang.to_string filename in
        let filename =
          if Filename.is_relative filename then
            Filename.concat directory filename
          else filename
        in
        let dir = Filename.dirname filename in
        ( try Utils.mkdir ~perm:0o777 dir
          with exn ->
            raise
              (Lang_errors.Invalid_value
                 ( List.assoc "persist_at" p,
                   Printf.sprintf
                     "Error while creating directory %S for persisting state: \
                      %s"
                     dir (Printexc.to_string exn) )) );
        filename)
      (Lang.to_option (List.assoc "persist_at" p))
  in
  (* better choice? *)
  let segment_duration = Lang.to_float (List.assoc "segment_duration" p) in
  let segment_ticks =
    Frame.master_of_seconds segment_duration / Lazy.force Frame.size
  in
  let segment_master_duration = segment_ticks * Lazy.force Frame.size in
  let segment_duration = Frame.seconds_of_master segment_master_duration in
  let segment_name = Lang.to_fun (List.assoc "segment_name" p) in
  let segment_name ~position ~extname sname =
    directory
    ^^ Lang.to_string
         (segment_name
            [
              ("position", Lang.int position);
              ("extname", Lang.string extname);
              ("", Lang.string sname);
            ])
  in
  let streams_info =
    let streams_info = List.assoc "streams_info" p in
    let l = Lang.to_list streams_info in
    List.map
      (fun el ->
        let name, specs = Lang.to_product el in
        let bandwidth, codec, extname =
          match Lang.to_tuple specs with
            | [bandwidth; codec; extname] -> (bandwidth, codec, extname)
            | _ -> assert false
        in
        ( Lang.to_string name,
          (Lang.to_int bandwidth, Lang.to_string codec, Lang.to_string extname)
        ))
      l
  in
  let streams =
    let streams = Lang.assoc "" 2 p in
    let l = Lang.to_list streams in
    if l = [] then
      raise
        (Lang_errors.Invalid_value
           (streams, "The list of streams cannot be empty"));
    l
  in
  let streams =
    let f s =
      let name, fmt = Lang.to_product s in
      let name = Lang.to_string name in
      let format = Lang.to_format fmt in
      let encoder_factory =
        try Encoder.get_factory format
        with Not_found ->
          raise (Lang_errors.Invalid_value (fmt, "Unsupported format"))
      in
      let encoder = encoder_factory name Meta_format.empty_metadata in
      let bandwidth, codec, extname =
        try List.assoc name streams_info
        with Not_found ->
          let bandwidth =
            try Encoder.bitrate format
            with Not_found ->
              raise
                (Lang_errors.Invalid_value
                   ( fmt,
                     "Bandwidth cannot be inferred from codec, please specify \
                      it in `streams_info`" ))
          in
          let codec =
            try Encoder.iso_base_file_media_file_format format
            with Not_found ->
              raise
                (Lang_errors.Invalid_value
                   ( fmt,
                     "Codec cannot be inferred from codec, please specify it \
                      in `streams_info`" ))
          in
          let extname =
            try Encoder.extension format
            with Not_found ->
              raise
                (Lang_errors.Invalid_value
                   ( fmt,
                     "File extension cannot be inferred from codec, please \
                      specify it in `streams_info`" ))
          in
          (bandwidth, codec, extname)
      in
      {
        name;
        format;
        encoder;
        bandwidth;
        codec;
        extname;
        init_state = `Todo;
        position = 0;
        current_segment = None;
        discontinuity_count = 0;
      }
    in
    let streams = List.map f streams in
    streams
  in
  let x_version () =
    if
      List.find_opt
        (fun s -> match s.init_state with `Has_init _ -> true | _ -> false)
        streams
      <> None
    then 7
    else 3
  in
  let source = Lang.assoc "" 3 p in
  let main_playlist_filename = Lang.to_string (List.assoc "playlist" p) in
  let main_playlist_path = directory ^^ main_playlist_filename in
  let segments_per_playlist = Lang.to_int (List.assoc "segments" p) in
  let max_segments =
    segments_per_playlist + Lang.to_int (List.assoc "segments_overhead" p)
  in
  let file_perm = Lang.to_int (List.assoc "perm" p) in
  let kind = Encoder.kind_of_format (List.hd streams).format in
  object (self)
    inherit
      Output.encoded
        ~infallible ~on_start ~on_stop ~autostart ~output_kind:"output.file"
          ~name:main_playlist_filename ~content_kind:kind source

    (** Available segments *)
    val mutable segments = List.map (fun { name } -> (name, ref [])) streams

    val mutable current_metadata = None

    val mutable state : hls_state = `Idle

    method private toggle_state event =
      match (event, state) with
        | `Restart, _ | `Resumed, _ | `Start, `Stopped -> state <- `Restarted
        | `Stop, _ -> state <- `Stopped
        | `Start, _ -> state <- `Started
        | `Streaming, _ -> state <- `Streaming

    method private open_out filename =
      let mode = [Open_wronly; Open_creat; Open_trunc] in
      let oc = open_out_gen mode file_perm filename in
      set_binary_mode_out oc true;
      on_file_change ~state:`Opened filename;
      oc

    method private close_out ~filename oc =
      close_out oc;
      on_file_change ~state:`Closed filename

    method private unlink filename =
      self#log#debug "Cleaning up %s.." filename;
      on_file_change ~state:`Deleted filename;
      try Unix.unlink filename
      with Unix.Unix_error (e, _, _) ->
        self#log#important "Could not remove file %s: %s" filename
          (Unix.error_message e)

    method private close_segment s =
      ignore
        (Option.map
           (fun segment ->
             self#close_out ~filename:segment.filename
               (Option.get segment.out_channel);
             segment.out_channel <- None;
             let segments = List.assoc s.name segments in
             push_segment segment segments;
             if List.length !segments >= max_segments then (
               let segment = remove_segment segments in
               self#unlink segment.filename ))
           s.current_segment);
      s.current_segment <- None

    method private open_segment s =
      self#log#debug "Opening segment %d for stream %s." s.position s.name;
      let meta =
        match current_metadata with
          | Some m -> m
          | None -> Meta_format.empty_metadata
      in
      if encode_metadata then s.encoder.Encoder.insert_metadata meta;
      let filename =
        segment_name ~position:s.position ~extname:s.extname s.name
      in
      let out_channel = self#open_out filename in
      Strings.iter (output_substring out_channel) s.encoder.Encoder.header;
      let discontinuous = state = `Restarted in
      let segment =
        {
          id = s.position;
          discontinuous;
          current_discontinuity = s.discontinuity_count;
          len = 0;
          filename;
          out_channel = Some out_channel;
        }
      in
      s.current_segment <- Some segment;
      s.position <- s.position + 1;
      if discontinuous then s.discontinuity_count <- s.discontinuity_count + 1;
      self#write_playlist s

    method private cleanup_streams =
      List.iter
        (fun (_, s) -> List.iter (fun s -> self#unlink s.filename) !s)
        segments;
      List.iter
        (fun s ->
          ignore
            (Option.map
               (fun segment ->
                 self#close_out ~filename:segment.filename
                   (Option.get segment.out_channel);
                 self#unlink segment.filename)
               s.current_segment);
          s.current_segment <- None;
          match s.init_state with
            | `Has_init filename -> self#unlink filename
            | _ -> ())
        streams

    method private playlist_name s = directory ^^ s.name ^ ".m3u8"

    method private write_playlist s =
      let segments =
        List.rev
          (List.fold_left
             (fun cur el ->
               if List.length cur < segments_per_playlist then el :: cur
               else cur)
             []
             !(List.assoc s.name segments))
      in
      let discontinuity_sequence, media_sequence =
        match segments with
          | { current_discontinuity; id } :: _ -> (current_discontinuity, id)
          | [] -> (0, 0)
      in
      let filename = self#playlist_name s in
      self#log#debug "Writting playlist %s.." s.name;
      let oc = self#open_out filename in
      output_string oc "#EXTM3U\r\n";
      output_string oc
        (Printf.sprintf "#EXT-X-TARGETDURATION:%d\r\n"
           (int_of_float (ceil segment_duration)));
      output_string oc (Printf.sprintf "#EXT-X-VERSION:%d\r\n" (x_version ()));
      output_string oc
        (Printf.sprintf "#EXT-X-MEDIA-SEQUENCE:%d\r\n" media_sequence);
      output_string oc
        (Printf.sprintf "#EXT-X-DISCONTINUITY-SEQUENCE:%d\r\n"
           discontinuity_sequence);
      List.iteri
        (fun pos segment ->
          if segment.discontinuous then
            output_string oc "#EXT-X-DISCONTINUITY\r\n";
          if pos = 0 || segment.discontinuous then (
            match s.init_state with
              | `Has_init init_filename ->
                  output_string oc
                    (Printf.sprintf "#EXT-X-MAP:URI=%S\r\n" init_filename)
              | _ -> () );
          output_string oc
            (Printf.sprintf "#EXTINF:%.03f,\r\n"
               (Frame.seconds_of_master segment.len));
          output_string oc (Printf.sprintf "%s\r\n" segment.filename))
        segments;

      self#close_out ~filename oc

    method private write_main_playlist =
      self#log#debug "Writting playlist %s.." main_playlist_path;
      let oc = self#open_out main_playlist_path in
      output_string oc "#EXTM3U\r\n";
      output_string oc (Printf.sprintf "#EXT-X-VERSION:%d\r\n" (x_version ()));
      List.iter
        (fun s ->
          let line =
            Printf.sprintf "#EXT-X-STREAM-INF:BANDWIDTH=%d,CODECS=%S\r\n"
              s.bandwidth s.codec
          in
          output_string oc line;
          output_string oc (s.name ^ ".m3u8\r\n"))
        streams;
      self#close_out ~filename:main_playlist_filename oc

    method private cleanup_playlists =
      List.iter (fun s -> self#unlink (self#playlist_name s)) streams;
      self#unlink main_playlist_path

    method output_start =
      ( match persist_at with
        | Some persist_at when Sys.file_exists persist_at -> (
            try
              self#log#info "Resuming from saved state";
              self#read_state persist_at;
              self#toggle_state `Resumed;
              try Unix.unlink persist_at with _ -> ()
            with exn ->
              self#log#info "Failed to resume from saved state: %s"
                (Printexc.to_string exn);
              self#toggle_state `Start )
        | _ -> self#toggle_state `Start );
      self#write_main_playlist;
      List.iter self#open_segment streams;
      self#toggle_state `Streaming

    method output_stop =
      self#toggle_state `Stop;
      let data =
        List.map (fun s -> (None, s.encoder.Encoder.stop ())) streams
      in
      self#send data;
      match persist_at with
        | Some persist_at ->
            self#log#info "Saving state to %S.." persist_at;
            List.iter (fun s -> self#close_segment s) streams;
            self#write_state persist_at
        | None ->
            self#cleanup_streams;
            self#cleanup_playlists

    method output_reset = self#toggle_state `Restart

    method private write_state persist_at =
      self#log#info "Reading state file at %S.." persist_at;
      let fd = open_out_bin persist_at in
      let streams =
        List.map
          (fun { name; position; discontinuity_count } ->
            (name, position, discontinuity_count))
          streams
      in
      Marshal.to_channel fd (streams, segments) [];
      close_out fd

    method private read_state persist_at =
      let fd = open_in_bin persist_at in
      let p, s = Marshal.from_channel fd in
      close_in fd;
      List.iter2
        (fun stream (name, pos, discontinuity_count) ->
          assert (name = stream.name);
          stream.discontinuity_count <- discontinuity_count;
          stream.position <- pos)
        streams p;
      segments <- s

    method private process_init ~init ({ extname; name } as s) =
      match init with
        | None -> s.init_state <- `No_init
        | Some data ->
            let init_filename = segment_name ~position:(-1) ~extname name in
            let oc = self#open_out init_filename in
            Strings.iter (output_substring oc) data;
            self#close_out ~filename:init_filename oc;
            s.init_state <- `Has_init init_filename

    method encode frame ofs len =
      List.map
        (fun s ->
          let segment = Option.get s.current_segment in
          let b =
            if s.init_state = `Todo then (
              let init, encoded =
                Encoder.(s.encoder.hls.init_encode frame ofs len)
              in
              self#process_init ~init s;
              (None, encoded) )
            else if segment.len + len > segment_master_duration then (
              match Encoder.(s.encoder.hls.split_encode frame ofs len) with
                | `Ok (flushed, encoded) -> (Some flushed, encoded)
                | `Nope encoded -> (None, encoded) )
            else (None, Encoder.(s.encoder.encode frame ofs len))
          in
          let segment = Option.get s.current_segment in
          segment.len <- segment.len + len;
          b)
        streams

    method private write_pipe s (flushed, data) =
      let { out_channel } = Option.get s.current_segment in
      ignore
        (Option.map
           (fun b ->
             Strings.iter (output_substring (Option.get out_channel)) b;
             self#close_segment s;
             self#open_segment s)
           flushed);
      let { out_channel } = Option.get s.current_segment in
      Strings.iter (output_substring (Option.get out_channel)) data

    method send b = List.iter2 self#write_pipe streams b

    method insert_metadata m =
      if encode_metadata then
        List.iter (fun s -> Encoder.(s.encoder.insert_metadata m)) streams
  end

let () =
  let return_t = Lang.univ_t () in
  Lang.add_operator "output.file.hls" (hls_proto return_t) ~active:true
    ~return_t ~category:Lang.Output
    ~descr:
      "Output the source stream to an HTTP live stream served from a local \
       directory." (fun p -> (new hls_output p :> Source.source))
