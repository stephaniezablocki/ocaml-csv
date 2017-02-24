(* File: csv.pp.ml

   Copyright (C) 2005-2009

     Richard Jones
     email: rjones@redhat.com

     Christophe Troestler
     email: Christophe.Troestler@umons.ac.be
     WWW: http://math.umons.ac.be/anum/software/

   This library is free software; you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License version 2.1 or
   later as published by the Free Software Foundation, with the special
   exception on linking described in the file LICENSE.

   This library is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
   LICENSE for more details. *)

(* MOTIVATION.  There are already several solutions to parse CSV files
   in OCaml.  They did not suit my needs however because:

   - The files I need to deal with have a header which does not always
   reflect the data structure (say the first row are the names of
   neurones but there are two columns per name).  In other words I
   want to be able to deal with heterogeneous files.

   - I do not want to read the the whole file at once (I may but I
   just want to be able to choose).  Higher order functions like fold
   are fine provided the read stops at the line an exception is raised
   (so it can be reread again).

   - For similarly encoded line, being able to specify once a decoder
   and then use a type safe version would be nice.

   - Speed is not neglected (we would like to be able to parse a
   ~2.5Mb file under 0.1 sec on my machine (2GHz Core Duo)).

   We follow the CVS format documentation available at
   http://www.creativyst.com/Doc/Articles/CSV/CSV01.htm
*)

type t = string list list

(* Specialize [min] to integers for performance reasons (> 150% faster). *)
let min x y = if (x:int) <= y then x else y
let max x y = if (x:int) >= y then x else y

(* Add Buffer.add_subbytes for all compiler versions.
   Copied from the OCaml stdlib. *)
module Buffer = struct
    include Buffer

    let add_subbytes b s offset len =
      add_substring b (Bytes.unsafe_to_string s) offset len
  end

(* Enhance the List module with tail rec functions. *)
module List = struct
  include List

  (* Implementation of [map] in JSC Core. *)
  let map_slow l ~f = List.rev (List.rev_map f l)

  let rec count_map ~f l ctr =
    match l with
    | [] -> []
    | [x1] ->
       let f1 = f x1 in
       [f1]
    | [x1; x2] ->
       let f1 = f x1 in
       let f2 = f x2 in
       [f1; f2]
    | [x1; x2; x3] ->
       let f1 = f x1 in
       let f2 = f x2 in
       let f3 = f x3 in
       [f1; f2; f3]
    | [x1; x2; x3; x4] ->
       let f1 = f x1 in
       let f2 = f x2 in
       let f3 = f x3 in
       let f4 = f x4 in
       [f1; f2; f3; f4]
    | x1 :: x2 :: x3 :: x4 :: x5 :: tl ->
       let f1 = f x1 in
       let f2 = f x2 in
       let f3 = f x3 in
       let f4 = f x4 in
       let f5 = f x5 in
       f1 :: f2 :: f3 :: f4 :: f5 :: (if ctr > 1000
                                      then map_slow ~f tl
                                      else count_map ~f tl (ctr + 1))

  let map f l = count_map ~f l 0

  (* Implementation of [append] in JSC core. *)
  let slow_append l1 l2 = List.rev_append (List.rev l1) l2

  let rec count_append l1 l2 count =
    match l1 with
    | []               ->                         l2
    | [x1]             -> x1                   :: l2
    | [x1; x2]         -> x1 :: x2             :: l2
    | [x1; x2; x3]     -> x1 :: x2 :: x3       :: l2
    | [x1; x2; x3; x4] -> x1 :: x2 :: x3 :: x4 :: l2
    | x1 :: x2 :: x3 :: x4 :: x5 :: tl ->
       x1 :: x2 :: x3 :: x4 :: x5 :: (if count > 1000
                                      then slow_append tl l2
                                      else count_append tl l2 (count + 1))

  let append l1 l2 = count_append l1 l2 0

  (* Tail recursive [combine]. *)
  let rec rev_combine acc l1 l2 =
    match l1, l2 with
    | ([], []) -> acc
    | (a1::l1, a2::l2) -> rev_combine ((a1, a2) :: acc) l1 l2
    | (_, _) -> invalid_arg "List.combine"

  let slow_combine l1 l2 = List.rev (rev_combine [] l1 l2)

  let rec count_combine l1 l2 count =
    match l1, l2 with
    | ([], []) -> []
    | ([x1], [y1]) -> [x1, y1]
    | ([x1; x2], [y1; y2]) -> [x1, y1; x2, y2]
    | ([x1; x2; x3], [y1; y2; y3]) -> [x1, y1; x2, y2; x3, y3]
    | ([x1; x2; x3; x4], [y1; y2; y3; y4]) -> [x1, y1; x2, y2; x3, y3; x4, y4]
    | (x1 :: x2 :: x3 :: x4 :: tl1), (y1 :: y2 :: y3 :: y4 :: tl2) ->
       (x1, y1) :: (x2, y2) :: (x3, y3) :: (x4, y4)
       :: (if count > 1000 then slow_combine tl1 tl2
           else count_combine tl1 tl2 (count + 1))
    | (_, _) -> invalid_arg "List.combine"

  let combine l1 l2 = count_combine l1 l2 0

end

class type in_obj_channel =
object
  method input : Bytes.t -> int -> int -> int
  method close_in : unit -> unit
end

class type out_obj_channel =
object
  method output : Bytes.t -> int -> int -> int
  method close_out : unit -> unit
end

(*
 * Representation of rows accessible by both keys and numbers
 *)

module Header = struct
  module M = Map.Make(String)

  type t = { names : string array;
             index : int M.t }
  (* This is a correspondence between names and column numbers, in
     both directions.  Names "" are not active and must not be in the
     index. *)

  let empty = { names = [| |];  index = M.empty }

  let get t i = try t.names.(i) with _ -> ""
  let find t name = M.find name t.index

  let of_names names =
    let names = Array.of_list names in
    let index = ref M.empty in
    for i = 0 to Array.length names - 1 do
      if names.(i) <> "" then
        if M.mem names.(i) !index then
          names.(i) <- "" (* remove duplicate binding *)
        else index := M.add names.(i) i !index
    done;
    { names;  index = !index }

  let names t = Array.to_list t.names

  (* [main] names take precedence over [t] ones. *)
  let merge ~main t =
    let index = ref main.index in
    if Array.length main.names >= Array.length t.names then (
      let names = Array.copy main.names in
      for i = 0 to Array.length t.names - 1 do
        if names.(i) = "" && t.names.(i) <> ""
           && not(M.mem t.names.(i) !index) then (
          names.(i) <- t.names.(i);
          index := M.add names.(i) i !index
        )
      done;
      { names;  index = !index }
    )
    else (
      let names = Array.make (Array.length t.names) "" in
      for i = 0 to Array.length main.names - 1 do
        if main.names.(i) <> "" then
          names.(i) <- main.names.(i)
        else if t.names.(i) <> "" && not(M.mem t.names.(i) !index) then (
          names.(i) <- t.names.(i);
          index := M.add names.(i) i !index
        )
      done;
      for i = Array.length names to Array.length names - 1 do
        if t.names.(i) <> "" then (
          names.(i) <- t.names.(i);
          index := M.add names.(i) i !index
        )
      done;
      { names;  index = !index }
    )
end


module Row = struct
  (* Datastructure with double access (integer and key). *)
  type t = { header : Header.t;  row: string array }

  let make header row = { header;  row = Array.of_list row }

  let get t i = try t.row.(i) with _ -> ""

  let find t key =
    try t.row.(Header.find t.header key)
    with _ -> ""

  let to_list t = Array.to_list t.row

  let to_assoc t =
    let l = ref [] in
    for i = Array.length t.row - 1 downto 0 do
      l := (Header.get t.header i, t.row.(i)) :: !l
    done;
    !l

  let with_header t h =
    let h = Header.of_names h in
    { t with header = Header.merge ~main:h t.header }
end


(*
 * Input
 *)

exception Failure of int * int * string

let buffer_len = 0x1FFF

(* We buffer the input as this allows the be efficient while using
   very basic input channels.  The drawback is that if we want to use
   another tool, there will be data hold in the buffer.  That is why
   we allow to convert a CSV handle to an object sharing the same
   buffer.  Because if this, we actually decided to implement the CSV
   handle as an object that is coercible to a input-object.

   FIXME: This is not made for non-blocking channels.  Can we fix it? *)
type in_channel = {
  in_chan : in_obj_channel;
  in_buf : Bytes.t;
  (* The data in the in_buf is at indexes i s.t. in0 <= i < in1.
     Invariant: 0 <= in0 ; in1 <= buffer_len in1 < 0 indicates a
     closed channel. *)
  mutable in0 : int;
  mutable in1 : int;
  mutable end_of_file : bool;
  (* If we encounter an End_of_file exception, we set this flag to
     avoid reading again because we do not know how the channel will
     react past an end of file.  That allows us to assume that
     reading past an end of file will keep raising End_of_file. *)
  current_field : Buffer.t; (* buffer reused to scan fields *)
  mutable record : string list; (* The current record *)
  mutable record_n : int; (* For error messages *)
  has_header : bool;
  header : Header.t; (* Convert the rows on demand (=> do not pay the price
                        if one does not use that feature). *)
  separator : char;
  backslash_escape : bool; (* Whether \x is considered as an escape *)
  excel_tricks : bool;
  (* Whitespace related stripping functions: *)
  is_space : char -> bool;
  lstrip_buffer : Buffer.t -> unit;
  rstrip_substring : Bytes.t -> int -> int -> string;
  rstrip_contents : Buffer.t -> string;
}

(*
 * Helpers for input
 *)

let is_space_or_tab c = c = ' ' || c = '\t' (* See documentation *)
let is_real_space c = c = ' ' (* when separator = '\t' *)

(* Given a buffer, returns its content stripped of *final* whitespace. *)
let rstrip_contents buf =
  let n = ref(Buffer.length buf - 1) in
  while !n >= 0 && is_space_or_tab(Buffer.nth buf !n) do decr n done;
  Buffer.sub buf 0 (!n + 1)

(* Return the substring after stripping its final space.  It is
   assumed the substring parameters are valid. *)
let rstrip_substring buf ofs len =
  let n = ref(ofs + len - 1) in
  while !n >= ofs && is_space_or_tab(Bytes.unsafe_get buf !n) do decr n done;
  Bytes.sub_string buf ofs (!n - ofs + 1)

let do_nothing _ = ()

(* [fill_in_buf_or_Eof chan] refills in_buf if needed (when empty).  After
   this [in0 < in1] or [in0 = in1 = 0], the latter indicating that
   there is currently no bytes to read (for a non-blocking channel).

   @raise End_of_file if there are no more bytes to read. *)
let fill_in_buf_or_Eof ic =
  if ic.end_of_file then raise End_of_file;
  if ic.in0 >= ic.in1 then begin
    try
      ic.in0 <- 0;
      ic.in1 <- ic.in_chan#input ic.in_buf 0 buffer_len;
    with End_of_file ->
      ic.end_of_file <- true;
      raise End_of_file
  end

(*
 * CSV input format parsing
 *)

(* Array: char escaped with '\\' → char.
   Keep in sync with [escape]. *)
let unescape =
  let escaped_by c =
    match Char.unsafe_chr c with
    | '0' -> '\000' (* \0 = NULL *)
    | 'b' -> '\b'
    | 'n' -> '\n'
    | 'r' -> '\r'
    | 't' -> '\t'
    | 'Z' -> '\026' (* Ctrl + Z, used by MySQL. *)
    | c -> c (* unchanged *) in
  Array.init 256 escaped_by

(* Skip the possible '\n' following a '\r'.  Reaching End_of_file is
   not considered an error -- just do nothing. *)
let skip_CR ic =
  try
    fill_in_buf_or_Eof ic;
    if Bytes.unsafe_get ic.in_buf ic.in0 = '\n' then ic.in0 <- ic.in0 + 1
  with End_of_file -> ()


(* Unquoted field.  Read till a delimiter, a newline, or the
   end of the file.  Skip the next delimiter or newline.
   @return [true] if more fields follow, [false] if the record
   is complete. *)
let rec seek_unquoted_separator ic i =
  if i >= ic.in1 then (
    (* End not found, need to look at the next chunk *)
    Buffer.add_subbytes ic.current_field ic.in_buf ic.in0 (i - ic.in0);
    ic.in0 <- i;
    fill_in_buf_or_Eof ic;
    seek_unquoted_separator ic 0
  )
  else
    let c = Bytes.unsafe_get ic.in_buf i in
    if c = ic.separator || c = '\n' || c = '\r' then (
      if Buffer.length ic.current_field = 0 then
        (* Avoid copying the string to the buffer if unnecessary *)
        ic.record <- ic.rstrip_substring ic.in_buf ic.in0 (i - ic.in0)
                    :: ic.record
      else (
        Buffer.add_subbytes ic.current_field ic.in_buf ic.in0 (i - ic.in0);
        ic.record <- ic.rstrip_contents ic.current_field :: ic.record
      );
      ic.in0 <- i + 1;
      if c = '\r' then (skip_CR ic; false) else (c = ic.separator)
    )
    else seek_unquoted_separator ic (i+1)

let add_unquoted_field ic =
  try seek_unquoted_separator ic ic.in0
  with End_of_file ->
    ic.record <- ic.rstrip_contents ic.current_field :: ic.record;
    false

(* Quoted field closed.  Read past a separator or a newline and decode
   the field or raise [End_of_file].  @return [true] if more fields
   follow, [false] if the record is complete. *)
let rec seek_quoted_separator ic field_no =
  fill_in_buf_or_Eof ic;
  let c = Bytes.unsafe_get ic.in_buf ic.in0 in
  ic.in0 <- ic.in0 + 1;
  if c = ic.separator || c = '\n' || c = '\r' then (
    ic.record <- Buffer.contents ic.current_field :: ic.record;
    if c = '\r' then (skip_CR ic; false) else (c = ic.separator)
  )
  else if is_space_or_tab c then
    seek_quoted_separator ic field_no (* skip space *)
  else raise(Failure(ic.record_n, field_no,
                     "Non-space char after closing the quoted field"))

let rec examine_quoted_field ic field_no after_quote i =
  if i >= ic.in1 then (
    (* End of field not found, need to look at the next chunk *)
    Buffer.add_subbytes ic.current_field ic.in_buf ic.in0 (i - ic.in0);
    ic.in0 <- i;
    fill_in_buf_or_Eof ic;
    examine_quoted_field ic field_no after_quote 0
  )
  else
    let c = Bytes.unsafe_get ic.in_buf i in
    if c = '\"' then (
      after_quote := true;
      (* Save the field so far, without the quote *)
      Buffer.add_subbytes ic.current_field ic.in_buf ic.in0 (i - ic.in0);
      ic.in0 <- i + 1; (* skip the quote *)
      (* The field up to [ic.in0] is saved, can refill if needed. *)
      fill_in_buf_or_Eof ic; (* possibly update [ic.in0] *)
      let c = Bytes.unsafe_get ic.in_buf ic.in0 in
      if c = '\"' then (
        after_quote := false;
        (* [c] is kept so a quote will be included in the field *)
        examine_quoted_field ic field_no after_quote (ic.in0 + 1)
      )
      else if c = ic.separator || is_space_or_tab c || c = '\n' || c = '\r' then (
        seek_quoted_separator ic field_no (* field already saved;
                                             after_quote=true *)
      )
      else if ic.excel_tricks && c = '0' then (
        (* Supposedly, '"' '0' means ASCII NULL *)
        after_quote := false;
        Buffer.add_char ic.current_field '\000';
        ic.in0 <- ic.in0 + 1; (* skip the '0' *)
        examine_quoted_field ic field_no after_quote ic.in0
      )
      else raise(Failure(ic.record_n, field_no, "Bad '\"' in quoted field"))
    )
    else if ic.backslash_escape && c = '\\' then (
      (* Save the field so far, without the backslash: *)
      Buffer.add_subbytes ic.current_field ic.in_buf ic.in0 (i - ic.in0);
      ic.in0 <- i + 1; (* skip the backslash *)
      fill_in_buf_or_Eof ic; (* possibly update [ic.in0] *)
      let c = Bytes.unsafe_get ic.in_buf ic.in0 in
      Buffer.add_char ic.current_field unescape.(Char.code c);
      ic.in0 <- ic.in0 + 1; (* skip the char [c]. *)
      examine_quoted_field ic field_no after_quote ic.in0
    )
    else examine_quoted_field ic field_no after_quote (i+1)

let add_quoted_field ic field_no =
  let after_quote = ref false in (* preserved through exn *)
  try examine_quoted_field ic field_no after_quote ic.in0
  with End_of_file ->
    (* Add the field even if not closed well *)
    ic.record <- Buffer.contents ic.current_field :: ic.record;
    if !after_quote then false (* = record is complete *)
    else raise(Failure(ic.record_n, field_no,
                       "Quoted field closed by end of file"))


let rec add_from_in_buf ic is_space =
  if ic.in0 < ic.in1 then
    let c = Bytes.unsafe_get ic.in_buf ic.in0 in
    if is_space c then (
      Buffer.add_char ic.current_field c;
      ic.in0 <- ic.in0 + 1;
      add_from_in_buf ic is_space
    )

let add_spaces ic =
  (* Skip spaces: after this [in0] is a non-space char. *)
  add_from_in_buf ic ic.is_space;
  while ic.in0 >= ic.in1 do
    fill_in_buf_or_Eof ic;
    add_from_in_buf ic ic.is_space;
  done

(* We suppose to be at the beginning of a field.  Add the next field
   to [record].  @return [true] if more fields follow, [false] if
   the record is complete.

   Return  Failure (if there is a format error), End_of_line
   (if the row is complete) or End_of_file (if there is not more
   data to read). *)
let add_next_field ic field_no =
  Buffer.clear ic.current_field;
  try
    add_spaces ic;
    (* Now, in0 < in1 or End_of_file was raised *)
    let c = Bytes.unsafe_get ic.in_buf ic.in0 in
    if c = '\"' then (
      ic.in0 <- ic.in0 + 1;
      Buffer.clear ic.current_field; (* remove spaces *)
      add_quoted_field ic field_no
    )
    else if ic.excel_tricks && c = '=' then (
      ic.in0 <- ic.in0 + 1; (* mark '=' as read *)
      try
        fill_in_buf_or_Eof ic;
        if Bytes.unsafe_get ic.in_buf ic.in0 = '\"' then (
          (* Excel trick ="..." to prevent spaces around the field
             to be removed. *)
          ic.in0 <- ic.in0 + 1; (* skip '"' *)
          add_quoted_field ic field_no
        )
        else (
          ic.lstrip_buffer ic.current_field; (* remove spaces *)
          Buffer.add_char ic.current_field '=';
          add_unquoted_field ic
        )
      with End_of_file ->
        ic.record <-  "=" :: ic.record;
        false
    )
    else (
      ic.lstrip_buffer ic.current_field; (* remove spaces *)
      add_unquoted_field ic
    )
  with End_of_file ->
    (* If it is the first field, coming from [next()], the field is
       made of spaces.  If after the first, we are sure we read a
       delimiter before (but maybe the field is empty).  Thus add en
       empty field. *)
    ic.record <-  "" :: ic.record;
    false

let next ic =
  if ic.in1 < 0 then raise(Sys_error "Bad file descriptor");
  fill_in_buf_or_Eof ic; (* End_of_file means no more records *)
  ic.record <- [];
  ic.record_n <- ic.record_n + 1; (* the current line being read *)
  let more_fields = ref true
  and field_no = ref 1 in (* the current field being read *)
  while !more_fields do
    more_fields := add_next_field ic !field_no;
    incr field_no;
  done;
  ic.record <- List.rev ic.record;
  ic.record


let current_record ic = ic.record


let fold_left ~f ~init:a0 ic =
  let a = ref a0 in
  try
    while true do
      a := f !a (next ic)
    done;
    assert false
  with End_of_file -> !a

let iter ~f ic =
  try  while true do f (next ic) done;
  with End_of_file -> ()

let input_all ic =
  List.rev(fold_left ~f:(fun l r -> r :: l) ~init:[] ic)

let fold_right ~f ic a0 =
  (* We to collect all records before applying [f] -- last row first. *)
  let lr = fold_left ~f:(fun l r -> r :: l) ~init:[] ic in
  List.fold_left (fun a r -> f r a) a0 lr


(*
 * Creating a handle, possibly with header
 *)

let of_in_obj ?(separator=',') ?(strip=true) ?(has_header=false) ?header
              ?(backslash_escape=false) ?(excel_tricks=true)
              in_chan =
  let ic = {
      in_chan = in_chan;
      in_buf = Bytes.create buffer_len;
      in0 = 0;
      in1 = 0;
      end_of_file = false;
      current_field = Buffer.create 0xFF;
      record = [];
      record_n = 0; (* => first record numbered 1 *)
      has_header = has_header || header <> None;
      header = Header.empty;
      separator = separator;
      backslash_escape;
      excel_tricks = excel_tricks;
      (* Stripping *)
      is_space = (if separator = '\t' then is_real_space else is_space_or_tab);
      lstrip_buffer = (if strip then Buffer.clear else do_nothing);
      rstrip_substring = (if strip then rstrip_substring else Bytes.sub_string);
      rstrip_contents = (if strip then rstrip_contents else Buffer.contents);
    } in
  if has_header then (
    (* Try to initialize headers with the first record that is read. *)
    try
      let names = next ic in
      let h = Header.of_names names in
      let h = match header with
        | None -> h
        | Some h0 -> Header.merge ~main:(Header.of_names h0) h in
      { ic with header = h }
    with End_of_file | Failure _ -> ic
  )
  else (
    (* The channel does not contain a header. *)
    match header with
    | None -> ic
    | Some h0 -> { ic with header = Header.of_names h0 }
  )


let of_channel ?separator ?strip ?has_header ?header
               ?backslash_escape ?excel_tricks fh =
  of_in_obj ?separator ?strip ?has_header ?header
            ?backslash_escape ?excel_tricks
    (object
       val fh = fh
       method input s ofs len =
         try
           let r = Pervasives.input fh s ofs len in
           if r = 0 then raise End_of_file;
           r
         with Sys_blocked_io -> 0
       method close_in() = Pervasives.close_in fh
     end)

let of_string ?separator ?strip ?has_header ?header
              ?backslash_escape ?excel_tricks str =
  of_in_obj ?separator ?strip ?has_header ?header
            ?backslash_escape ?excel_tricks
    (object
       val mutable position = 0
       method input buf ofs len =
         if position >= String.length str
         then raise End_of_file
         else
           ( let actual = min len (String.length str - position) in
               String.blit str position buf ofs actual ;
               position <- position + actual ;
               actual )
       method close_in() = ()
     end)

let close_in ic =
  if ic.in1 >= 0 then begin
    ic.in0 <- 0;
    ic.in1 <- -1;
    ic.in_chan#close_in(); (* may raise an exception *)
  end


let to_in_obj ic =
object
  val ic = ic

  method input buf ofs len =
    if ofs < 0 || len < 0 || ofs + len > Bytes.length buf
    then invalid_arg "Csv.to_in_obj#input";
    if ic.in1 < 0 then raise(Sys_error "Bad file descriptor");
    fill_in_buf_or_Eof ic;
    let r = min len (ic.in1 - ic.in0) in
    Bytes.blit ic.in_buf ic.in0 buf ofs r;
    ic.in0 <- ic.in0 + r;
    r

  method close_in() = close_in ic
end

let load ?separator ?strip ?backslash_escape ?excel_tricks fname =
  let fh = if fname = "-" then stdin else open_in fname in
  let csv = of_channel ?separator ?strip ?backslash_escape ?excel_tricks fh in
  let t = input_all csv in
  close_in csv;
  t

let load_in ?separator ?strip ?backslash_escape ?excel_tricks ch =
  input_all (of_channel ?separator ?strip ?backslash_escape ?excel_tricks ch)

(* @deprecated *)
let load_rows ?separator ?strip ?backslash_escape ?excel_tricks f ch =
  iter ~f (of_channel ?separator ?strip ?backslash_escape ?excel_tricks ch)

(*
 * Output
 *)

(* Arrays for backslash-escaping. *)
let must_escape = Array.make 256 false
let () =
  List.iter (fun c -> must_escape.(Char.code c) <- true)
            ['\"'; '\\';  '\000'; '\b'; '\n'; '\r'; '\t'; '\026']

let escape =
  (* Keep in sync with [unescape]. *)
  let escape_of c =
    match Char.unsafe_chr c with
    | '\000' -> '0' (* esape: \0 *)
    | '\b' -> 'b'
    | '\n' -> 'n'
    | '\r' -> 'r'
    | '\t' -> 't'
    | '\026' -> 'Z'
    | c ->  c in
  Array.init 256 escape_of

(* FIXME: Rework this part *)
type out_channel = {
  out_chan : out_obj_channel;
  out_separator : char;
  out_separator_bytes : Bytes.t;
  out_backslash_escape : bool;
  out_excel_tricks : bool;
}

let to_out_obj ?(separator=',') ?(backslash_escape=false) ?(excel_tricks=false)
               out_chan = {
  out_chan = out_chan;
  out_separator = separator;
  out_separator_bytes = Bytes.make 1 separator;
  out_backslash_escape = backslash_escape;
  out_excel_tricks = excel_tricks;
}

let to_channel ?separator ?backslash_escape ?excel_tricks fh =
  to_out_obj ?separator ?backslash_escape ?excel_tricks
    (object
       val fh = fh
       method output s ofs len = output fh s ofs len; len
       method close_out () = close_out fh
     end)

let to_buffer ?separator ?backslash_escape ?excel_tricks buf =
  to_out_obj ?separator ?backslash_escape ?excel_tricks
    (object
       method output s ofs len = Buffer.add_subbytes buf s ofs len; len
       method close_out () = ()
     end)

let close_out oc =
  oc.out_chan#close_out()

let rec really_output oc s ofs len =
  let w = oc.out_chan#output s ofs len in
  if w < len then really_output oc s (ofs+w) (len-w)

let quote_bytes = Bytes.make 1 '\"'
let output_quote oc = really_output oc quote_bytes 0 1

let equal_quote_bytes = Bytes.make 2 '='
let () = Bytes.unsafe_set equal_quote_bytes 1 '\"'
let output_equal_quote oc = really_output oc equal_quote_bytes 0 2

let newline_bytes = Bytes.make 1 '\n'
let output_newline oc = really_output oc newline_bytes 0 1

(* Determine whether the string s must be quoted and how many chars it
   must be extended to contain the escaped values.  Return -1 if there
   is no need to quote.  It is assumed that the string length [len]
   is > 0. *)
let must_quote oc s len =
  let quote = ref(is_space_or_tab(String.unsafe_get s 0)
                  || is_space_or_tab(String.unsafe_get s (len - 1))) in
  let n = ref 0 in
  for i = 0 to len - 1 do
    let c = String.unsafe_get s i in
    if oc.out_backslash_escape && must_escape.(Char.code c) then (
      (* Must be done first because backslash escaping will be
         favored, even for the separator, '\n',... *)
      quote := true;
      incr n)
    else if c = oc.out_separator || c = '\n' || c = '\r' then quote := true
    else if c = '"' || (oc.out_excel_tricks && c = '\000') then (
      quote := true;
      incr n)
  done;
  if !quote then !n else -1

let need_excel_trick s len =
  let c = String.unsafe_get s 0 in
  is_space_or_tab c || c = '0' || is_space_or_tab(String.unsafe_get s (len - 1))

(* Do some work to avoid quoting a field unless it is absolutely
   required. *)
let write_escaped oc field =
  if String.length field > 0 then begin
    let len = String.length field in
    let use_excel_trick = oc.out_excel_tricks && need_excel_trick field len
    and n = must_quote oc field len in
    if n < 0 && not use_excel_trick then
      (* [really_output] does not mutate the [Bytes.t] argument. *)
      really_output oc (Bytes.unsafe_of_string field) 0 len
    else (
      let field =
        if n <= 0 then Bytes.unsafe_of_string field
        else (* There are some quotes to escape *)
          let s = Bytes.create (len + n) in
          let j = ref 0 in
          for i = 0 to len - 1 do
            let c = String.unsafe_get field i in
            if oc.out_backslash_escape && must_escape.(Char.code c) then (
              Bytes.unsafe_set s !j '\\'; incr j;
              Bytes.unsafe_set s !j escape.(Char.code c); incr j
            )
            else if c = '"' then (
              Bytes.unsafe_set s !j '"'; incr j;
              Bytes.unsafe_set s !j '"'; incr j
            )
            else if oc.out_excel_tricks && c = '\000' then (
              Bytes.unsafe_set s !j '"'; incr j;
              Bytes.unsafe_set s !j '0'; incr j
            )
            else (Bytes.unsafe_set s !j c; incr j)
          done;
          s
      in
      if use_excel_trick then output_equal_quote oc
      else output_quote oc;
      really_output oc field 0 (Bytes.length field);
      output_quote oc
    )
  end

let output_record oc = function
  | [] ->
      output_newline oc
  | [f] ->
      write_escaped oc f;
      output_newline oc
  | f :: tl ->
      write_escaped oc f;
      List.iter (fun f ->
                   really_output oc oc.out_separator_bytes 0 1;
                   write_escaped oc f;
                ) tl;
      output_newline oc

let output_all oc t =
  List.iter (fun r -> output_record oc r) t

let print ?separator ?backslash_escape ?excel_tricks t =
  let csv = to_channel ?separator ?backslash_escape ?excel_tricks stdout in
  output_all csv t;
  flush stdout

let save_out ?separator ?backslash_escape ?excel_tricks ch t =
  let csv = to_channel ?separator ?backslash_escape ?excel_tricks ch in
  output_all csv t

let save ?separator ?backslash_escape ?excel_tricks fname t =
  let ch = open_out fname in
  let csv = to_channel ?separator ?backslash_escape ?excel_tricks ch in
  output_all csv t;
  Pervasives.close_out ch

(*
 * Reading rows with headers
 *)

module Rows = struct
  let header ic = Header.names ic.header

  let current ic = Row.make ic.header ic.record

  let next ic = Row.make ic.header (next ic)

  (* The convenience higher order functions are defined in terms of
     [next] in the same way as above. *)

  let fold_left ~f ~init:a0 ic =
    let a = ref a0 in
    try
      while true do
        a := f !a (next ic)
      done;
      assert false
    with End_of_file -> !a

  let iter ~f ic =
    try  while true do f (next ic) done;
    with End_of_file -> ()

  let input_all ic =
    List.rev(fold_left ~f:(fun l r -> r :: l) ~init:[] ic)

  let fold_right ~f ic a0 =
    (* We to collect all records before applying [f] -- last row first. *)
    let lr = fold_left ~f:(fun l r -> r :: l) ~init:[] ic in
    List.fold_left (fun a r -> f r a) a0 lr

  let load ?separator ?strip ?has_header ?header
           ?backslash_escape ?excel_tricks fname =
    let fh = if fname = "-" then stdin else open_in fname in
    let csv = of_channel ?separator ?strip ?has_header ?header
                         ?backslash_escape ?excel_tricks fh in
    let t = input_all csv in
    close_in csv;
    t

end