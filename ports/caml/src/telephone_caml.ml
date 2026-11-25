(* telephone_caml.ml - Exocortical Telephone Game CLI (contract v2)
   for the Caml libphext port. Wire: one JSON request in, one response
   out; arg "serve" loops over JSON lines. PGP via subprocess gpg on
   temp files, key home $TELEPHONE_GNUPG_HOME or ~/telephone-caml/gnupg. *)
open Phext_caml
open Wire_caml

let impl = "caml"
let key_uid = "libphext telephone " ^ impl
let index_coord = Option.get (parse_coordinate "1.1.1/1.1.1/1.1.1")
let keys_coord = Option.get (parse_coordinate "1.1.1/1.1.1/1.1.2")
let kh_coord = Option.get (parse_coordinate "1.1.1/1.1.1/1.1.3")
let reserved = [ index_coord; keys_coord; kh_coord ]

let state_bytes req =
  let raw =
    match json_get "state" req with
    | JStr s -> s
    | _ -> (match json_get "state_b64" req with JStr s -> s | _ -> "")
  in
  b64_decode raw

let shq s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let slurp path =
  let ic = open_in_bin path in
  let buf = Buffer.create 1024 in
  (try while true do Buffer.add_channel buf ic 8192 done with End_of_file -> ());
  close_in ic;
  Buffer.contents buf

let spit path data =
  let oc = open_out_bin path in
  output_string oc data;
  close_out oc

let shell cmd =
  let tmp = Filename.temp_file "tel-caml-" ".out" in
  let rc = Sys.command (cmd ^ " > " ^ shq tmp ^ " 2>/tmp/telephone-caml.err") in
  let out = if Sys.file_exists tmp then slurp tmp else "" in
  Sys.remove tmp;
  if rc <> 0 then
    failwith ("command failed: "
              ^ (if Sys.file_exists "/tmp/telephone-caml.err"
                 then slurp "/tmp/telephone-caml.err" else ""));
  out

let gnupg_home () =
  match Sys.getenv_opt "TELEPHONE_GNUPG_HOME" with
  | Some h -> h
  | None -> Filename.concat (Sys.getenv "HOME") ("telephone-" ^ impl ^ "/gnupg")

let gpg args input =
  let home = gnupg_home () in
  ignore (Sys.command ("mkdir -p " ^ shq home ^ " && chmod 700 " ^ shq home));
  let cmd = "gpg --batch --yes --pinentry-mode loopback --passphrase '' --homedir "
            ^ shq home ^ " " ^ args in
  match input with
  | None -> shell cmd
  | Some data ->
      let tmp = Filename.temp_file "tel-caml-in-" ".bin" in
      spit tmp data;
      let out = shell (cmd ^ " < " ^ shq tmp) in
      Sys.remove tmp;
      out

let contains hay needle =
  let hl = String.length hay and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  go 0

let keygen () =
  let listing = gpg "--list-keys --with-colons" None in
  if not (contains listing "pub:") then
    ignore (gpg ("--quick-gen-key " ^ shq key_uid ^ " ed25519 sign never") None);
  gpg ("--armor --export " ^ shq key_uid) None

let detach_sign data =
  let dir = Filename.temp_file "tel-caml-dir-" "" in
  Sys.remove dir;
  ignore (Sys.command ("mkdir -p " ^ shq dir));
  spit (Filename.concat dir "descriptor.json") data;
  ignore (gpg ("--detach-sign --armor --local-user " ^ shq key_uid
               ^ " --output " ^ shq (Filename.concat dir "descriptor.asc")
               ^ " " ^ shq (Filename.concat dir "descriptor.json")) None);
  let sig_ = slurp (Filename.concat dir "descriptor.asc") in
  ignore (Sys.command ("rm -rf " ^ shq dir));
  sig_

let verify_signature pubkeys data signature =
  let dir = Filename.temp_file "tel-caml-dir-" "" in
  Sys.remove dir;
  let home = Filename.concat dir "gnupg" in
  ignore (Sys.command ("mkdir -p " ^ shq home ^ " && chmod 700 " ^ shq home));
  spit (Filename.concat dir "keys.asc") pubkeys;
  spit (Filename.concat dir "descriptor.json") data;
  spit (Filename.concat dir "descriptor.asc") signature;
  let rc1 = Sys.command ("gpg --batch --yes --homedir " ^ shq home ^ " --import "
                         ^ shq (Filename.concat dir "keys.asc") ^ " >/dev/null 2>&1") in
  let rc2 =
    if rc1 = 0 then
      Sys.command ("gpg --batch --yes --homedir " ^ shq home ^ " --verify "
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
    | JInt n -> string_of_int n
    | JStr s -> s
    | _ -> (match json_get "turn" ping with JInt n -> string_of_int n | JStr s -> s | _ -> "")
  in
  let nonce = json_string (json_get "nonce" ping) in
  sha256_hex (impl ^ "|" ^ game ^ "|" ^ round ^ "|" ^ nonce)

let seed_byte hex i = int_of_string ("0x" ^ String.sub hex (i * 2) 2)

(* Caml's election rule: hash position+turn+candidate list, walk from
   that offset until a candidate distinct from the outgoing holder
   (the position string names the holder's last coordinate, not an
   id, so in practice this is a plain deterministic rotation). *)
let elect_winner position candidates turn =
  let hex = sha256_hex (position ^ String.make 1 (Char.chr (turn mod 256))
                        ^ String.concat "," candidates) in
  List.nth candidates (seed_byte hex 0 mod List.length candidates)

let successor c =
  let rec bump d arr =
    if d < 0 then arr
    else if arr.(d) < 999 then begin arr.(d) <- arr.(d) + 1; arr end
    else begin arr.(d) <- 1; bump (d - 1) arr end
  in
  let arr = [| c.library; c.shelf; c.series; c.collection; c.volume;
               c.book; c.chapter; c.section; c.scroll |] in
  coord_of_key (Array.to_list (bump 8 arr))

(* Caml's adventure rule: from the tracked position, step the scroll
   dimension by a hash-chosen stride (1-3), then walk successors
   until an unused, unreserved coordinate is found. *)
let choose_adventure state position turn =
  let pos =
    match parse_coordinate position with
    | Some c -> c
    | None -> failwith ("invalid position " ^ position)
  in
  let used = explode state in
  let taken c = ScrollMap.mem c used || List.exists (fun r -> compare_coordinate r c = 0) reserved in
  let seed_hex = sha256_hex (position ^ String.make 1 (Char.chr (turn mod 256)) ^ state) in
  let stride = 1 + (seed_byte seed_hex 2 mod 3) in
  let start = ref pos in
  for _ = 1 to stride do start := successor !start done;
  let cur = ref !start in
  while taken !cur do cur := successor !cur done;
  let cs = format_coordinate !cur in
  JObj [ ("op", JStr "insert"); ("coordinate", JStr cs);
         ("text", JStr (impl ^ " turn " ^ string_of_int turn ^ " at " ^ cs)) ]

let apply_step state step =
  match parse_coordinate (json_string (json_get "coordinate" step)) with
  | None -> (state, JNull)
  | Some coord ->
      let text = json_string (json_get "text" step) in
      (match json_string (json_get "op" step) with
       | "insert" -> (insert state coord text, JNull)
       | "replace" -> (replace state coord text, JNull)
       | "remove" -> (remove state coord, JNull)
       | "fetch" -> (state, JStr (sha256_hex (fetch state coord)))
       | _ -> (state, JNull))

let vfail detail =
  JObj [ ("impl", JStr impl); ("verdict", JStr "fail"); ("detail", JStr detail) ]

let vpass detail =
  JObj [ ("impl", JStr impl); ("verdict", JStr "pass"); ("detail", JStr detail) ]

let validate_step new_state step prior_opt =
  if json_string (json_get "op" step) <> "insert" then vfail "step op is not insert"
  else
    match parse_coordinate (json_string (json_get "coordinate" step)) with
    | None -> vfail "unparseable coordinate"
    | Some coord ->
        if fetch new_state coord <> json_string (json_get "text" step) then
          vfail ("placed scroll absent or content differs at "
                 ^ json_string (json_get "coordinate" step))
        else
          (match prior_opt with
           | None -> vpass "placed scroll present with attested content (no prior state supplied)"
           | Some prior ->
               if fetch prior coord <> "" then vfail "coordinate was not unused in the prior state"
               else
                 let before = explode prior in
                 let after_ = explode new_state in
                 if ScrollMap.cardinal after_ <> ScrollMap.cardinal before + 1 then
                   vfail "scroll count did not grow by exactly one"
                 else
                   let bad =
                     ScrollMap.fold
                       (fun c t acc ->
                         match acc with
                         | Some _ -> acc
                         | None -> (match ScrollMap.find_opt c after_ with
                                    | Some t2 when t2 = t -> None
                                    | _ -> Some c))
                       before None
                   in
                   (match bad with
                    | Some c -> vfail ("a prior scroll was overwritten: " ^ format_coordinate c)
                    | None -> vpass "placed at unused coordinate; all prior scrolls intact"))

(* ---- serve-mode validator cache (init / driver-form validate) ---- *)
let cache : (string ScrollMap.t) option ref = ref None

let init_cache state =
  cache := Some (explode state);
  JObj [ ("impl", JStr impl); ("verdict", JStr "pass") ]

let strip_nl s =
  let n = ref (String.length s) in
  while !n > 0 && s.[!n - 1] = '\n' do decr n done;
  String.sub s 0 !n

let ends_with s suffix =
  let sl = String.length s and xl = String.length suffix in
  xl <= sl && String.sub s (sl - xl) xl = suffix

let validate_driver new_state step event_coord_s index_line =
  match !cache with
  | None -> vfail "no prior state (init not called)"
  | Some old -> begin
      let new_map = explode new_state in
      match parse_coordinate (json_string (json_get "coordinate" step)) with
      | None -> vfail "unparseable coordinate"
      | Some coord ->
          let placed = ScrollMap.find_opt coord new_map in
          if placed <> Some (json_string (json_get "text" step)) then
            vfail "placed scroll missing or altered"
          else
            let overwritten =
              ScrollMap.fold
                (fun c text acc ->
                  match acc with
                  | Some _ -> acc
                  | None ->
                      if compare_coordinate c index_coord = 0 then None
                      else (match ScrollMap.find_opt c new_map with
                            | Some t when t = text -> None
                            | _ -> Some c))
                old None
            in
            (match overwritten with
             | Some c -> vfail ("prior scroll overwritten at " ^ format_coordinate c)
             | None ->
                 let unexpected =
                   ScrollMap.fold
                     (fun c _ acc ->
                       match acc with
                       | Some _ -> acc
                       | None ->
                           if ScrollMap.mem c old then None
                           else if format_coordinate c = format_coordinate coord then None
                           else if format_coordinate c = event_coord_s then None
                           else Some c)
                     new_map None
                 in
                 (match unexpected with
                  | Some c -> vfail ("unexpected new scroll at " ^ format_coordinate c)
                  | None ->
                      let idx = match ScrollMap.find_opt index_coord new_map with Some t -> t | None -> "" in
                      if not (ends_with (strip_nl idx) (strip_nl index_line)) then
                        vfail "index does not record the placement"
                      else begin
                        cache := Some new_map;
                        JObj [ ("impl", JStr impl); ("verdict", JStr "pass") ]
                      end))
    end

let split_ws line =
  let rec go acc cur i =
    if i >= String.length line then List.rev (if cur = "" then acc else cur :: acc)
    else if line.[i] = ' ' || line.[i] = '\t' then go (if cur = "" then acc else cur :: acc) "" (i + 1)
    else go acc (cur ^ String.make 1 line.[i]) (i + 1)
  in
  go [] "" 0

let verify_game state pubkeys =
  let fail msg checked =
    JObj [ ("impl", JStr impl); ("verdict", JStr "fail");
           ("placements_checked", JInt checked);
           ("first_failure", JObj [ ("detail", JStr msg) ]) ]
  in
  let scrolls = explode state in
  let keys_text = match ScrollMap.find_opt keys_coord scrolls with Some t -> t | None -> "" in
  if keys_text = "" then fail ("no public-keys scroll at " ^ format_coordinate keys_coord) 0
  else if String.trim pubkeys <> String.trim keys_text then
    fail "supplied pubkeys do not match the inscribed keys scroll" 0
  else if not (ScrollMap.mem kh_coord scrolls) then
    fail ("no keys-hash scroll at " ^ format_coordinate kh_coord) 0
  else if String.trim (ScrollMap.find kh_coord scrolls) <> sha256_hex keys_text then
    fail "keys-hash scroll does not match the keys scroll" 0
  else begin
    let index = Hashtbl.create 64 in
    let index_text = match ScrollMap.find_opt index_coord scrolls with Some t -> t | None -> "" in
    let malformed = ref None in
    List.iter
      (fun raw ->
        let line = String.trim raw in
        if line <> "" && line.[0] <> '#' then begin
          let flds = split_ws line in
          if List.length flds <> 4 then malformed := Some line
          else Hashtbl.replace index (List.nth flds 1)
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
          let ecoord = { origin with chapter = 2; section = 1; scroll = !seq } in
          (* event prefix is 1.1.1/1.1.1/2.1.<seq>: library..book = 1,
             chapter = 2, section = 1, scroll = seq *)
          match ScrollMap.find_opt ecoord scrolls with
          | None -> continue := false
          | Some ev_text ->
              let ev = try Some (parse_json ev_text) with _ -> None in
              (match ev with
               | None -> failure := Some ("event " ^ string_of_int !seq ^ " is not a JSON object", !checked)
               | Some ev ->
                   let body = json_get "body" ev in
                   (match body with
                    | JObj _ -> ()
                    | _ -> failure := Some ("event " ^ string_of_int !seq ^ " is not a JSON object", !checked));
                   if !failure = None then begin
                     if !seq = 1 then begin
                       match json_get "prev" ev with
                       | JNull -> ()
                       | _ -> failure := Some ("event 1 prev is not null", !checked)
                     end
                     else begin
                       match (json_get "prev" ev, !prev_hash) with
                       | JStr p, Some ph when p = ph -> ()
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
                         else
                           (match parse_coordinate coord_str with
                            | None -> failure := Some ("bad coordinate " ^ coord_str, !checked)
                            | Some coord ->
                                if not (ScrollMap.mem coord scrolls) then
                                  failure := Some ("placement missing at " ^ coord_str, !checked)
                                else if sha256_hex (ScrollMap.find coord scrolls) <> text_hash then
                                  failure := Some ("placement hash mismatch at " ^ coord_str, !checked)
                                else
                                  (match Hashtbl.find_opt index coord_str with
                                   | Some (iturn, ihash, iactor)
                                     when ihash = text_hash && iturn = string_of_int turn && iactor = actor ->
                                       let desc =
                                         JObj [ ("turn", JInt turn); ("coordinate", JStr coord_str);
                                                ("scroll_sha256", JStr text_hash); ("file_sha256", JStr file_hash) ]
                                       in
                                       let signature = b64_decode att_b64 in
                                       if verify_signature pubkeys (canon_json desc) signature then begin
                                         Hashtbl.replace seen coord_str true;
                                         incr checked
                                       end
                                       else
                                         failure := Some ("event " ^ string_of_int !seq ^ " signature invalid", !checked)
                                   | _ -> failure := Some ("index mismatch at " ^ coord_str, !checked)))
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
                   JObj [ ("impl", JStr impl); ("verdict", JStr "pass");
                          ("placements_checked", JInt !checked); ("first_failure", JNull) ]
             end)
  end

let handle req =
  match json_string (json_get "cmd" req) with
  | "id" -> JObj [ ("impl", JStr impl) ]
  | "echo" -> JObj [ ("impl", JStr impl); ("echo", JStr (echo_value (json_get "ping" req))) ]
  | "elect" ->
      let cands =
        match json_get "candidates" req with JArr elems -> List.map json_string elems | _ -> []
      in
      if cands = [] then failwith "elect: no candidates";
      JObj [ ("elect", JStr (elect_winner (json_string (json_get "position" req)) cands (json_int (json_get "turn" req)))) ]
  | "choose" ->
      choose_adventure (state_bytes req) (json_string (json_get "position" req)) (json_int (json_get "turn" req))
  | "apply" ->
      let ns, fh = apply_step (state_bytes req) (json_get "step" req) in
      JObj [ ("state_b64", JStr (b64_encode ns)); ("state_sha256", JStr (sha256_hex ns)); ("fetch_sha256", fh) ]
  | "keygen" -> JObj [ ("impl", JStr impl); ("pubkey", JStr (keygen ())) ]
  | "attest" -> JObj [ ("signature", JStr (detach_sign (canon_json (json_get "descriptor" req)))) ]
  | "init" -> init_cache (state_bytes req)
  | "validate" when (match json_get "event_coord" req with JStr _ -> true | _ -> false) ->
      validate_driver (state_bytes req) (json_get "step" req)
        (json_string (json_get "event_coord" req)) (json_string (json_get "index_line" req))
  | "validate" ->
      let prior_opt =
        match json_get "prior_state" req with
        | JStr s -> Some (b64_decode s)
        | _ -> None
      in
      validate_step (state_bytes req) (json_get "step" req) prior_opt
  | "verify" -> verify_game (state_bytes req) (json_string (json_get "pubkeys" req))
  | other -> failwith ("unknown cmd " ^ other)

(* Game-scale framing: lines over 8 KB may arrive gzip-framed as
   "GZ1:" + base64(gzip(line)) - the fleet-ssh channel is ~25-70 KB/s.
   OCaml stdlib has no zlib, so (de)compression shells to gzip(1) on
   temp files. Lossless; plain lines unchanged. *)
let gz_via data flag =
  let fin = Filename.temp_file "gzframe" ".in" in
  let fout = Filename.temp_file "gzframe" ".out" in
  spit fin data;
  ignore (Sys.command ("gzip " ^ flag ^ " " ^ shq fin ^ " > " ^ shq fout));
  let out = slurp fout in
  Sys.remove fin;
  Sys.remove fout;
  out

let gz_unframe s = gz_via (b64_decode (String.sub s 4 (String.length s - 4))) "-dc"
let gz_frame s = "GZ1:" ^ b64_encode (gz_via s "-c")

let read_stdin_all () =
  let buf = Buffer.create 1024 in
  (try while true do Buffer.add_channel buf stdin 8192 done with End_of_file -> ());
  Buffer.contents buf

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
             with e -> JObj [ ("error", JStr (Printexc.to_string e)) ]
           in
           let outj = canon_json out in
           let outj = if String.length outj > 8192 then gz_frame outj else outj in
           print_string (outj ^ "\n");
           flush stdout
         end
       done
     with End_of_file -> ())
  end
  else begin
    let raw = read_stdin_all () in
    let req = parse_json raw in
    print_string (canon_json (handle req) ^ "\n")
  end
