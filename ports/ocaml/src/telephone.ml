(* telephone.ml - Exocortical Telephone Game CLI (contract v2) for the
   OCaml libphext port. Wire: one JSON request in, one response out;
   arg "serve" loops over JSON lines. PGP via this language's own
   subprocess gpg calls (Sys.command on temp files), key home
   $TELEPHONE_GNUPG_HOME or ~/telephone-ocaml/gnupg. *)
open Wire

let impl = "ocaml"
let key_uid = "libphext telephone " ^ impl
let index_coord = "1.1.1/1.1.1/1.1.1"
let keys_coord = "1.1.1/1.1.1/1.1.2"
let keys_hash_coord = "1.1.1/1.1.1/1.1.3"
let reserved = [ index_coord; keys_coord; keys_hash_coord ]

let state_bytes req =
  let s =
    match json_get "state" req with
    | Str s -> s
    | _ -> (match json_get "state_b64" req with Str s -> s | _ -> "")
  in
  b64_decode s

let trim = String.trim

let shq s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let read_all ic =
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with End_of_file -> ());
  Buffer.contents buf

let read_file path =
  let ic = open_in_bin path in
  let data = read_all ic in
  close_in ic;
  data

let write_file path data =
  let oc = open_out_bin path in
  output_string oc data;
  close_out oc

let run cmd =
  let tmp = Filename.temp_file "tel-ocaml-" ".out" in
  let rc = Sys.command (cmd ^ " > " ^ shq tmp ^ " 2>/tmp/telephone-ocaml-gpg.err") in
  let out = if Sys.file_exists tmp then read_file tmp else "" in
  Sys.remove tmp;
  if rc <> 0 then begin
    let err = if Sys.file_exists "/tmp/telephone-ocaml-gpg.err" then read_file "/tmp/telephone-ocaml-gpg.err" else "" in
    failwith ("command failed: " ^ err)
  end;
  out

let gnupg_home () =
  match Sys.getenv_opt "TELEPHONE_GNUPG_HOME" with
  | Some h -> h
  | None -> Filename.concat (Sys.getenv "HOME") ("telephone-" ^ impl ^ "/gnupg")

let gpg args input =
  let home = gnupg_home () in
  ignore (Sys.command ("mkdir -p " ^ shq home ^ " && chmod 700 " ^ shq home));
  let cmd =
    "gpg --batch --yes --pinentry-mode loopback --passphrase '' --homedir " ^ shq home ^ " " ^ args
  in
  match input with
  | None -> run cmd
  | Some data ->
      let tmp = Filename.temp_file "tel-ocaml-in-" ".bin" in
      write_file tmp data;
      let out = run (cmd ^ " < " ^ shq tmp) in
      Sys.remove tmp;
      out

let keygen () =
  let listing = gpg "--list-keys --with-colons" None in
  let contains hay needle =
    let hl = String.length hay and nl = String.length needle in
    let rec go i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else go (i + 1)
    in
    go 0
  in
  let has_pub = contains listing "pub:" in
  if not has_pub then
    ignore (gpg ("--quick-gen-key " ^ shq key_uid ^ " ed25519 sign never") None);
  gpg ("--armor --export " ^ shq key_uid) None

let detach_sign data =
  let dir = Filename.temp_file "tel-ocaml-dir-" "" in
  Sys.remove dir;
  ignore (Sys.command ("mkdir -p " ^ shq dir));
  write_file (Filename.concat dir "descriptor.json") data;
  ignore
    (gpg
       ("--detach-sign --armor --local-user " ^ shq key_uid ^ " --output "
        ^ shq (Filename.concat dir "descriptor.asc") ^ " "
        ^ shq (Filename.concat dir "descriptor.json"))
       None);
  let sig_ = read_file (Filename.concat dir "descriptor.asc") in
  ignore (Sys.command ("rm -rf " ^ shq dir));
  sig_

let verify_signature pubkeys data signature =
  let dir = Filename.temp_file "tel-ocaml-dir-" "" in
  Sys.remove dir;
  let home = Filename.concat dir "gnupg" in
  ignore (Sys.command ("mkdir -p " ^ shq home ^ " && chmod 700 " ^ shq home));
  write_file (Filename.concat dir "keys.asc") pubkeys;
  write_file (Filename.concat dir "descriptor.json") data;
  write_file (Filename.concat dir "descriptor.asc") signature;
  let rc1 =
    Sys.command
      ("gpg --batch --yes --homedir " ^ shq home ^ " --import " ^ shq (Filename.concat dir "keys.asc")
       ^ " >/dev/null 2>&1")
  in
  let rc2 =
    if rc1 = 0 then
      Sys.command
        ("gpg --batch --yes --homedir " ^ shq home ^ " --verify "
         ^ shq (Filename.concat dir "descriptor.asc") ^ " "
         ^ shq (Filename.concat dir "descriptor.json") ^ " >/dev/null 2>&1")
    else 1
  in
  ignore (Sys.command ("rm -rf " ^ shq dir));
  rc2 = 0

(* ---- game logic ---- *)
let echo_value ping =
  let game = json_string (json_get "game" ping) in
  let round =
    match json_get "round" ping with
    | Int n -> string_of_int n
    | Str s -> s
    | _ -> (match json_get "turn" ping with Int n -> string_of_int n | Str s -> s | _ -> "")
  in
  let nonce = json_string (json_get "nonce" ping) in
  sha256_hex (impl ^ "|" ^ game ^ "|" ^ round ^ "|" ^ nonce)

let seed_byte hex i = int_of_string ("0x" ^ String.sub hex (i * 2) 2)

let elect_winner position candidates turn =
  let hex = sha256_hex (position ^ String.make 1 (Char.chr (turn mod 256)) ^ String.concat "," candidates) in
  List.nth candidates (seed_byte hex 0 mod List.length candidates)

let next_coord c =
  let out = Array.copy c in
  let rec go d =
    if d < 0 then ()
    else if out.(d) < 999 then out.(d) <- out.(d) + 1
    else begin
      out.(d) <- 1;
      go (d - 1)
    end
  in
  go 8;
  out

let choose_adventure state position turn =
  let pos =
    match Phext.parse_coordinate position with
    | Some c -> c
    | None -> failwith ("invalid position " ^ position)
  in
  let used = Phext.explode state in
  List.iter (fun r -> Hashtbl.replace used r "\x00") reserved;
  let seed_hex = sha256_hex (position ^ String.make 1 (Char.chr (turn mod 256)) ^ state) in
  let cand = Array.copy pos in
  let dim = seed_byte seed_hex 1 mod 9 in
  cand.(dim) <- ((cand.(dim) - 1 + 1 + (seed_byte seed_hex 2 mod 3)) mod 999) + 1;
  let cur = ref cand in
  while Hashtbl.mem used (Phext.format_coordinate !cur) do
    cur := next_coord !cur
  done;
  let cs = Phext.format_coordinate !cur in
  Obj [ ("op", Str "insert"); ("coordinate", Str cs); ("text", Str (impl ^ " turn " ^ string_of_int turn ^ " at " ^ cs)) ]

let apply_step state step =
  match Phext.parse_coordinate (json_string (json_get "coordinate" step)) with
  | None -> (state, Null)
  | Some coord ->
      let text = json_string (json_get "text" step) in
      (match json_string (json_get "op" step) with
       | "insert" -> (Phext.insert state coord text, Null)
       | "replace" -> (Phext.replace state coord text, Null)
       | "remove" -> (Phext.remove state coord, Null)
       | "fetch" -> (state, Str (sha256_hex (Phext.fetch state coord)))
       | _ -> (state, Null))

let validate_step new_state step prior_opt =
  let fail detail = Obj [ ("impl", Str impl); ("verdict", Str "fail"); ("detail", Str detail) ] in
  if json_string (json_get "op" step) <> "insert" then fail "step op is not insert"
  else
    match Phext.parse_coordinate (json_string (json_get "coordinate" step)) with
    | None -> fail "unparseable coordinate"
    | Some coord ->
        if Phext.fetch new_state coord <> json_string (json_get "text" step) then
          fail ("placed scroll absent or content differs at " ^ json_string (json_get "coordinate" step))
        else
          (match prior_opt with
           | None ->
               Obj [ ("impl", Str impl); ("verdict", Str "pass");
                     ("detail", Str "placed scroll present with attested content (no prior state supplied)") ]
           | Some prior ->
               if Phext.fetch prior coord <> "" then fail "coordinate was not unused in the prior state"
               else begin
                 let before = Phext.explode prior in
                 let after_ = Phext.explode new_state in
                 if Hashtbl.length after_ <> Hashtbl.length before + 1 then
                   fail "scroll count did not grow by exactly one"
                 else begin
                   let bad = ref None in
                   Hashtbl.iter
                     (fun c t ->
                       if !bad = None then
                         match Hashtbl.find_opt after_ c with
                         | Some t2 when t2 = t -> ()
                         | _ -> bad := Some c)
                     before;
                   match !bad with
                   | Some c -> fail ("a prior scroll was overwritten: " ^ c)
                   | None ->
                       Obj [ ("impl", Str impl); ("verdict", Str "pass");
                             ("detail", Str "placed at unused coordinate; all prior scrolls intact") ]
                 end
               end)

(* ---- serve-mode validator cache (init / driver-form validate) ---- *)
let cache_map : (string, string) Hashtbl.t option ref = ref None

let init_cache state =
  cache_map := Some (Phext.explode state);
  Obj [ ("impl", Str impl); ("verdict", Str "pass") ]

let rstrip_nl s =
  let n = ref (String.length s) in
  while !n > 0 && s.[!n - 1] = '\n' do
    decr n
  done;
  String.sub s 0 !n

let ends_with s suffix =
  let sl = String.length s and xl = String.length suffix in
  xl <= sl && String.sub s (sl - xl) xl = suffix

let validate_driver new_state step event_coord_s index_line =
  let fail detail = Obj [ ("impl", Str impl); ("verdict", Str "fail"); ("detail", Str detail) ] in
  match !cache_map with
  | None -> fail "no prior state (init not called)"
  | Some old ->
      let new_map = Phext.explode new_state in
      (match Phext.parse_coordinate (json_string (json_get "coordinate" step)) with
       | None -> fail "unparseable coordinate"
       | Some coord ->
           let coord_s = Phext.format_coordinate coord in
           let placed = match Hashtbl.find_opt new_map coord_s with Some t -> t | None -> "\x00missing" in
           if placed <> json_string (json_get "text" step) then
             fail "placed scroll missing or altered"
           else begin
             let overwritten = ref None in
             Hashtbl.iter
               (fun c text ->
                 if !overwritten = None && c <> index_coord then
                   match Hashtbl.find_opt new_map c with
                   | Some t when t = text -> ()
                   | _ -> overwritten := Some c)
               old;
             match !overwritten with
             | Some c -> fail ("prior scroll overwritten at " ^ c)
             | None ->
                 let unexpected = ref None in
                 Hashtbl.iter
                   (fun c _ ->
                     if !unexpected = None && not (Hashtbl.mem old c) && c <> coord_s && c <> event_coord_s
                     then unexpected := Some c)
                   new_map;
                 (match !unexpected with
                  | Some c -> fail ("unexpected new scroll at " ^ c)
                  | None ->
                      let idx = match Hashtbl.find_opt new_map index_coord with Some t -> t | None -> "" in
                      if not (ends_with (rstrip_nl idx) (rstrip_nl index_line)) then
                        fail "index does not record the placement"
                      else begin
                        cache_map := Some new_map;
                        Obj [ ("impl", Str impl); ("verdict", Str "pass") ]
                      end)
           end)

let verify_game state pubkeys =
  let fail msg checked =
    Obj [ ("impl", Str impl); ("verdict", Str "fail"); ("placements_checked", Int checked);
          ("first_failure", Obj [ ("detail", Str msg) ]) ]
  in
  let scrolls = Phext.explode state in
  let keys_text = match Hashtbl.find_opt scrolls keys_coord with Some t -> t | None -> "" in
  if keys_text = "" then fail ("no public-keys scroll at " ^ keys_coord) 0
  else if trim pubkeys <> trim keys_text then
    fail "supplied pubkeys do not match the inscribed keys scroll" 0
  else if not (Hashtbl.mem scrolls keys_hash_coord) then
    fail ("no keys-hash scroll at " ^ keys_hash_coord) 0
  else if trim (Hashtbl.find scrolls keys_hash_coord) <> sha256_hex keys_text then
    fail "keys-hash scroll does not match the keys scroll" 0
  else begin
    let index = Hashtbl.create 64 in
    let index_text = match Hashtbl.find_opt scrolls index_coord with Some t -> t | None -> "" in
    let malformed = ref None in
    List.iter
      (fun raw ->
        let line = trim raw in
        if line <> "" && line.[0] <> '#' then begin
          let flds = String.split_on_char ' ' line |> List.filter (fun f -> f <> "") in
          (* split on any whitespace run: re-split robustly *)
          let flds =
            let rec split acc cur i =
              if i >= String.length line then List.rev (if cur = "" then acc else cur :: acc)
              else if line.[i] = ' ' || line.[i] = '\t' then
                split (if cur = "" then acc else cur :: acc) "" (i + 1)
              else split acc (cur ^ String.make 1 line.[i]) (i + 1)
            in
            split [] "" 0
          in
          ignore flds;
          if List.length flds <> 4 then malformed := Some line
          else
            Hashtbl.replace index (List.nth flds 1)
              (List.nth flds 0, List.nth flds 2, List.nth flds 3)
        end)
      (String.split_on_char '\n' index_text);
    match !malformed with
    | Some line -> fail ("malformed index line: " ^ line) 0
    | None ->
        let checked = ref 0 in
        let seen = Hashtbl.create 64 in
        let prev_hash = ref None in
        let failure = ref None in
        let seq = ref 1 in
        let continue = ref true in
        while !continue && !failure = None do
          let ecoord = Phext.format_coordinate [| 1; 1; 1; 1; 1; 1; 2; 1; !seq |] in
          match Hashtbl.find_opt scrolls ecoord with
          | None -> continue := false
          | Some ev_text ->
              let ev = try Some (parse_json ev_text) with _ -> None in
              (match ev with
               | None -> failure := Some ("event " ^ string_of_int !seq ^ " is not a JSON object", !checked)
               | Some ev ->
                   let body = json_get "body" ev in
                   (match body with
                    | Obj _ -> ()
                    | _ -> failure := Some ("event " ^ string_of_int !seq ^ " is not a JSON object", !checked));
                   if !failure = None then begin
                     if !seq = 1 then begin
                       match json_get "prev" ev with
                       | Null -> ()
                       | _ -> failure := Some ("event 1 prev is not null", !checked)
                     end
                     else begin
                       match (json_get "prev" ev, !prev_hash) with
                       | Str p, Some ph when p = ph -> ()
                       | _ -> failure := Some ("event chain broken at seq " ^ string_of_int !seq, !checked)
                     end;
                     if !failure = None then begin
                       prev_hash := Some (sha256_hex (canon_json body));
                       if json_string (json_get "type" body) = "placement" then begin
                         let coord_str = json_string (json_get "coord" body) in
                         let text_hash = json_string (json_get "text_sha256" body) in
                         let file_hash = json_string (json_get "file_sha256" body) in
                         let att_b64 = json_string (json_get "att" body) in
                         let turn = json_int (json_get "turn" body) in
                         let actor = json_string (json_get "actor" body) in
                         if coord_str = "" || text_hash = "" || file_hash = "" || att_b64 = "" then
                           failure := Some ("event " ^ string_of_int !seq ^ " lacks coord/text_sha256/file_sha256/att", !checked)
                         else if Hashtbl.mem seen coord_str then
                           failure := Some ("coordinate reused at " ^ coord_str, !checked)
                         else if not (Hashtbl.mem scrolls coord_str) then
                           failure := Some ("placement missing at " ^ coord_str, !checked)
                         else if sha256_hex (Hashtbl.find scrolls coord_str) <> text_hash then
                           failure := Some ("placement hash mismatch at " ^ coord_str, !checked)
                         else begin
                           match Hashtbl.find_opt index coord_str with
                           | Some (iturn, ihash, iactor)
                             when ihash = text_hash && iturn = string_of_int turn && iactor = actor ->
                               let desc =
                                 Obj [ ("turn", Int turn); ("coordinate", Str coord_str);
                                       ("scroll_sha256", Str text_hash); ("file_sha256", Str file_hash) ]
                               in
                               let signature = b64_decode att_b64 in
                               if verify_signature pubkeys (canon_json desc) signature then begin
                                 Hashtbl.replace seen coord_str true;
                                 incr checked
                               end
                               else
                                 failure := Some ("event " ^ string_of_int !seq ^ " signature invalid", !checked)
                           | _ -> failure := Some ("index mismatch at " ^ coord_str, !checked)
                         end
                       end
                     end
                   end);
              incr seq
        done;
        (match !failure with
         | Some (msg, n) -> fail msg n
         | None ->
             if !checked = 0 then fail "no placement events found" 0
             else begin
               let extra = ref None in
               Hashtbl.iter (fun cs _ -> if !extra = None && not (Hashtbl.mem seen cs) then extra := Some cs) index;
               match !extra with
               | Some cs -> fail ("index lists a placement with no event: " ^ cs) !checked
               | None ->
                   Obj [ ("impl", Str impl); ("verdict", Str "pass");
                         ("placements_checked", Int !checked); ("first_failure", Null) ]
             end)
  end

let handle req =
  match json_string (json_get "cmd" req) with
  | "id" -> Obj [ ("impl", Str impl) ]
  | "echo" -> Obj [ ("impl", Str impl); ("echo", Str (echo_value (json_get "ping" req))) ]
  | "elect" ->
      let cands =
        match json_get "candidates" req with Arr elems -> List.map json_string elems | _ -> []
      in
      if cands = [] then failwith "elect: no candidates";
      Obj [ ("elect", Str (elect_winner (json_string (json_get "position" req)) cands (json_int (json_get "turn" req)))) ]
  | "choose" ->
      choose_adventure (state_bytes req) (json_string (json_get "position" req)) (json_int (json_get "turn" req))
  | "apply" ->
      let ns, fh = apply_step (state_bytes req) (json_get "step" req) in
      Obj [ ("state_b64", Str (b64_encode ns)); ("state_sha256", Str (sha256_hex ns)); ("fetch_sha256", fh) ]
  | "keygen" -> Obj [ ("impl", Str impl); ("pubkey", Str (keygen ())) ]
  | "attest" -> Obj [ ("signature", Str (detach_sign (canon_json (json_get "descriptor" req)))) ]
  | "init" -> init_cache (state_bytes req)
  | "validate" when (match json_get "event_coord" req with Str _ -> true | _ -> false) ->
      validate_driver (state_bytes req) (json_get "step" req)
        (json_string (json_get "event_coord" req)) (json_string (json_get "index_line" req))
  | "validate" ->
      let prior_opt =
        match json_get "prior_state" req with
        | Str s -> Some (b64_decode s)
        | _ -> None
      in
      validate_step (state_bytes req) (json_get "step" req) prior_opt
  | "verify" -> verify_game (state_bytes req) (json_string (json_get "pubkeys" req))
  | other -> failwith ("unknown cmd " ^ other)

(* Game-scale framing (2026-11-24): lines over 8 KB may arrive
   gzip-framed as "GZ1:" + base64(gzip(line)) — the fleet-ssh channel
   is ~25-70 KB/s and raw base64 state lines took minutes at 1,000
   placements. OCaml stdlib has no zlib, so (de)compression shells to
   the system gzip(1) on temp files (the same idiom as the gpg calls
   above). Lossless; plain lines unchanged. *)
let gz_via data flag =
  let fin = Filename.temp_file "gzframe" ".in" in
  let fout = Filename.temp_file "gzframe" ".out" in
  let oc = open_out_bin fin in
  output_string oc data;
  close_out oc;
  ignore (Sys.command ("gzip " ^ flag ^ " " ^ fin ^ " > " ^ fout));
  let ic = open_in_bin fout in
  let out = read_all ic in
  close_in ic;
  Sys.remove fin;
  Sys.remove fout;
  out

let gz_unframe s =
  gz_via (b64_decode (String.sub s 4 (String.length s - 4))) "-dc"

let gz_frame s = "GZ1:" ^ b64_encode (gz_via s "-c")

let () =
  if Array.length Sys.argv > 1 && Sys.argv.(1) = "serve" then begin
    (try
       while true do
         let line = input_line stdin in
         if String.trim line <> "" then begin
           let line =
             if String.length line >= 4 && String.sub line 0 4 = "GZ1:"
             then gz_unframe line
             else line
           in
           let out =
             try handle (parse_json line)
             with e -> Obj [ ("error", Str (Printexc.to_string e)) ]
           in
           let outj = canon_json out in
           let outj =
             if String.length outj > 8192 then gz_frame outj else outj
           in
           print_string (outj ^ "\n");
           flush stdout
         end
       done
     with End_of_file -> ())
  end
  else begin
    let raw = read_all stdin in
    let req = parse_json raw in
    print_string (canon_json (handle req) ^ "\n")
  end
