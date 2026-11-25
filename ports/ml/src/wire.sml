(* wire.sml - SHA-256, base64 and canonical JSON for the ML (Standard
   ML) libphext port. SHA-256 is written from FIPS 180-4 with Word32
   arithmetic (the Basis Library has no SHA-256). JSON output is
   canonical: keys sorted, compact separators, strings escaped the
   way Python's json.dumps(ensure_ascii=True) escapes them, so hashes
   over canonical text agree byte-for-byte with the other ports.
   MLton target; Basis Library only. *)

structure Wire =
struct

(* ---------------- SHA-256 ---------------- *)
val kTable = Vector.fromList
  [ 0wx428a2f98, 0wx71374491, 0wxb5c0fbcf, 0wxe9b5dba5, 0wx3956c25b, 0wx59f111f1,
    0wx923f82a4, 0wxab1c5ed5, 0wxd807aa98, 0wx12835b01, 0wx243185be, 0wx550c7dc3,
    0wx72be5d74, 0wx80deb1fe, 0wx9bdc06a7, 0wxc19bf174, 0wxe49b69c1, 0wxefbe4786,
    0wx0fc19dc6, 0wx240ca1cc, 0wx2de92c6f, 0wx4a7484aa, 0wx5cb0a9dc, 0wx76f988da,
    0wx983e5152, 0wxa831c66d, 0wxb00327c8, 0wxbf597fc7, 0wxc6e00bf3, 0wxd5a79147,
    0wx06ca6351, 0wx14292967, 0wx27b70a85, 0wx2e1b2138, 0wx4d2c6dfc, 0wx53380d13,
    0wx650a7354, 0wx766a0abb, 0wx81c2c92e, 0wx92722c85, 0wxa2bfe8a1, 0wxa81a664b,
    0wxc24b8b70, 0wxc76c51a3, 0wxd192e819, 0wxd6990624, 0wxf40e3585, 0wx106aa070,
    0wx19a4c116, 0wx1e376c08, 0wx2748774c, 0wx34b0bcb5, 0wx391c0cb3, 0wx4ed8aa4a,
    0wx5b9cca4f, 0wx682e6ff3, 0wx748f82ee, 0wx78a5636f, 0wx84c87814, 0wx8cc70208,
    0wx90befffa, 0wxa4506ceb, 0wxbef9a3f7, 0wxc67178f2 ]

fun rotr (x : Word32.word, n) =
  Word32.orb (Word32.>> (x, Word.fromInt n), Word32.<< (x, Word.fromInt (32 - n)))

fun sha256Hex (msg : string) : string =
  let
    val len = String.size msg
    val total = ((len + 9 + 63) div 64) * 64
    val data = Word8Array.array (total, 0w0)
    val () = Word8Array.copyVec { src = Byte.stringToBytes msg, dst = data, di = 0 }
    val () = Word8Array.update (data, len, 0wx80)
    val bits = IntInf.fromInt len * 8
    val () =
      let
        fun put i =
          if i > 7 then ()
          else (Word8Array.update (data, total - 8 + i,
                  Word8.fromInt (IntInf.toInt (IntInf.andb
                    (IntInf.~>> (bits, Word.fromInt ((7 - i) * 8)), 0xff))));
                put (i + 1))
      in put 0 end
    val h = Array.fromList
      [ 0wx6a09e667, 0wxbb67ae85, 0wx3c6ef372, 0wxa54ff53a,
        0wx510e527f, 0wx9b05688c, 0wx1f83d9ab, 0wx5be0cd19 ]
    val w = Array.array (64, 0w0 : Word32.word)
    fun byteAt i = Word32.fromInt (Word8.toInt (Word8Array.sub (data, i)))
    fun compress chunk =
      let
        val base = chunk * 64
        val () =
          let fun init i =
                if i > 15 then ()
                else (Array.update (w, i,
                        Word32.orb (Word32.<< (byteAt (base + i * 4), 0w24),
                        Word32.orb (Word32.<< (byteAt (base + i * 4 + 1), 0w16),
                        Word32.orb (Word32.<< (byteAt (base + i * 4 + 2), 0w8),
                                    byteAt (base + i * 4 + 3)))));
                      init (i + 1))
          in init 0 end
        val () =
          let fun ext i =
                if i > 63 then ()
                else
                  let
                    val x15 = Array.sub (w, i - 15)
                    val x2 = Array.sub (w, i - 2)
                    val s0 = Word32.xorb (Word32.xorb (rotr (x15, 7), rotr (x15, 18)),
                                          Word32.>> (x15, 0w3))
                    val s1 = Word32.xorb (Word32.xorb (rotr (x2, 17), rotr (x2, 19)),
                                          Word32.>> (x2, 0w10))
                  in
                    Array.update (w, i, Array.sub (w, i - 16) + s0 + Array.sub (w, i - 7) + s1);
                    ext (i + 1)
                  end
          in ext 16 end
        val v = Array.tabulate (8, fn i => Array.sub (h, i))
        val () =
          let fun round i =
                if i > 63 then ()
                else
                  let
                    val a = Array.sub (v, 0) val b = Array.sub (v, 1)
                    val c = Array.sub (v, 2) val d = Array.sub (v, 3)
                    val e = Array.sub (v, 4) val f = Array.sub (v, 5)
                    val g = Array.sub (v, 6) val hh = Array.sub (v, 7)
                    val s1 = Word32.xorb (Word32.xorb (rotr (e, 6), rotr (e, 11)), rotr (e, 25))
                    val ch = Word32.xorb (Word32.andb (e, f), Word32.andb (Word32.notb e, g))
                    val t1 = hh + s1 + ch + Vector.sub (kTable, i) + Array.sub (w, i)
                    val s0 = Word32.xorb (Word32.xorb (rotr (a, 2), rotr (a, 13)), rotr (a, 22))
                    val maj = Word32.xorb (Word32.xorb (Word32.andb (a, b), Word32.andb (a, c)),
                                           Word32.andb (b, c))
                    val t2 = s0 + maj
                  in
                    Array.update (v, 7, g); Array.update (v, 6, f);
                    Array.update (v, 5, e); Array.update (v, 4, d + t1);
                    Array.update (v, 3, c); Array.update (v, 2, b);
                    Array.update (v, 1, a); Array.update (v, 0, t1 + t2);
                    round (i + 1)
                  end
          in round 0 end
        val () =
          let fun add i =
                if i > 7 then ()
                else (Array.update (h, i, Array.sub (h, i) + Array.sub (v, i)); add (i + 1))
          in add 0 end
      in () end
    val () =
      let fun chunks c =
            if c >= total div 64 then () else (compress c; chunks (c + 1))
      in chunks 0 end
    val hexdigits = "0123456789abcdef"
    fun wordHex (x : Word32.word) =
      let
        fun nib s = String.sub (hexdigits, Word32.toInt (Word32.andb (Word32.>> (x, Word.fromInt s), 0wxf)))
      in String.implode [nib 28, nib 24, nib 20, nib 16, nib 12, nib 8, nib 4, nib 0] end
  in
    String.concat (List.tabulate (8, fn i => wordHex (Array.sub (h, i))))
  end

(* ---------------- base64 ---------------- *)
val b64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

fun b64Encode (data : string) : string =
  let
    val n = String.size data
    fun byte i = if i < n then Char.ord (String.sub (data, i)) else 0
    fun go i acc =
      if i >= n then String.concat (List.rev acc)
      else
        let
          val v = (byte i * 65536) + (byte (i + 1) * 256) + byte (i + 2)
          fun ch s = String.sub (b64Alphabet, (v div s) mod 64)
        in
          go (i + 3)
            ((String.implode
               [ ch 262144, ch 4096,
                 if i + 1 < n then ch 64 else #"=",
                 if i + 2 < n then ch 1 else #"=" ]) :: acc)
        end
  in go 0 [] end

fun b64Value (ch : char) : int =
  if ch >= #"A" andalso ch <= #"Z" then Char.ord ch - 65
  else if ch >= #"a" andalso ch <= #"z" then Char.ord ch - 71
  else if ch >= #"0" andalso ch <= #"9" then Char.ord ch + 4
  else if ch = #"+" then 62
  else if ch = #"/" then 63
  else ~1

fun b64Decode (data : string) : string =
  let
    val clean = String.implode (List.filter (fn ch => b64Value ch >= 0 orelse ch = #"=") (String.explode data))
    val n = String.size clean
    fun go i acc =
      if i + 4 > n then String.concat (List.rev acc)
      else
        let
          val c3 = String.sub (clean, i + 2)
          val c4 = String.sub (clean, i + 3)
          val v = (b64Value (String.sub (clean, i)) * 262144)
                + (b64Value (String.sub (clean, i + 1)) * 4096)
                + ((if c3 = #"=" then 0 else b64Value c3) * 64)
                + (if c4 = #"=" then 0 else b64Value c4)
          val b1 = Char.chr ((v div 65536) mod 256)
          val b2 = Char.chr ((v div 256) mod 256)
          val b3 = Char.chr (v mod 256)
        in
          go (i + 4) ((String.implode
            (b1 :: (if c3 = #"=" then [] else b2 :: (if c4 = #"=" then [] else [b3])))) :: acc)
        end
  in go 0 [] end

(* ---------------- JSON ---------------- *)
datatype json =
    JNull
  | JBool of bool
  | JInt of int
  | JFloat of real
  | JStr of string
  | JArr of json list
  | JObj of (string * json) list

fun jsonGet key (JObj fields) =
      (case List.find (fn (k, _) => k = key) fields of
         SOME (_, v) => v
       | NONE => JNull)
  | jsonGet _ _ = JNull

fun jsonString (JStr s) = s
  | jsonString _ = ""

fun jsonInt (JInt n) = n
  | jsonInt (JFloat f) = Real.floor f
  | jsonInt _ = 0

exception BadJson of string

fun utf8EncodeCp cp =
  if cp < 0x80 then String.str (Char.chr cp)
  else if cp < 0x800 then
    String.implode [Char.chr (0xC0 + (cp div 64)), Char.chr (0x80 + (cp mod 64))]
  else if cp < 0x10000 then
    String.implode [ Char.chr (0xE0 + (cp div 4096)),
                     Char.chr (0x80 + ((cp div 64) mod 64)),
                     Char.chr (0x80 + (cp mod 64)) ]
  else
    String.implode [ Char.chr (0xF0 + (cp div 262144)),
                     Char.chr (0x80 + ((cp div 4096) mod 64)),
                     Char.chr (0x80 + ((cp div 64) mod 64)),
                     Char.chr (0x80 + (cp mod 64)) ]

fun parseJson (src : string) : json =
  let
    val len = String.size src
    val pos = ref 0
    fun peek () = if !pos < len then SOME (String.sub (src, !pos)) else NONE
    fun next () =
      if !pos >= len then raise BadJson "eof"
      else let val ch = String.sub (src, !pos) in pos := !pos + 1; ch end
    fun skip () =
      while (!pos < len andalso
             (case String.sub (src, !pos) of #" " => true | #"\t" => true
              | #"\n" => true | #"\r" => true | _ => false))
        do pos := !pos + 1
    fun expect ch =
      if next () <> ch then raise BadJson "unexpected character" else ()
    fun hex4 () =
      let
        fun hv ch =
          if ch >= #"0" andalso ch <= #"9" then Char.ord ch - 48
          else if ch >= #"a" andalso ch <= #"f" then Char.ord ch - 87
          else if ch >= #"A" andalso ch <= #"F" then Char.ord ch - 55
          else raise BadJson "bad \\u"
        val a = hv (next ()) val b = hv (next ())
        val c = hv (next ()) val d = hv (next ())
      in ((a * 16 + b) * 16 + c) * 16 + d end
    fun parseString () =
      let
        val () = expect #"\""
        fun go acc =
          let val ch = next () in
            if ch = #"\"" then String.concat (List.rev acc)
            else if ch = #"\\" then
              let val esc = next () in
                case esc of
                  #"n" => go ("\n" :: acc)
                | #"t" => go ("\t" :: acc)
                | #"r" => go ("\r" :: acc)
                | #"b" => go ("\b" :: acc)
                | #"f" => go ("\f" :: acc)
                | #"/" => go ("/" :: acc)
                | #"\\" => go ("\\" :: acc)
                | #"\"" => go ("\"" :: acc)
                | #"u" =>
                    let val cp = hex4 () in
                      if cp >= 0xD800 andalso cp <= 0xDBFF andalso !pos + 6 <= len
                         andalso String.sub (src, !pos) = #"\\"
                         andalso String.sub (src, !pos + 1) = #"u"
                      then
                        let
                          val save = !pos
                          val () = pos := !pos + 2
                          val lo = hex4 ()
                        in
                          if lo >= 0xDC00 andalso lo <= 0xDFFF
                          then go (utf8EncodeCp (0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)) :: acc)
                          else (pos := save; go (utf8EncodeCp cp :: acc))
                        end
                      else go (utf8EncodeCp cp :: acc)
                    end
                | _ => raise BadJson "bad escape"
              end
            else go (String.str ch :: acc)
          end
      in go [] end
    fun parseValue () =
      let
        val () = skip ()
      in
        case peek () of
          NONE => raise BadJson "eof"
        | SOME #"{" => parseObj ()
        | SOME #"[" => parseArr ()
        | SOME #"\"" => JStr (parseString ())
        | SOME #"t" => (expectWord "true"; JBool true)
        | SOME #"f" => (expectWord "false"; JBool false)
        | SOME #"n" => (expectWord "null"; JNull)
        | SOME _ => parseNumber ()
      end
    and expectWord word =
      let
        fun go [] = ()
          | go (ch :: rest) = (expect ch; go rest)
      in go (String.explode word) end
    and parseObj () =
      let
        val () = expect #"{"
        val () = skip ()
      in
        case peek () of
          SOME #"}" => (pos := !pos + 1; JObj [])
        | _ =>
            let
              fun fields acc =
                let
                  val () = skip ()
                  val k = parseString ()
                  val () = skip ()
                  val () = expect #":"
                  val v = parseValue ()
                  val () = skip ()
                in
                  case next () of
                    #"," => fields ((k, v) :: acc)
                  | #"}" => JObj (List.rev ((k, v) :: acc))
                  | _ => raise BadJson "expected , or } in object"
                end
            in fields [] end
      end
    and parseArr () =
      let
        val () = expect #"["
        val () = skip ()
      in
        case peek () of
          SOME #"]" => (pos := !pos + 1; JArr [])
        | _ =>
            let
              fun elems acc =
                let
                  val v = parseValue ()
                  val () = skip ()
                in
                  case next () of
                    #"," => elems (v :: acc)
                  | #"]" => JArr (List.rev (v :: acc))
                  | _ => raise BadJson "expected , or ] in array"
                end
            in elems [] end
      end
    and parseNumber () =
      let
        val start = !pos
        fun isNumCh ch = Char.isDigit ch orelse ch = #"-" orelse ch = #"+"
                         orelse ch = #"." orelse ch = #"e" orelse ch = #"E"
        val () = while (!pos < len andalso isNumCh (String.sub (src, !pos)))
                   do pos := !pos + 1
        val tok = String.substring (src, start, !pos - start)
      in
        if tok = "" then raise BadJson "bad value"
        else if String.isSubstring "." tok orelse String.isSubstring "e" tok
                orelse String.isSubstring "E" tok
        then (case Real.fromString tok of SOME r => JFloat r | NONE => raise BadJson "bad number")
        else (case Int.fromString tok of SOME n => JInt n | NONE => raise BadJson "bad number")
      end
    val v = parseValue ()
    val () = skip ()
  in v end

(* ---------------- canonical JSON ---------------- *)
fun decodeUtf8 (s : string) : int list =
  let
    val n = String.size s
    fun byte i = Char.ord (String.sub (s, i))
    fun cont i = (byte i) mod 64
    fun go i acc =
      if i >= n then List.rev acc
      else
        let val b = byte i in
          if b < 0x80 then go (i + 1) (b :: acc)
          else if b < 0xE0 then go (i + 2) (((b mod 32) * 64 + cont (i + 1)) :: acc)
          else if b < 0xF0 then go (i + 3) (((b mod 16) * 4096 + cont (i + 1) * 64 + cont (i + 2)) :: acc)
          else go (i + 4) (((b mod 8) * 262144 + cont (i + 1) * 4096 + cont (i + 2) * 64 + cont (i + 3)) :: acc)
        end
  in go 0 [] end

fun canonString (s : string) : string =
  let
    fun hex4 n =
      let val d = "0123456789abcdef"
      in String.implode [ String.sub (d, (n div 4096) mod 16), String.sub (d, (n div 256) mod 16),
                          String.sub (d, (n div 16) mod 16), String.sub (d, n mod 16) ] end
    fun esc cp =
      if cp = 0x22 then "\\\""
      else if cp = 0x5C then "\\\\"
      else if cp = 0x08 then "\\b"
      else if cp = 0x0C then "\\f"
      else if cp = 0x0A then "\\n"
      else if cp = 0x0D then "\\r"
      else if cp = 0x09 then "\\t"
      else if cp < 0x20 orelse cp > 0x7E then
        if cp > 0xFFFF then
          let val v = cp - 0x10000
          in "\\u" ^ hex4 (0xD800 + v div 1024) ^ "\\u" ^ hex4 (0xDC00 + v mod 1024) end
        else "\\u" ^ hex4 cp
      else String.str (Char.chr cp)
  in "\"" ^ String.concat (List.map esc (decodeUtf8 s)) ^ "\"" end

fun canonJson value =
  let
    fun go JNull = "null"
      | go (JBool b) = if b then "true" else "false"
      | go (JInt n) = Int.toString n
      | go (JFloat f) =
          if Real.isFinite f andalso Real.== (f, Real.fromInt (Real.floor f))
          then Int.toString (Real.floor f)
          else Real.toString f
      | go (JStr s) = canonString s
      | go (JArr elems) = "[" ^ String.concatWith "," (List.map go elems) ^ "]"
      | go (JObj fields) =
          let
            fun insert (x as (xk, _)) [] = [x]
              | insert (x as (xk, _)) ((y as (yk, _)) :: rest) =
                  if xk <= yk then x :: y :: rest else y :: insert x rest
            fun isort [] = []
              | isort (x :: rest) = insert x (isort rest)
            val sorted = isort fields
          in
            "{" ^ String.concatWith ","
              (List.map (fn (k, v) => canonString k ^ ":" ^ go v) sorted) ^ "}"
          end
  in go value end

end
