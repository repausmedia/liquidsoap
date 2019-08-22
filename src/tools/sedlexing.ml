type lexbuf = Lexing.lexbuf

let set_filename lexbuf fname =
  lexbuf.Lexing.lex_start_p <- { lexbuf.Lexing.lex_start_p with Lexing.pos_fname = fname };
  lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = fname }

let lexing_positions lexbuf =
  lexbuf.Lexing.lex_start_p, lexbuf.Lexing.lex_curr_p

module Utf8 = struct
  let from_string = Lexing.from_string

  let from_channel = Lexing.from_channel

  let from_gen _ = failwith "TODO"

  let lexeme = Lexing.lexeme
end
