(* wire_caml.ml - SHA-256, base64 and canonical JSON for the Caml
   libphext port. SHA-256 is written from the FIPS 180-4 spec with
   Int32 words (the stdlib Digest module is MD5-only). JSON output is
   canonical: keys sorted, compact separators, strings escaped the
   way Python's json.dumps(ensure_ascii=True) escapes them, so hashes
   over canonical text agree byte-for-byte with the other ports. *)

(* ---------------- SHA-256 ---------------- *)
let sha256_hex message =
  let k =
    [| 0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l; 0x3956c25bl;
       0x59f111f1l; 0x923f82a4l; 0xab1c5ed5l; 0xd807aa98l; 0x12835b01l;
       0x243185bel; 0x550c7dc3l; 0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l;
       0xc19bf174l; 0xe49b69c1l; 0xefbe4786l; 0x0fc19dc6l; 0x240ca1ccl;
       0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal; 0x983e5152l;
       0xa831c66dl; 0xb00327c8l; 0xbf597fc7l; 0xc6e00bf3l; 0xd5a79147l;
       0x06ca6351l; 0x14292967l; 0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl;
       0x53380d13l; 0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l;
       0xa2bfe8a1l; 0xa81a664bl; 0xc24b8b70l; 0xc76c51a3l; 0xd192e819l;
       0xd6990624l; 0xf40e3585l; 0x106aa070l; 0x19a4c116l; 0x1e376c08l;
       0x2748774cl; 0x34b0bcb5l; 0x391c0cb3l; 0x4ed8aa4al; 0x5b9cca4fl;
       0x682e6ff3l; 0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l;
       0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l |]
  in
  let rotr x n =
    Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))
  in
  let len = String.length message in
  let total = ((len + 9 + 63) / 64) * 64 in
  let block = Bytes.make total '\x00' in
  Bytes.blit_string message 0 block 0 len;
  Bytes.set block len '\x80';
  let bits = Int64.mul (Int64.of_int len) 8L in
  for i = 0 to 7 do
    Bytes.set block (total - 1 - i)
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right bits (i * 8)) 0xffL)))
  done;
  let h =
    [| 0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al; 0x510e527fl;
       0x9b05688cl; 0x1f83d9abl; 0x5be0cd19l |]
  in
  let w = Array.make 64 0l in
  let word_at o =
    let byte i = Int32.of_int (Char.code (Bytes.get block (o + i))) in
    Int32.logor (Int32.shift_left (byte 0) 24)
      (Int32.logor (Int32.shift_left (byte 1) 16)
         (Int32.logor (Int32.shift_left (byte 2) 8) (byte 3)))
  in
  for chunk = 0 to total / 64 - 1 do
    let base = chunk * 64 in
    for i = 0 to 15 do w.(i) <- word_at (base + i * 4) done;
    for i = 16 to 63 do
      let s0 = Int32.logxor (Int32.logxor (rotr w.(i - 15) 7) (rotr w.(i - 15) 18))
                 (Int32.shift_right_logical w.(i - 15) 3) in
      let s1 = Int32.logxor (Int32.logxor (rotr w.(i - 2) 17) (rotr w.(i - 2) 19))
                 (Int32.shift_right_logical w.(i - 2) 10) in
      w.(i) <- Int32.add (Int32.add w.(i - 16) s0) (Int32.add w.(i - 7) s1)
    done;
    let v = Array.copy h in
    for i = 0 to 63 do
      let s1 = Int32.logxor (Int32.logxor (rotr v.(4) 6) (rotr v.(4) 11)) (rotr v.(4) 25) in
      let ch = Int32.logxor (Int32.logand v.(4) v.(5)) (Int32.logand (Int32.lognot v.(4)) v.(6)) in
      let t1 = Int32.add (Int32.add (Int32.add (Int32.add v.(7) s1) ch) k.(i)) w.(i) in
      let s0 = Int32.logxor (Int32.logxor (rotr v.(0) 2) (rotr v.(0) 13)) (rotr v.(0) 22) in
      let maj = Int32.logxor (Int32.logxor (Int32.logand v.(0) v.(1)) (Int32.logand v.(0) v.(2)))
                  (Int32.logand v.(1) v.(2)) in
      let t2 = Int32.add s0 maj in
      v.(7) <- v.(6); v.(6) <- v.(5); v.(5) <- v.(4);
      v.(4) <- Int32.add v.(3) t1;
      v.(3) <- v.(2); v.(2) <- v.(1); v.(1) <- v.(0);
      v.(0) <- Int32.add t1 t2
    done;
    for i = 0 to 7 do h.(i) <- Int32.add h.(i) v.(i) done
  done;
  let out = Buffer.create 64 in
  Array.iter (fun x -> Buffer.add_string out (Printf.sprintf "%08lx" x)) h;
  Buffer.contents out

(* ---------------- base64 ---------------- *)
let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let b64_encode data =
  let n = String.length data in
  let out = Buffer.create ((n + 2) / 3 * 4) in
  let rec go i =
    if i < n then begin
      let a = Char.code data.[i] in
      let b = if i + 1 < n then Char.code data.[i + 1] else 0 in
      let c = if i + 2 < n then Char.code data.[i + 2] else 0 in
      let v = (a lsl 16) lor (b lsl 8) lor c in
      Buffer.add_char out alphabet.[(v lsr 18) land 63];
      Buffer.add_char out alphabet.[(v lsr 12) land 63];
      Buffer.add_char out (if i + 1 < n then alphabet.[(v lsr 6) land 63] else '=');
      Buffer.add_char out (if i + 2 < n then alphabet.[v land 63] else '=');
      go (i + 3)
    end
  in
  go 0;
  Buffer.contents out

let b64_value = function
  | 'A' .. 'Z' as ch -> Char.code ch - 65
  | 'a' .. 'z' as ch -> Char.code ch - 71
  | '0' .. '9' as ch -> Char.code ch + 4
  | '+' -> 62
  | '/' -> 63
  | _ -> -1

let b64_decode data =
  let clean = Buffer.create (String.length data) in
  String.iter
    (fun ch -> if b64_value ch >= 0 || ch = '=' then Buffer.add_char clean ch)
    data;
  let clean = Buffer.contents clean in
  let n = String.length clean in
  let out = Buffer.create (n / 4 * 3 + 3) in
  let rec go i =
    if i + 4 <= n then begin
      let c3 = clean.[i + 2] and c4 = clean.[i + 3] in
      let v =
        (b64_value clean.[i] lsl 18) lor (b64_value clean.[i + 1] lsl 12)
        lor ((if c3 = '=' then 0 else b64_value c3) lsl 6)
        lor (if c4 = '=' then 0 else b64_value c4)
      in
      Buffer.add_char out (Char.chr ((v lsr 16) land 0xff));
      if c3 <> '=' then Buffer.add_char out (Char.chr ((v lsr 8) land 0xff));
      if c4 <> '=' then Buffer.add_char out (Char.chr (v land 0xff));
      go (i + 4)
    end
  in
  go 0;
  Buffer.contents out

(* ---------------- JSON ---------------- *)
type json =
  | JNull
  | JBool of bool
  | JInt of int
  | JFloat of float
  | JStr of string
  | JArr of json list
  | JObj of (string * json) list

let json_get key = function
  | JObj fields -> (try List.assoc key fields with Not_found -> JNull)
  | _ -> JNull

let json_string = function JStr s -> s | _ -> ""
let json_int = function JInt n -> n | JFloat f -> int_of_float f | _ -> 0

exception Bad_json of string

type scanner = { src : string; mutable pos : int }

let scan_skip sc =
  while
    sc.pos < String.length sc.src
    && (match sc.src.[sc.pos] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false)
  do
    sc.pos <- sc.pos + 1
  done

let scan_expect sc ch =
  if sc.pos >= String.length sc.src || sc.src.[sc.pos] <> ch then
    raise (Bad_json "unexpected character");
  sc.pos <- sc.pos + 1

let utf8_push buf cp =
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

let rec scan_string sc =
  scan_expect sc '"';
  let buf = Buffer.create 32 in
  let rec go () =
    if sc.pos >= String.length sc.src then raise (Bad_json "unterminated string");
    let ch = sc.src.[sc.pos] in
    if ch = '"' then begin
      sc.pos <- sc.pos + 1;
      Buffer.contents buf
    end
    else if ch = '\\' then begin
      sc.pos <- sc.pos + 1;
      if sc.pos >= String.length sc.src then raise (Bad_json "bad escape");
      let esc = sc.src.[sc.pos] in
      sc.pos <- sc.pos + 1;
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
           if sc.pos + 4 > String.length sc.src then raise (Bad_json "bad \\u");
           let cp = int_of_string ("0x" ^ String.sub sc.src sc.pos 4) in
           sc.pos <- sc.pos + 4;
           if cp >= 0xD800 && cp <= 0xDBFF && sc.pos + 6 <= String.length sc.src
              && sc.src.[sc.pos] = '\\' && sc.src.[sc.pos + 1] = 'u'
           then begin
             let lo = int_of_string ("0x" ^ String.sub sc.src (sc.pos + 2) 4) in
             if lo >= 0xDC00 && lo <= 0xDFFF then begin
               sc.pos <- sc.pos + 6;
               utf8_push buf (0x10000 + ((cp - 0xD800) lsl 10) + (lo - 0xDC00))
             end
             else utf8_push buf cp
           end
           else utf8_push buf cp
       | _ -> raise (Bad_json "bad escape char"));
      go ()
    end
    else begin
      Buffer.add_char buf ch;
      sc.pos <- sc.pos + 1;
      go ()
    end
  in
  go ()

and scan_value sc =
  scan_skip sc;
  if sc.pos >= String.length sc.src then raise (Bad_json "eof");
  match sc.src.[sc.pos] with
  | '{' ->
      sc.pos <- sc.pos + 1;
      scan_skip sc;
      if sc.pos < String.length sc.src && sc.src.[sc.pos] = '}' then begin
        sc.pos <- sc.pos + 1;
        JObj []
      end
      else
        let rec fields acc =
          scan_skip sc;
          let k = scan_string sc in
          scan_skip sc;
          scan_expect sc ':';
          let v = scan_value sc in
          scan_skip sc;
          if sc.pos < String.length sc.src && sc.src.[sc.pos] = ',' then begin
            sc.pos <- sc.pos + 1;
            fields ((k, v) :: acc)
          end
          else begin
            scan_expect sc '}';
            JObj (List.rev ((k, v) :: acc))
          end
        in
        fields []
  | '[' ->
      sc.pos <- sc.pos + 1;
      scan_skip sc;
      if sc.pos < String.length sc.src && sc.src.[sc.pos] = ']' then begin
        sc.pos <- sc.pos + 1;
        JArr []
      end
      else
        let rec elems acc =
          let v = scan_value sc in
          scan_skip sc;
          if sc.pos < String.length sc.src && sc.src.[sc.pos] = ',' then begin
            sc.pos <- sc.pos + 1;
            elems (v :: acc)
          end
          else begin
            scan_expect sc ']';
            JArr (List.rev (v :: acc))
          end
        in
        elems []
  | '"' -> JStr (scan_string sc)
  | 't' ->
      if String.sub sc.src sc.pos 4 <> "true" then raise (Bad_json "bad literal");
      sc.pos <- sc.pos + 4;
      JBool true
  | 'f' ->
      if String.sub sc.src sc.pos 5 <> "false" then raise (Bad_json "bad literal");
      sc.pos <- sc.pos + 5;
      JBool false
  | 'n' ->
      if String.sub sc.src sc.pos 4 <> "null" then raise (Bad_json "bad literal");
      sc.pos <- sc.pos + 4;
      JNull
  | _ ->
      let start = sc.pos in
      while
        sc.pos < String.length sc.src
        && (match sc.src.[sc.pos] with
            | '0' .. '9' | '-' | '+' | '.' | 'e' | 'E' -> true
            | _ -> false)
      do
        sc.pos <- sc.pos + 1
      done;
      let tok = String.sub sc.src start (sc.pos - start) in
      if String.contains tok '.' || String.contains tok 'e' || String.contains tok 'E'
      then JFloat (float_of_string tok)
      else JInt (int_of_string tok)

let parse_json src =
  let sc = { src; pos = 0 } in
  let v = scan_value sc in
  scan_skip sc;
  v

(* ---------------- canonical JSON ---------------- *)
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
             Buffer.add_string buf
               (Printf.sprintf "\\u%04x\\u%04x" (0xD800 + (v lsr 10)) (0xDC00 + (v land 0x3FF)))
           end
           else Buffer.add_string buf (Printf.sprintf "\\u%04x" cp)
         end
         else Buffer.add_char buf (Char.chr cp))
  done;
  Buffer.add_char buf '"'

let rec canon buf = function
  | JNull -> Buffer.add_string buf "null"
  | JBool b -> Buffer.add_string buf (if b then "true" else "false")
  | JInt n -> Buffer.add_string buf (string_of_int n)
  | JFloat f ->
      if Float.is_integer f then Buffer.add_string buf (Printf.sprintf "%d" (int_of_float f))
      else Buffer.add_string buf (Printf.sprintf "%.14g" f)
  | JStr s -> canon_string buf s
  | JArr elems ->
      Buffer.add_char buf '[';
      List.iteri (fun i e -> if i > 0 then Buffer.add_char buf ','; canon buf e) elems;
      Buffer.add_char buf ']'
  | JObj fields ->
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
