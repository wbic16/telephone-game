(* Test suite for the ML (Standard ML) libphext port. Build/run via
   tests/run_tests.sh; fixtures via PHEXT_FIXTURES env. *)

structure TestPhext =
struct

open Phext

val failures = ref 0

fun check cond name =
  if cond then print ("ok - " ^ name ^ "\n")
  else (failures := !failures + 1; print ("FAIL - " ^ name ^ "\n"))

fun coord s =
  case parseCoordinate s of SOME c => c | NONE => raise Fail ("bad coord " ^ s)

fun slurpBytes path =
  let
    val ins = BinIO.openIn path
    val data = BinIO.inputAll ins
    val () = BinIO.closeIn ins
  in Byte.bytesToString data end

fun collect dir acc =
  let
    val ds = OS.FileSys.openDir dir
    fun go acc =
      case OS.FileSys.readDir ds of
        NONE => (OS.FileSys.closeDir ds; acc)
      | SOME name =>
          let
            val p = dir ^ "/" ^ name
          in
            if OS.FileSys.isDir p then go (collect p acc)
            else if name = "input.phext" then go (p :: acc)
            else go acc
          end
  in go acc end

fun main () =
  let
    val () = check (formatCoordinate (coord "1.2.3/4.5.6/7.8.9") = "1.2.3/4.5.6/7.8.9")
                   "coordinate round trip"
    val () = check (parseCoordinate "0.1.1/1.1.1/1.1.1" = NONE) "coordinate rejects 0"
    val () = check (parseCoordinate "1.1.1/1.1.1" = NONE) "coordinate rejects short"
    val () = check (coordCompare (coord "1.1.1/1.1.1/1.1.9", coord "1.1.1/1.1.1/1.1.2") = GREATER)
                   "order: section beats scroll"
    val () = check (coordCompare (coord "2.1.1/1.1.1/1.1.1", coord "10.1.1/1.1.1/1.1.1") = LESS)
                   "order: numeric not string"
    val buf = "a\023b\024c\001d"
    val scrolls = phokenize buf
    val got = List.map (fn s => formatCoordinate (#coord s) ^ ":" ^ #text s) scrolls
    val () = check (got = [ "1.1.1/1.1.1/1.1.1:a", "1.1.1/1.1.1/1.1.2:b",
                            "1.1.1/1.1.1/1.2.1:c", "2.1.1/1.1.1/1.1.1:d" ])
                   "phokenize breaks"
    val () = check (dephokenize scrolls = buf) "dephokenize round trip"
    val s1 = phokenize "line1\nline2"
    val () = check (List.length s1 = 1 andalso #text (List.hd s1) = "line1\nline2")
                   "newline is text"
    val () = check (fetch "hello" (coord "1.1.1/1.1.1/1.1.2") = "") "gap fetch is empty"
    val () = check (fetch "hello" (coord "9.9.9/9.9.9/9.9.9") = "") "far gap fetch is empty"
    val () = check (fetch "hello" (coord "1.1.1/1.1.1/1.1.1") = "hello") "fetch hit"
    val buf1 = insert "base" (coord "1.1.1/1.1.1/1.1.1") "+more"
    val () = check (fetch buf1 (coord "1.1.1/1.1.1/1.1.1") = "base+more")
                   "insert merges existing+inserted"
    val buf2 = insert buf1 (coord "1.1.1/1.1.1/1.1.3") "third"
    val () = check (buf2 = "base+more\023\023third") "insert creates in canonical position"
    val buf3 = replace "a\023b\023c" (coord "1.1.1/1.1.1/1.1.2") "B"
    val () = check (buf3 = "a\023B\023c") "replace overwrites"
    val buf4 = remove buf3 (coord "1.1.1/1.1.1/1.1.2")
    val () = check (buf4 = "a\023\023c") "remove coordinate-preserving: c stays at scroll 3"
    val () = check (fetch buf4 (coord "1.1.1/1.1.1/1.1.2") = "") "fetch after remove is empty"
    val () = check (fetch buf4 (coord "1.1.1/1.1.1/1.1.3") = "c")
                   "later scroll did NOT shift after remove"
    val () = check (remove buf4 (coord "5.5.5/5.5.5/5.5.5") = buf4) "remove gap is no-op"
    val m = explode "x\023y\001z"
    val () = check (ScrollMap.size m = 3 andalso implode m = "x\023y\001z")
                   "explode/implode round trip"
    (* store equivalence *)
    val ops = [ ("insert", "1.1.1/1.1.1/1.1.1", "+X"), ("insert", "1.1.1/1.1.1/1.1.3", "third"),
                ("replace", "1.1.1/1.1.1/1.1.2", "B"), ("remove", "1.1.1/1.1.1/1.1.1", ""),
                ("insert", "2.1.1/1.1.1/1.1.1", "lib2"), ("remove", "1.1.1/1.1.1/1.1.3", ""),
                ("replace", "9.9.9/9.9.9/9.9.9", "far"), ("insert", "1.1.1/1.1.1/1.1.2", "-tail") ]
    val d = dynamicCreate "a\023b"
    val t = transitiveCreate "a\023b"
    val refr = ref "a\023b"
    val () = List.app
      (fn (kind, at, text) =>
         let
           val c = coord at
           val () = case kind of
                      "insert" => (dynamicInsert d c text; transitiveInsert t c text;
                                   refr := insert (!refr) c text)
                    | "replace" => (dynamicReplace d c text; transitiveReplace t c text;
                                    refr := replace (!refr) c text)
                    | _ => (dynamicRemove d c; transitiveRemove t c;
                            refr := remove (!refr) c)
           val want = normalize (!refr)
         in
           check (dynamicSerialize d = want)
                 ("DynamicPhext serialize matches after " ^ kind ^ " " ^ at);
           check (transitiveSerialize t = want)
                 ("TransitivePhext serialize matches after " ^ kind ^ " " ^ at);
           check (dynamicFetch d c = fetch want c)
                 ("DynamicPhext fetch matches after " ^ kind ^ " " ^ at);
           check (transitiveFetch t c = fetch want c)
                 ("TransitivePhext fetch matches after " ^ kind ^ " " ^ at)
         end) ops
    val d2 = dynamicCreate ""
    val () = List.app
      (fn i => dynamicAppend d2 (coord ("1.1.1/1.1.1/1.1." ^ Int.toString i)) ("s" ^ Int.toString i))
      (List.tabulate (20, fn i => i + 1))
    val () = check (dynamicLen d2 = 20 andalso dynamicCapacity d2 >= 20 andalso dynamicCapacity d2 < 40)
                   ("DynamicPhext capacity doubling (cap=" ^ Int.toString (dynamicCapacity d2) ^ ")")
    val () = List.app
      (fn i => dynamicRemove d2 (coord ("1.1.1/1.1.1/1.1." ^ Int.toString i)))
      (List.tabulate (15, fn i => 20 - i))
    val () = check (dynamicLen d2 = 5) "DynamicPhext removals"
    val () = check (transitiveDepth (transitiveCreate "") = 9) "TransitivePhext depth 9"
    (* fixtures *)
    val () = case OS.Process.getEnv "PHEXT_FIXTURES" of
               NONE => print "skip - fixtures (PHEXT_FIXTURES not set)\n"
             | SOME dir =>
                 let
                   val paths = collect dir []
                   val identical = ref 0
                   val () = List.app
                     (fn path =>
                        let
                          val data = slurpBytes path
                          val () = if dephokenize (phokenize data) = data
                                   then identical := !identical + 1 else ()
                          val n1 = normalize data
                        in
                          check (normalize n1 = n1) ("fixture normalize idempotent: " ^ path)
                        end) paths
                 in
                   check (List.length paths > 0)
                         ("fixtures found (" ^ Int.toString (List.length paths) ^ ")");
                   check (!identical = List.length paths)
                         ("fixtures byte-identical round-trips ("
                          ^ Int.toString (!identical) ^ "/"
                          ^ Int.toString (List.length paths) ^ ")")
                 end
  in
    print (if !failures = 0 then "PASS\n" else "FAILURES: " ^ Int.toString (!failures) ^ "\n");
    OS.Process.exit (if !failures = 0 then OS.Process.success else OS.Process.failure)
  end

end

val () = TestPhext.main ()
