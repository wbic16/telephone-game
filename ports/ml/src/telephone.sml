fun dropWhile p [] = []
  | dropWhile p (x :: rest) = if p x then dropWhile p rest else x :: rest

(* telephone.sml - Exocortical Telephone Game CLI (contract v2) for
   the ML (Standard ML) libphext port. Wire: one JSON request in, one
   response out; arg "serve" loops over JSON lines. PGP via subprocess
   gpg on temp files, key home $TELEPHONE_GNUPG_HOME or
   ~/telephone-ml/gnupg. MLton target; Basis Library only. *)

structure Telephone =
struct

open Wire
open Phext

val impl = "ml"
val keyUid = "libphext telephone " ^ impl
val indexCoord = [1, 1, 1, 1, 1, 1, 1, 1, 1]
val keysCoord = [1, 1, 1, 1, 1, 1, 1, 1, 2]
val khCoord = [1, 1, 1, 1, 1, 1, 1, 1, 3]
val reserved = [indexCoord, keysCoord, khCoord]

fun stateBytes req =
  case jsonGet "state" req of
    JStr s => b64Decode s
  | _ => (case jsonGet "state_b64" req of JStr s => b64Decode s | _ => "")

fun shq s =
  "'" ^ String.concat (List.map (fn ch => if ch = #"'" then "'\\''" else String.str ch)
                                (String.explode s)) ^ "'"

fun slurp path =
  let
    val ins = BinIO.openIn path
    val data = BinIO.inputAll ins
    val () = BinIO.closeIn ins
  in Byte.bytesToString data end

fun spit path data =
  let
    val outs = BinIO.openOut path
    val () = BinIO.output (outs, Byte.stringToBytes data)
    val () = BinIO.closeOut outs
  in () end

fun shell cmd =
  let
    val tmp = OS.FileSys.tmpName ()
    val status = OS.Process.system (cmd ^ " > " ^ shq tmp ^ " 2>/tmp/telephone-ml.err")
  in
    if OS.Process.isSuccess status then
      let val out = (slurp tmp) handle _ => "" in
        (OS.FileSys.remove tmp handle _ => ()); out
      end
    else
      raise Fail ("command failed: " ^
        ((slurp "/tmp/telephone-ml.err") handle _ => ""))
  end

fun gnupgHome () =
  case OS.Process.getEnv "TELEPHONE_GNUPG_HOME" of
    SOME h => h
  | NONE => (case OS.Process.getEnv "HOME" of SOME h => h | NONE => "/home/wbic16")
            ^ "/telephone-" ^ impl ^ "/gnupg"

fun gpg args input =
  let
    val home = gnupgHome ()
    val _ = OS.Process.system ("mkdir -p " ^ shq home ^ " && chmod 700 " ^ shq home)
    val cmd = "gpg --batch --yes --pinentry-mode loopback --passphrase '' --homedir "
              ^ shq home ^ " " ^ args
  in
    case input of
      NONE => shell cmd
    | SOME data =>
        let
          val tmp = OS.FileSys.tmpName ()
          val () = spit tmp data
          val out = shell (cmd ^ " < " ^ shq tmp)
          val () = (OS.FileSys.remove tmp) handle _ => ()
        in out end
  end

fun contains hay needle =
  String.isSubstring needle hay

fun keygen () =
  let
    val listing = gpg "--list-keys --with-colons" NONE
  in
    (if not (contains listing "pub:")
     then ignore (gpg ("--quick-gen-key " ^ shq keyUid ^ " ed25519 sign never") NONE)
     else ());
    gpg ("--armor --export " ^ shq keyUid) NONE
  end

fun tempDir () =
  let
    val dir = OS.FileSys.tmpName ()
    val () = (OS.FileSys.remove dir) handle _ => ()
    val _ = OS.Process.system ("mkdir -p " ^ shq dir)
  in dir end

fun detachSign data =
  let
    val dir = tempDir ()
    val () = spit (dir ^ "/descriptor.json") data
    val _ = gpg ("--detach-sign --armor --local-user " ^ shq keyUid
                 ^ " --output " ^ shq (dir ^ "/descriptor.asc")
                 ^ " " ^ shq (dir ^ "/descriptor.json")) NONE
    val sig_ = slurp (dir ^ "/descriptor.asc")
    val _ = OS.Process.system ("rm -rf " ^ shq dir)
  in sig_ end

fun verifySignature pubkeys data sigText =
  let
    val dir = tempDir ()
    val home = dir ^ "/gnupg"
    val _ = OS.Process.system ("mkdir -p " ^ shq home ^ " && chmod 700 " ^ shq home)
    val () = spit (dir ^ "/keys.asc") pubkeys
    val () = spit (dir ^ "/descriptor.json") data
    val () = spit (dir ^ "/descriptor.asc") sigText
    val rc1 = OS.Process.system
      ("gpg --batch --yes --homedir " ^ shq home ^ " --import "
       ^ shq (dir ^ "/keys.asc") ^ " >/dev/null 2>&1")
    val ok = OS.Process.isSuccess rc1 andalso
      OS.Process.isSuccess (OS.Process.system
        ("gpg --batch --yes --homedir " ^ shq home ^ " --verify "
         ^ shq (dir ^ "/descriptor.asc") ^ " "
         ^ shq (dir ^ "/descriptor.json") ^ " >/dev/null 2>&1"))
    val _ = OS.Process.system ("rm -rf " ^ shq dir)
  in ok end

(* ---- game logic ---- *)
fun echoValue ping =
  let
    val game = jsonString (jsonGet "game" ping)
    val round =
      case jsonGet "round" ping of
        JInt n => Int.toString n
      | JStr s => s
      | _ => (case jsonGet "turn" ping of
                JInt n => Int.toString n
              | JStr s => s
              | _ => "")
    val nonce = jsonString (jsonGet "nonce" ping)
  in sha256Hex (impl ^ "|" ^ game ^ "|" ^ round ^ "|" ^ nonce) end

fun seedByte hex i =
  case Int.fromString ("0x" ^ String.substring (hex, i * 2, 2)) of
    SOME n => n
  | NONE => 0

fun electWinner position candidates turn =
  let
    val hex = sha256Hex (position ^ String.str (Char.chr (turn mod 256))
                         ^ String.concatWith "," candidates)
  in List.nth (candidates, seedByte hex 0 mod List.length candidates) end

fun nextCoord (c : coord) : coord =
  let
    val arr = Array.fromList c
    fun bump d =
      if d < 0 then ()
      else if Array.sub (arr, d) < 999 then Array.update (arr, d, Array.sub (arr, d) + 1)
      else (Array.update (arr, d, 1); bump (d - 1))
    val () = bump 8
  in Array.foldr (op ::) [] arr end

fun chooseAdventure state position turn =
  case parseCoordinate position of
    NONE => raise Fail ("invalid position " ^ position)
  | SOME pos =>
      let
        val used = explode state
        fun taken c = ScrollMap.mem used c
                      orelse List.exists (fn r => coordCompare (r, c) = EQUAL) reserved
        val seedHex = sha256Hex (position ^ String.str (Char.chr (turn mod 256)) ^ state)
        val dim = seedByte seedHex 1 mod 9
        val start = List.tabulate (9, fn i =>
          let val x = List.nth (pos, i)
          in if i = dim
             then ((x - 1 + 1 + (seedByte seedHex 2 mod 3)) mod 999) + 1
             else x end)
        fun seekFree c = if taken c then seekFree (nextCoord c) else c
        val cur = seekFree start
        val cs = formatCoordinate cur
      in
        JObj [ ("op", JStr "insert"), ("coordinate", JStr cs),
               ("text", JStr (impl ^ " turn " ^ Int.toString turn ^ " at " ^ cs)) ]
      end

fun applyStep state step =
  case parseCoordinate (jsonString (jsonGet "coordinate" step)) of
    NONE => (state, JNull)
  | SOME coord =>
      let val text = jsonString (jsonGet "text" step) in
        case jsonString (jsonGet "op" step) of
          "insert" => (insert state coord text, JNull)
        | "replace" => (replace state coord text, JNull)
        | "remove" => (remove state coord, JNull)
        | "fetch" => (state, JStr (sha256Hex (fetch state coord)))
        | _ => (state, JNull)
      end

fun vfail detail =
  JObj [ ("impl", JStr impl), ("verdict", JStr "fail"), ("detail", JStr detail) ]
fun vpass detail =
  JObj [ ("impl", JStr impl), ("verdict", JStr "pass"), ("detail", JStr detail) ]

fun validateStep newState step priorOpt =
  if jsonString (jsonGet "op" step) <> "insert" then vfail "step op is not insert"
  else
    case parseCoordinate (jsonString (jsonGet "coordinate" step)) of
      NONE => vfail "unparseable coordinate"
    | SOME coord =>
        if fetch newState coord <> jsonString (jsonGet "text" step)
        then vfail ("placed scroll absent or content differs at "
                    ^ jsonString (jsonGet "coordinate" step))
        else
          (case priorOpt of
             NONE => vpass "placed scroll present with attested content (no prior state supplied)"
           | SOME prior =>
               if fetch prior coord <> ""
               then vfail "coordinate was not unused in the prior state"
               else
                 let
                   val priorMap = explode prior
                   val after_ = explode newState
                 in
                   if ScrollMap.size after_ <> ScrollMap.size priorMap + 1
                   then vfail "scroll count did not grow by exactly one"
                   else
                     let
                       val bad = ScrollMap.foldl
                         (fn (c, t, acc) =>
                            case acc of
                              SOME _ => acc
                            | NONE => (case ScrollMap.get after_ c of
                                         SOME t2 => if t2 = t then NONE else SOME c
                                       | NONE => SOME c))
                         NONE priorMap
                     in
                       case bad of
                         SOME c => vfail ("a prior scroll was overwritten: " ^ formatCoordinate c)
                       | NONE => vpass "placed at unused coordinate; all prior scrolls intact"
                     end
                 end)

(* ---- serve-mode validator cache (init / driver-form validate) ---- *)
val cache : ScrollMap.t option ref = ref NONE

fun initCache state =
  (cache := SOME (explode state);
   JObj [ ("impl", JStr impl), ("verdict", JStr "pass") ])

fun stripNl s =
  if String.size s > 0 andalso String.sub (s, String.size s - 1) = #"\n"
  then stripNl (String.substring (s, 0, String.size s - 1))
  else s

fun endsWith s suffix =
  String.size suffix <= String.size s
  andalso String.substring (s, String.size s - String.size suffix,
                            String.size suffix) = suffix

fun validateDriver newState step eventCoordS indexLine =
  case !cache of
    NONE => vfail "no prior state (init not called)"
  | SOME old =>
      let
        val newMap = explode newState
      in
        case parseCoordinate (jsonString (jsonGet "coordinate" step)) of
          NONE => vfail "unparseable coordinate"
        | SOME coord =>
            if ScrollMap.get newMap coord <> SOME (jsonString (jsonGet "text" step))
            then vfail "placed scroll missing or altered"
            else
              let
                val overwritten = ScrollMap.foldl
                  (fn (c, text, acc) =>
                     case acc of
                       SOME _ => acc
                     | NONE =>
                         if coordCompare (c, indexCoord) = EQUAL then NONE
                         else (case ScrollMap.get newMap c of
                                 SOME t => if t = text then NONE else SOME c
                               | NONE => SOME c))
                  NONE old
              in
                case overwritten of
                  SOME c => vfail ("prior scroll overwritten at " ^ formatCoordinate c)
                | NONE =>
                    let
                      val unexpected = ScrollMap.foldl
                        (fn (c, _, acc) =>
                           case acc of
                             SOME _ => acc
                           | NONE =>
                               if ScrollMap.mem old c then NONE
                               else if formatCoordinate c = formatCoordinate coord then NONE
                               else if formatCoordinate c = eventCoordS then NONE
                               else SOME c)
                        NONE newMap
                    in
                      case unexpected of
                        SOME c => vfail ("unexpected new scroll at " ^ formatCoordinate c)
                      | NONE =>
                          let
                            val idx = case ScrollMap.get newMap indexCoord of
                                        SOME t => t | NONE => ""
                          in
                            if not (endsWith (stripNl idx) (stripNl indexLine))
                            then vfail "index does not record the placement"
                            else (cache := SOME newMap;
                                  JObj [ ("impl", JStr impl), ("verdict", JStr "pass") ])
                          end
                    end
              end
      end

fun splitWs line =
  String.fields (fn ch => ch = #" " orelse ch = #"\t") line

fun trim s =
  let
    val cs = String.explode s
    val cs = List.rev (dropWhile Char.isSpace (List.rev (dropWhile Char.isSpace cs)))
  in String.implode cs end

fun verifyGame state pubkeys =
  let
    fun fail msg checked =
      JObj [ ("impl", JStr impl), ("verdict", JStr "fail"),
             ("placements_checked", JInt checked),
             ("first_failure", JObj [ ("detail", JStr msg) ]) ]
    val scrolls = explode state
    val keysText = case ScrollMap.get scrolls keysCoord of SOME t => t | NONE => ""
  in
    if keysText = "" then fail ("no public-keys scroll at " ^ formatCoordinate keysCoord) 0
    else if trim pubkeys <> trim keysText
    then fail "supplied pubkeys do not match the inscribed keys scroll" 0
    else if not (ScrollMap.mem scrolls khCoord)
    then fail ("no keys-hash scroll at " ^ formatCoordinate khCoord) 0
    else if trim (valOf (ScrollMap.get scrolls khCoord)) <> sha256Hex keysText
    then fail "keys-hash scroll does not match the keys scroll" 0
    else
      let
        val indexText = case ScrollMap.get scrolls indexCoord of SOME t => t | NONE => ""
        val lines = List.map trim (String.fields (fn ch => ch = #"\n") indexText)
        val entryLines = List.filter
          (fn l => l <> "" andalso String.sub (l, 0) <> #"#") lines
        val parsed = List.map splitWs entryLines
      in
        if List.exists (fn f => List.length f <> 4) parsed
        then fail "malformed index line" 0
        else
          let
            val index = List.map (fn [t, c, h, a] => (c, (t, h, a)) | _ => ("", ("", "", ""))) parsed
            fun indexGet c = case List.find (fn (k, _) => k = c) index of
                               SOME (_, v) => SOME v | NONE => NONE
            fun walk seq prevHash seen checked =
              let
                val ecoord = [1, 1, 1, 1, 1, 1, 2, 1, seq]
              in
                case ScrollMap.get scrolls ecoord of
                  NONE =>
                    if checked = 0 then fail "no placement events found" 0
                    else
                      (case List.find (fn (cs, _) => not (List.exists (fn x => x = cs) seen)) index of
                         SOME (cs, _) => fail ("index lists a placement with no event: " ^ cs) checked
                       | NONE => JObj [ ("impl", JStr impl), ("verdict", JStr "pass"),
                                        ("placements_checked", JInt checked),
                                        ("first_failure", JNull) ])
                | SOME evText =>
                    (case (parseJson evText) handle _ => JNull of
                       ev as JObj _ =>
                         let val body = jsonGet "body" ev in
                           case body of
                             JObj _ =>
                               let
                                 val prevOk =
                                   case (jsonGet "prev" ev, prevHash) of
                                     (JNull, NONE) => true
                                   | (JStr p, SOME ph) => p = ph
                                   | _ => false
                               in
                                 if not prevOk
                                 then fail (if seq = 1 then "event 1 prev is not null"
                                            else "event chain broken at seq " ^ Int.toString seq) checked
                                 else
                                   let
                                     val newPrev = sha256Hex (canonJson body)
                                   in
                                     if jsonString (jsonGet "type" body) <> "placement"
                                     then walk (seq + 1) (SOME newPrev) seen checked
                                     else
                                       let
                                         val coordStr = jsonString (jsonGet "coord" body)
                                         val textHash = jsonString (jsonGet "text_sha256" body)
                                         val fileHash = jsonString (jsonGet "file_sha256" body)
                                         val attB64 = jsonString (jsonGet "att" body)
                                         val turn = jsonInt (jsonGet "turn" body)
                                         val actor = jsonString (jsonGet "actor" body)
                                       in
                                         if coordStr = "" orelse textHash = "" orelse fileHash = "" orelse attB64 = ""
                                         then fail ("event " ^ Int.toString seq ^ " lacks coord/text_sha256/file_sha256/att") checked
                                         else if List.exists (fn x => x = coordStr) seen
                                         then fail ("coordinate reused at " ^ coordStr) checked
                                         else
                                           (case parseCoordinate coordStr of
                                              NONE => fail ("bad coordinate " ^ coordStr) checked
                                            | SOME coord =>
                                                if not (ScrollMap.mem scrolls coord)
                                                then fail ("placement missing at " ^ coordStr) checked
                                                else if sha256Hex (valOf (ScrollMap.get scrolls coord)) <> textHash
                                                then fail ("placement hash mismatch at " ^ coordStr) checked
                                                else
                                                  (case indexGet coordStr of
                                                     SOME (iturn, ihash, iactor) =>
                                                       if ihash = textHash andalso iturn = Int.toString turn andalso iactor = actor
                                                       then
                                                         let
                                                           val desc = JObj
                                                             [ ("turn", JInt turn),
                                                               ("coordinate", JStr coordStr),
                                                               ("scroll_sha256", JStr textHash),
                                                               ("file_sha256", JStr fileHash) ]
                                                         in
                                                           if verifySignature keysText (canonJson desc) (b64Decode attB64)
                                                           then walk (seq + 1) (SOME newPrev) (coordStr :: seen) (checked + 1)
                                                           else fail ("event " ^ Int.toString seq ^ " signature invalid") checked
                                                         end
                                                       else fail ("index mismatch at " ^ coordStr) checked
                                                   | NONE => fail ("index mismatch at " ^ coordStr) checked))
                                       end
                                   end
                               end
                           | _ => fail ("event " ^ Int.toString seq ^ " is not a JSON object") checked
                         end
                     | _ => fail ("event " ^ Int.toString seq ^ " is not a JSON object") checked)
              end
          in walk 1 NONE [] 0 end
      end
  end

fun dispatch req =
  case jsonString (jsonGet "cmd" req) of
    "id" => JObj [ ("impl", JStr impl) ]
  | "echo" => JObj [ ("impl", JStr impl), ("echo", JStr (echoValue (jsonGet "ping" req))) ]
  | "elect" =>
      let
        val cands = case jsonGet "candidates" req of
                      JArr elems => List.map jsonString elems
                    | _ => []
      in
        if null cands then raise Fail "elect: no candidates"
        else JObj [ ("elect", JStr (electWinner
                      (jsonString (jsonGet "position" req)) cands
                      (jsonInt (jsonGet "turn" req)))) ]
      end
  | "choose" => chooseAdventure (stateBytes req)
                  (jsonString (jsonGet "position" req)) (jsonInt (jsonGet "turn" req))
  | "apply" =>
      let val (ns, fh) = applyStep (stateBytes req) (jsonGet "step" req)
      in JObj [ ("state_b64", JStr (b64Encode ns)),
                ("state_sha256", JStr (sha256Hex ns)),
                ("fetch_sha256", fh) ] end
  | "keygen" => JObj [ ("impl", JStr impl), ("pubkey", JStr (keygen ())) ]
  | "attest" => JObj [ ("signature", JStr (detachSign (canonJson (jsonGet "descriptor" req)))) ]
  | "init" => initCache (stateBytes req)
  | "validate" =>
      (case jsonGet "event_coord" req of
         JStr _ => validateDriver (stateBytes req) (jsonGet "step" req)
                     (jsonString (jsonGet "event_coord" req))
                     (jsonString (jsonGet "index_line" req))
       | _ =>
           let
             val priorOpt = case jsonGet "prior_state" req of
                              JStr s => SOME (b64Decode s)
                            | _ => NONE
           in validateStep (stateBytes req) (jsonGet "step" req) priorOpt end)
  | "verify" => verifyGame (stateBytes req) (jsonString (jsonGet "pubkeys" req))
  | other => raise Fail ("unknown cmd " ^ other)

(* Game-scale framing: lines over 8 KB may arrive gzip-framed as
   "GZ1:" + base64(gzip(line)) - the fleet-ssh channel is ~25-70 KB/s.
   The Basis Library has no zlib, so (de)compression shells to gzip(1)
   on temp files. Lossless; plain lines unchanged. *)
fun gzVia data flag =
  let
    val fin = OS.FileSys.tmpName ()
    val fout = OS.FileSys.tmpName ()
    val () = spit fin data
    val _ = OS.Process.system ("gzip " ^ flag ^ " " ^ shq fin ^ " > " ^ shq fout)
    val out = slurp fout
    val () = (OS.FileSys.remove fin) handle _ => ()
    val () = (OS.FileSys.remove fout) handle _ => ()
  in out end

fun gzUnframe s = gzVia (b64Decode (String.substring (s, 4, String.size s - 4))) "-dc"
fun gzFrame s = "GZ1:" ^ b64Encode (gzVia s "-c")

fun startsWith s prefix =
  String.size s >= String.size prefix
  andalso String.substring (s, 0, String.size prefix) = prefix

fun main () =
  let
    val args = CommandLine.arguments ()
  in
    if List.exists (fn a => a = "serve") args then
      let
        fun loop () =
          case TextIO.inputLine TextIO.stdIn of
            NONE => ()
          | SOME raw =>
              let
                val line0 = raw
                val line = if String.size line0 > 0
                              andalso String.sub (line0, String.size line0 - 1) = #"\n"
                           then String.substring (line0, 0, String.size line0 - 1)
                           else line0
              in
                if trim line = "" then loop ()
                else
                  let
                    val line = if startsWith line "GZ1:" then gzUnframe line else line
                    val out = (dispatch (parseJson line))
                              handle e => JObj [ ("error", JStr (exnMessage e)) ]
                    val outj = canonJson out
                    val outLine = if String.size outj > 8192 then gzFrame outj else outj
                  in
                    TextIO.output (TextIO.stdOut, outLine ^ "\n");
                    TextIO.flushOut TextIO.stdOut;
                    loop ()
                  end
              end
      in loop () end
    else
      let
        val raw = TextIO.inputAll TextIO.stdIn
        val req = parseJson raw
        val out = dispatch req
      in
        TextIO.output (TextIO.stdOut, canonJson out ^ "\n");
        TextIO.flushOut TextIO.stdOut
      end
  end

end

val () = Telephone.main ()
