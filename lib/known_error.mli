type t =
  | InvalidUsage
  | NoSuchFile of string
  | InvalidBeam of {beam_filename: string; message: string}
  | UnboundVariable of {filename: string; line: int; variable: Context.Key.t}
  | TypeError of {filename: string; line: int; actual : Type.typ; expected: Type.typ; message: string}
  | NotImplemented of {issue_link: string}
[@@deriving show, sexp_of]

exception FialyzerError of t

val to_message : t -> string
