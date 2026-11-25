(* Test suite for the Caml libphext port. Build/run via
   tests/run_tests.sh; fixtures via PHEXT_FIXTURES env. *)
open Phext_caml

let failures = ref 0

let check cond name =
  if cond then Printf.printf "ok - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let coord s =
  match parse_coordinate s with Some c -> c | None -> failwith ("bad coord " ^ s)

let () =
  check (format_coordinate (coord "1.2.3/4.5.6/7.8.9") = "1.2.3/4.5.6/7.8.9") "coordinate round trip";
  check (parse_coordinate "0.1.1/1.1.1/1.1.1" = None) "coordinate rejects 0";
  check (parse_coordinate "1.1.1/1.1.1" = None) "coordinate rejects short";
  check (compare_coordinate (coord "1.1.1/1.1.1/1.1.9") (coord "1.1.1/1.1.2/1.1.1") < 0) "order: section beats scroll";
  check (compare_coordinate (coord "2.1.1/1.1.1/1.1.1") (coord "10.1.1/1.1.1/1.1.1") < 0) "order: numeric not string";
  let buf = "a\x17b\x18c\x01d" in
  let scrolls = phokenize buf in
  let got = List.map (fun ps -> format_coordinate ps.at ^ ":" ^ ps.body) scrolls in
  check (got = [ "1.1.1/1.1.1/1.1.1:a"; "1.1.1/1.1.1/1.1.2:b"; "1.1.1/1.1.1/1.2.1:c"; "2.1.1/1.1.1/1.1.1:d" ]) "phokenize breaks";
  check (dephokenize scrolls = buf) "dephokenize round trip";
  let s = phokenize "line1\nline2" in
  check (List.length s = 1 && (List.hd s).body = "line1\nline2") "newline is text";
  check (fetch "hello" (coord "1.1.1/1.1.1/1.1.2") = "") "gap fetch is empty";
  check (fetch "hello" (coord "9.9.9/9.9.9/9.9.9") = "") "far gap fetch is empty";
  check (fetch "hello" (coord "1.1.1/1.1.1/1.1.1") = "hello") "fetch hit";
  let buf = insert "base" (coord "1.1.1/1.1.1/1.1.1") "+more" in
  check (fetch buf (coord "1.1.1/1.1.1/1.1.1") = "base+more") "insert merges existing+inserted";
  let buf = insert buf (coord "1.1.1/1.1.1/1.1.3") "third" in
  check (buf = "base+more\x17\x17third") "insert creates in canonical position";
  let buf = replace "a\x17b\x17c" (coord "1.1.1/1.1.1/1.1.2") "B" in
  check (buf = "a\x17B\x17c") "replace overwrites";
  let buf = remove buf (coord "1.1.1/1.1.1/1.1.2") in
  check (buf = "a\x17\x17c") "remove coordinate-preserving: c stays at scroll 3";
  check (fetch buf (coord "1.1.1/1.1.1/1.1.2") = "") "fetch after remove is empty";
  check (fetch buf (coord "1.1.1/1.1.1/1.1.3") = "c") "later scroll did NOT shift after remove";
  check (remove buf (coord "5.5.5/5.5.5/5.5.5") = buf) "remove gap is no-op";
  let m = explode "x\x17y\x01z" in
  check (ScrollMap.cardinal m = 3 && implode m = "x\x17y\x01z") "explode/implode round trip";
  (* store equivalence *)
  let ops =
    [ ("insert", "1.1.1/1.1.1/1.1.1", "+X"); ("insert", "1.1.1/1.1.1/1.1.3", "third");
      ("replace", "1.1.1/1.1.1/1.1.2", "B"); ("remove", "1.1.1/1.1.1/1.1.1", "");
      ("insert", "2.1.1/1.1.1/1.1.1", "lib2"); ("remove", "1.1.1/1.1.1/1.1.3", "");
      ("replace", "9.9.9/9.9.9/9.9.9", "far"); ("insert", "1.1.1/1.1.1/1.1.2", "-tail") ]
  in
  let d = dynamic_create "a\x17b" in
  let t = transitive_create "a\x17b" in
  let refr = ref "a\x17b" in
  List.iter
    (fun (kind, at, text) ->
      let c = coord at in
      (match kind with
       | "insert" -> dynamic_insert d c text; transitive_insert t c text; refr := insert !refr c text
       | "replace" -> dynamic_replace d c text; transitive_replace t c text; refr := replace !refr c text
       | _ -> dynamic_remove d c; transitive_remove t c; refr := remove !refr c);
      let want = normalize !refr in
      check (dynamic_serialize d = want) ("DynamicPhext serialize matches after " ^ kind ^ " " ^ at);
      check (transitive_serialize t = want) ("TransitivePhext serialize matches after " ^ kind ^ " " ^ at);
      check (dynamic_fetch d c = fetch want c) ("DynamicPhext fetch matches after " ^ kind ^ " " ^ at);
      check (transitive_fetch t c = fetch want c) ("TransitivePhext fetch matches after " ^ kind ^ " " ^ at))
    ops;
  let d2 = dynamic_create "" in
  for i = 1 to 20 do
    dynamic_append d2 (coord ("1.1.1/1.1.1/1.1." ^ string_of_int i)) ("s" ^ string_of_int i)
  done;
  check (dynamic_len d2 = 20 && d2.cap >= 20 && d2.cap < 40)
    ("DynamicPhext capacity doubling (cap=" ^ string_of_int d2.cap ^ ")");
  for i = 20 downto 6 do
    dynamic_remove d2 (coord ("1.1.1/1.1.1/1.1." ^ string_of_int i))
  done;
  check (dynamic_len d2 = 5) "DynamicPhext removals";
  check (transitive_depth (transitive_create "") = 9) "TransitivePhext depth 9";
  (* fixtures *)
  (match Sys.getenv_opt "PHEXT_FIXTURES" with
   | None -> print_endline "skip - fixtures (PHEXT_FIXTURES not set)"
   | Some dir ->
       let paths = ref [] in
       let rec walk d =
         Array.iter
           (fun name ->
             let p = Filename.concat d name in
             if Sys.is_directory p then walk p else if name = "input.phext" then paths := p :: !paths)
           (Sys.readdir d)
       in
       walk dir;
       let paths = List.sort String.compare !paths in
       let identical = ref 0 in
       List.iter
         (fun path ->
           let ic = open_in_bin path in
           let buf = Buffer.create 256 in
           (try while true do Buffer.add_channel buf ic 4096 done with End_of_file -> ());
           close_in ic;
           let data = Buffer.contents buf in
           if dephokenize (phokenize data) = data then incr identical;
           let n1 = normalize data in
           check (normalize n1 = n1) ("fixture normalize idempotent: " ^ path))
         paths;
       check (List.length paths > 0) ("fixtures found (" ^ string_of_int (List.length paths) ^ ")");
       check (!identical = List.length paths)
         ("fixtures byte-identical round-trips (" ^ string_of_int !identical ^ "/" ^ string_of_int (List.length paths) ^ ")"));
  Printf.printf "%s\n%!" (if !failures = 0 then "PASS" else "FAILURES: " ^ string_of_int !failures);
  exit (if !failures = 0 then 0 else 1)
