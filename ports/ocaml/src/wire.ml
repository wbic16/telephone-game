(* wire.ml - SHA-256 (implemented here with Int32 arithmetic; the
   OCaml stdlib Digest is MD5-only), base64, and a minimal JSON
   parser/printer with canonical output (Python json.dumps sort_keys,
   compact separators, ensure_ascii). *)

(* ---------- SHA-256 ---------- *)
let k_table =
  [| 0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l; 0x3956c25bl; 0x59f111f1l; 0x923f82a4l; 0xab1c5ed5l;
     0xd807aa98l; 0x12835b01l; 0x243185bel; 0x550c7dc3l; 0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l; 0xc19bf174l;
     0xe49b69c1l; 0xefbe4786l; 0x0fc19dc6l; 0x240ca1ccl; 0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal;
     0x983e5152l; 0xa831c66dl; 0xb00327c8l; 0xbf597fc7l; 0xc6e00bf3l; 0xd5a79147l; 0x06ca6351l; 0x14292967l;
     0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl; 0x53380d13l; 0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l;
     0xa2bfe8a1l; 0xa81a664bl; 0xc24b8b70l; 0xc76c51a3l; 0xd192e819l; 0xd6990624l; 0xf40e3585l; 0x106aa070l;
     0x19a4c116l; 0x1e376c08l; 0x2748774cl; 0x34b0bcb5l; 0x391c0cb3l; 0x4ed8aa4al; 0x5b9cca4fl; 0x682e6ff3l;
     0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l; 0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l |]

let rotr x n =
  Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))

let sha256_hex msg =
  let h =
    [| 0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al; 0x510e527fl; 0x9b05688cl; 0x1f83d9abl; 0x5be0cd19l |]
  in
  let len = String.length msg in
  let padded_len = ((len + 9 + 63) / 64) * 64 in
  let data = Bytes.make padded_len '\x00' in
  Bytes.blit_string msg 0 data 0 len;
  Bytes.set data len '\x80';
  let bitlen = Int64.of_int len |> Int64.mul 8L in
  for i = 0 to 7 do
    let byte = Int64.to_int (Int64.logand (Int64.shift_right bitlen ((7 - i) * 8)) 0xffL) in
    Bytes.set data (padded_len - 8 + i) (Char.chr byte)
  done;
  let w = Array.make 64 0l in
  let add = Int32.add in
  for chunk = 0 to padded_len / 64 - 1 do
    let base = chunk * 64 in
    for i = 0 to 15 do
      let o = base + (i * 4) in
      w.(i) <-
        Int32.logor
          (Int32.logor
             (Int32.shift_left (Int32.of_int (Char.code (Bytes.get data o))) 24)
             (Int32.shift_left (Int32.of_int (Char.code (Bytes.get data (o + 1)))) 16))
          (Int32.logor
             (Int32.shift_left (Int32.of_int (Char.code (Bytes.get data (o + 2)))) 8)
             (Int32.of_int (Char.code (Bytes.get data (o + 3)))))
    done;
    for i = 16 to 63 do
      let s0 =
        Int32.logxor (Int32.logxor (rotr w.(i - 15) 7) (rotr w.(i - 15) 18))
          (Int32.shift_right_logical w.(i - 15) 3)
      in
      let s1 =
        Int32.logxor (Int32.logxor (rotr w.(i - 2) 17) (rotr w.(i - 2) 19))
          (Int32.shift_right_logical w.(i - 2) 10)
      in
      w.(i) <- add (add w.(i - 16) s0) (add w.(i - 7) s1)
    done;
    let a = ref h.(0) and b = ref h.(1) and c = ref h.(2) and d = ref h.(3) in
    let e = ref h.(4) and f = ref h.(5) and g = ref h.(6) and hh = ref h.(7) in
    for i = 0 to 63 do
      let s1 = Int32.logxor (Int32.logxor (rotr !e 6) (rotr !e 11)) (rotr !e 25) in
      let ch = Int32.logxor (Int32.logand !e !f) (Int32.logand (Int32.lognot !e) !g) in
      let t1 = add (add (add !hh s1) (add ch k_table.(i))) w.(i) in
      let s0 = Int32.logxor (Int32.logxor (rotr !a 2) (rotr !a 13)) (rotr !a 22) in
      let maj =
        Int32.logxor (Int32.logxor (Int32.logand !a !b) (Int32.logand !a !c)) (Int32.logand !b !c)
      in
      let t2 = add s0 maj in
      hh := !g; g := !f; f := !e; e := add !d t1; d := !c; c := !b; b := !a; a := add t1 t2
    done;
    h.(0) <- add h.(0) !a; h.(1) <- add h.(1) !b; h.(2) <- add h.(2) !c; h.(3) <- add h.(3) !d;
    h.(4) <- add h.(4) !e; h.(5) <- add h.(5) !f; h.(6) <- add h.(6) !g; h.(7) <- add h.(7) !hh
  done;
  let buf = Buffer.create 64 in
  Array.iter (fun v -> Buffer.add_string buf (Printf.sprintf "%08lx" v)) h;
  Buffer.contents buf

(* ---------- base64 ---------- *)
let b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let b64_encode data =
  let len = String.length data in
  let buf = Buffer.create ((len + 2) / 3 * 4) in
  let rec go i =
    if i < len then begin
      let a = Char.code data.[i] in
      let b = if i + 1 < len then Char.code data.[i + 1] else 0 in
      let c = if i + 2 < len then Char.code data.[i + 2] else 0 in
      let n = (a lsl 16) lor (b lsl 8) lor c in
      Buffer.add_char buf b64_chars.[(n lsr 18) land 63];
      Buffer.add_char buf b64_chars.[(n lsr 12) land 63];
      Buffer.add_char buf (if i + 1 < len then b64_chars.[(n lsr 6) land 63] else '=');
      Buffer.add_char buf (if i + 2 < len then b64_chars.[n land 63] else '=');
      go (i + 3)
    end
  in
  go 0;
  Buffer.contents buf

let b64_value ch =
  if ch >= 'A' && ch <= 'Z' then Char.code ch - Char.code 'A'
  else if ch >= 'a' && ch <= 'z' then Char.code ch - Char.code 'a' + 26
  else if ch >= '0' && ch <= '9' then Char.code ch - Char.code '0' + 52
  else if ch = '+' then 62
  else if ch = '/' then 63
  else -1

let b64_decode data =
  let clean =
    String.concat "" (String.split_on_char '\n' (String.concat "" (String.split_on_char '\r' data)))
  in
  let clean =
    let b = Buffer.create (String.length clean) in
    String.iter (fun ch -> if b64_value ch >= 0 || ch = '=' then Buffer.add_char b ch) clean;
    Buffer.contents b
  in
  let len = String.length clean in
  let buf = Buffer.create (len / 4 * 3 + 3) in
  let rec go i =
    if i + 3 < len + 1 && i < len then begin
      let c1 = clean.[i] and c2 = clean.[i + 1] and c3 = clean.[i + 2] and c4 = clean.[i + 3] in
      let n =
        ((b64_value c1) lsl 18) lor ((b64_value c2) lsl 12)
        lor ((if c3 = '=' then 0 else b64_value c3) lsl 6)
        lor (if c4 = '=' then 0 else b64_value c4)
      in
      Buffer.add_char buf (Char.chr ((n lsr 16) land 0xff));
      if c3 <> '=' then Buffer.add_char buf (Char.chr ((n lsr 8) land 0xff));
      if c4 <> '=' then Buffer.add_char buf (Char.chr (n land 0xff));
      go (i + 4)
    end
  in
  if len >= 4 then go 0;
  Buffer.contents buf

(* ---------- JSON ---------- *)
type json =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | Str of string
  | Arr of json list
  | Obj of (string * json) list

let json_get key = function
  | Obj fields -> (try List.assoc key fields with Not_found -> Null)
  | _ -> Null

let json_string = function Str s -> s | _ -> ""
let json_int = function Int n -> n | Float f -> int_of_float f | _ -> 0

let utf8_encode buf cp =
  if cp < 0x80 then Buffer.add_char buf (Char.chr cp)
  else if cp < 0x800 then begin
    Buffer.add_char buf (Char.chr (0xC0 lor (cp lsr 6)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end
  else if cp < 0x10000 then begin
    Buffer.add_char buf (Char.chr (0xE0 lor (cp lsr 12)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end
  else begin
    Buffer.add_char buf (Char.chr (0xF0 lor (cp lsr 18)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end

exception Json_error of string

let parse_json s =
  let len = String.length s in
  let pos = ref 0 in
  let skip () =
    while !pos < len && (s.[!pos] = ' ' || s.[!pos] = '\t' || s.[!pos] = '\n' || s.[!pos] = '\r') do
      incr pos
    done
  in
  let expect ch =
    if !pos >= len || s.[!pos] <> ch then raise (Json_error ("expected " ^ String.make 1 ch));
    incr pos
  in
  let rec parse_string () =
    expect '"';
    let buf = Buffer.create 32 in
    let rec go () =
      if !pos >= len then raise (Json_error "unterminated string");
      let ch = s.[!pos] in
      if ch = '"' then begin
        incr pos;
        Buffer.contents buf
      end
      else if ch = '\\' then begin
        incr pos;
        if !pos >= len then raise (Json_error "bad escape");
        let esc = s.[!pos] in
        incr pos;
        (match esc with
         | 'n' -> Buffer.add_char buf '\n'
         | 't' -> Buffer.add_char buf '\t'
         | 'r' -> Buffer.add_char buf '\r'
         | 'b' -> Buffer.add_char buf '\b'
         | 'f' -> Buffer.add_char buf '\x0c'
         | '/' -> Buffer.add_char buf '/'
         | '\\' -> Buffer.add_char buf '\\'
         | '"' -> Buffer.add_char buf '"'
         | 'u' ->
             if !pos + 4 > len then raise (Json_error "bad \\u");
             let cp = int_of_string ("0x" ^ String.sub s !pos 4) in
             pos := !pos + 4;
             if cp >= 0xD800 && cp <= 0xDBFF && !pos + 6 <= len && s.[!pos] = '\\' && s.[!pos + 1] = 'u'
             then begin
               let lo = int_of_string ("0x" ^ String.sub s (!pos + 2) 4) in
               if lo >= 0xDC00 && lo <= 0xDFFF then begin
                 pos := !pos + 6;
                 utf8_encode buf (0x10000 + ((cp - 0xD800) lsl 10) + (lo - 0xDC00))
               end
               else utf8_encode buf cp
             end
             else utf8_encode buf cp
         | _ -> raise (Json_error "bad escape char"));
        go ()
      end
      else begin
        Buffer.add_char buf ch;
        incr pos;
        go ()
      end
    in
    go ()
  and parse_value () =
    skip ();
    if !pos >= len then raise (Json_error "eof");
    match s.[!pos] with
    | '{' ->
        incr pos;
        skip ();
        if !pos < len && s.[!pos] = '}' then begin
          incr pos;
          Obj []
        end
        else begin
          let rec fields acc =
            skip ();
            let k = parse_string () in
            skip ();
            expect ':';
            let v = parse_value () in
            skip ();
            if !pos < len && s.[!pos] = ',' then begin
              incr pos;
              fields ((k, v) :: acc)
            end
            else begin
              expect '}';
              Obj (List.rev ((k, v) :: acc))
            end
          in
          fields []
        end
    | '[' ->
        incr pos;
        skip ();
        if !pos < len && s.[!pos] = ']' then begin
          incr pos;
          Arr []
        end
        else begin
          let rec elems acc =
            let v = parse_value () in
            skip ();
            if !pos < len && s.[!pos] = ',' then begin
              incr pos;
              elems (v :: acc)
            end
            else begin
              expect ']';
              Arr (List.rev (v :: acc))
            end
          in
          elems []
        end
    | '"' -> Str (parse_string ())
    | 't' ->
        if String.sub s !pos 4 <> "true" then raise (Json_error "bad literal");
        pos := !pos + 4;
        Bool true
    | 'f' ->
        if String.sub s !pos 5 <> "false" then raise (Json_error "bad literal");
        pos := !pos + 5;
        Bool false
    | 'n' ->
        if String.sub s !pos 4 <> "null" then raise (Json_error "bad literal");
        pos := !pos + 4;
        Null
    | _ ->
        let start = !pos in
        while
          !pos < len
          && (let ch = s.[!pos] in
              (ch >= '0' && ch <= '9') || ch = '-' || ch = '+' || ch = '.' || ch = 'e' || ch = 'E')
        do
          incr pos
        done;
        let tok = String.sub s start (!pos - start) in
        if String.contains tok '.' || String.contains tok 'e' || String.contains tok 'E' then
          Float (float_of_string tok)
        else Int (int_of_string tok)
  in
  let v = parse_value () in
  skip ();
  v

(* ---------- canonical JSON ---------- *)
let canon_string buf s =
  Buffer.add_char buf '"';
  let len = String.length s in
  let i = ref 0 in
  while !i < len do
    let b = Char.code s.[!i] in
    let cp, adv =
      if b < 0x80 then (b, 1)
      else if b < 0xE0 then (((b land 0x1F) lsl 6) lor (Char.code s.[!i + 1] land 0x3F), 2)
      else if b < 0xF0 then
        (((b land 0x0F) lsl 12) lor ((Char.code s.[!i + 1] land 0x3F) lsl 6)
         lor (Char.code s.[!i + 2] land 0x3F), 3)
      else
        (((b land 0x07) lsl 18) lor ((Char.code s.[!i + 1] land 0x3F) lsl 12)
         lor ((Char.code s.[!i + 2] land 0x3F) lsl 6) lor (Char.code s.[!i + 3] land 0x3F), 4)
    in
    i := !i + adv;
    (match cp with
     | 0x22 -> Buffer.add_string buf "\\\""
     | 0x5C -> Buffer.add_string buf "\\\\"
     | 0x08 -> Buffer.add_string buf "\\b"
     | 0x0C -> Buffer.add_string buf "\\f"
     | 0x0A -> Buffer.add_string buf "\\n"
     | 0x0D -> Buffer.add_string buf "\\r"
     | 0x09 -> Buffer.add_string buf "\\t"
     | _ ->
         if cp < 0x20 || cp > 0x7E then begin
           if cp > 0xFFFF then begin
             let v = cp - 0x10000 in
             Buffer.add_string buf (Printf.sprintf "\\u%04x\\u%04x" (0xD800 + (v lsr 10)) (0xDC00 + (v land 0x3FF)))
           end
           else Buffer.add_string buf (Printf.sprintf "\\u%04x" cp)
         end
         else Buffer.add_char buf (Char.chr cp))
  done;
  Buffer.add_char buf '"'

let rec canon buf = function
  | Null -> Buffer.add_string buf "null"
  | Bool b -> Buffer.add_string buf (if b then "true" else "false")
  | Int n -> Buffer.add_string buf (string_of_int n)
  | Float f ->
      if Float.is_integer f then Buffer.add_string buf (Printf.sprintf "%d" (int_of_float f))
      else Buffer.add_string buf (Printf.sprintf "%.14g" f)
  | Str s -> canon_string buf s
  | Arr elems ->
      Buffer.add_char buf '[';
      List.iteri
        (fun i e ->
          if i > 0 then Buffer.add_char buf ',';
          canon buf e)
        elems;
      Buffer.add_char buf ']'
  | Obj fields ->
      let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) fields in
      Buffer.add_char buf '{';
      List.iteri
        (fun i (k, v) ->
          if i > 0 then Buffer.add_char buf ',';
          canon_string buf k;
          Buffer.add_char buf ':';
          canon buf v)
        sorted;
      Buffer.add_char buf '}'

let canon_json v =
  let buf = Buffer.create 256 in
  canon buf v;
  Buffer.contents buf
