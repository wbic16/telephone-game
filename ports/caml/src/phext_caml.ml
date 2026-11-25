(* phext_caml.ml - libphext port for Caml (TIOBE #40; the Caml lineage
   toolchain is OCaml 4.14.1 - Caml Light itself is legacy, see
   TOP100.md). 0.6.1 parity semantics; normative reference:
   libphext-py.
   This is a DISTINCT implementation from ports/ocaml, written in the
   Caml idiom: coordinates are records, the scroll store is a
   functorised Map, and the walker is a tail-recursive byte fold.
   Dimension breaks (dim -> byte): 0 library 0x01, 1 shelf 0x1F,
   2 series 0x1E, 3 collection 0x1D, 4 volume 0x1C, 5 book 0x1A,
   6 chapter 0x19, 7 section 0x18, 8 scroll 0x17. Newline is text. *)

type coordinate = {
  library : int; shelf : int; series : int;
  collection : int; volume : int; book : int;
  chapter : int; section : int; scroll : int;
}

let origin = { library = 1; shelf = 1; series = 1; collection = 1;
               volume = 1; book = 1; chapter = 1; section = 1; scroll = 1 }

let coord_get c = function
  | 0 -> c.library | 1 -> c.shelf | 2 -> c.series | 3 -> c.collection
  | 4 -> c.volume | 5 -> c.book | 6 -> c.chapter | 7 -> c.section
  | _ -> c.scroll

let coord_set c d v =
  let c = match d with
    | 0 -> { c with library = v } | 1 -> { c with shelf = v }
    | 2 -> { c with series = v } | 3 -> { c with collection = v }
    | 4 -> { c with volume = v } | 5 -> { c with book = v }
    | 6 -> { c with chapter = v } | 7 -> { c with section = v }
    | _ -> { c with scroll = v }
  in
  (* every lower dimension resets to 1 *)
  let rec reset c d = if d > 8 then c else reset (set_raw c d 1) (d + 1)
  and set_raw c = function
    | 0 -> fun v -> { c with library = v } | 1 -> fun v -> { c with shelf = v }
    | 2 -> fun v -> { c with series = v } | 3 -> fun v -> { c with collection = v }
    | 4 -> fun v -> { c with volume = v } | 5 -> fun v -> { c with book = v }
    | 6 -> fun v -> { c with chapter = v } | 7 -> fun v -> { c with section = v }
    | _ -> fun v -> { c with scroll = v }
  in
  reset c (d + 1)

let compare_coordinate a b =
  let rec go d =
    if d > 8 then 0
    else
      let x = coord_get a d and y = coord_get b d in
      if x <> y then compare x y else go (d + 1)
  in
  go 0

module CoordOrder = struct
  type t = coordinate
  let compare = compare_coordinate
end

module ScrollMap = Map.Make (CoordOrder)

type scroll = { at : coordinate; body : string }

let parse_coordinate text =
  let is_digits s =
    let rec go i = i >= String.length s || (s.[i] >= '0' && s.[i] <= '9' && go (i + 1)) in
    String.length s > 0 && go 0
  in
  match String.split_on_char '/' (String.trim text) with
  | [ g1; g2; g3 ] ->
      let parts =
        List.concat_map (String.split_on_char '.') [ g1; g2; g3 ]
      in
      if List.length parts = 9 && List.for_all is_digits parts then
        let v = List.map int_of_string parts in
        if List.exists (fun n -> n < 1) v then None
        else
          Some { library = List.nth v 0; shelf = List.nth v 1;
                 series = List.nth v 2; collection = List.nth v 3;
                 volume = List.nth v 4; book = List.nth v 5;
                 chapter = List.nth v 6; section = List.nth v 7;
                 scroll = List.nth v 8 }
      else None
  | _ -> None

let format_coordinate c =
  Printf.sprintf "%d.%d.%d/%d.%d.%d/%d.%d.%d" c.library c.shelf c.series
    c.collection c.volume c.book c.chapter c.section c.scroll

let break_bytes = [| '\x01'; '\x1f'; '\x1e'; '\x1d'; '\x1c'; '\x1a'; '\x19'; '\x18'; '\x17' |]

let dimension_of_byte ch =
  let rec go d = if d > 8 then -1 else if break_bytes.(d) = ch then d else go (d + 1) in
  go 0

let step_break c d = coord_set c d (coord_get c d + 1)

(* phokenize: a tail-recursive fold over the buffer; each maximal run of
   non-break bytes is one scroll at the walker's current coordinate. *)
let phokenize buffer =
  let len = String.length buffer in
  let rec walk i walker acc =
    if i >= len then List.rev acc
    else
      let d = dimension_of_byte buffer.[i] in
      if d >= 0 then walk (i + 1) (step_break walker d) acc
      else
        let rec run j =
          if j < len && dimension_of_byte buffer.[j] < 0 then run (j + 1) else j
        in
        let j = run i in
        walk j walker ({ at = walker; body = String.sub buffer i (j - i) } :: acc)
  in
  walk 0 origin []

(* advance: emit the breaks that carry [loc] up to [target]; returns the
   emitted bytes and the reached coordinate. *)
let advance loc target =
  if compare_coordinate loc target >= 0 then ("", loc)
  else
    let rec first_diff d =
      if coord_get loc d = coord_get target d then first_diff (d + 1) else d
    in
    let d = first_diff 0 in
    let buf = Buffer.create 16 in
    for _ = 1 to coord_get target d - coord_get loc d do
      Buffer.add_char buf break_bytes.(d)
    done;
    let reached = ref (coord_set loc d (coord_get target d)) in
    for lower = d + 1 to 8 do
      for _ = 1 to coord_get target lower - 1 do
        Buffer.add_char buf break_bytes.(lower)
      done;
      reached := coord_set !reached lower (coord_get target lower)
    done;
    (Buffer.contents buf, !reached)

let dephokenize scrolls =
  let buf = Buffer.create 256 in
  let loc = ref origin in
  List.iter
    (fun s ->
      let bytes, reached = advance !loc s.at in
      loc := reached;
      Buffer.add_string buf bytes;
      Buffer.add_string buf s.body)
    scrolls;
  Buffer.contents buf

let normalize buffer = dephokenize (phokenize buffer)

let fetch buffer coord =
  let rec go = function
    | [] -> ""
    | s :: rest -> if compare_coordinate s.at coord = 0 then s.body else go rest
  in
  go (phokenize buffer)

let update buffer coord text overwrite =
  let nxt = ref { at = coord; body = text } in
  let placed = ref false in
  let out = ref [] in
  List.iter
    (fun s ->
      if (not !placed) && compare_coordinate s.at coord > 0 then begin
        out := !nxt :: !out;
        placed := true
      end;
      if (not !placed) && compare_coordinate s.at coord = 0 then begin
        if not overwrite then nxt := { at = coord; body = s.body ^ !nxt.body };
        out := !nxt :: !out;
        placed := true
      end
      else out := s :: !out)
    (phokenize buffer);
  if not !placed then out := !nxt :: !out;
  dephokenize (List.rev !out)

let insert buffer coord text = update buffer coord text false
let replace buffer coord text = update buffer coord text true

(* remove is COORDINATE-PRESERVING: the scroll empties, delimiters
   stay, later scrolls do NOT shift. *)
let remove buffer coord = normalize (update buffer coord "" true)

let explode buffer =
  List.fold_left
    (fun m s -> ScrollMap.add s.at s.body m)
    ScrollMap.empty (phokenize buffer)

let implode map =
  dephokenize
    (ScrollMap.fold (fun at body acc -> { at; body } :: acc) map []
     |> List.rev)

(* ---------- DynamicPhext: capacity-managed dynamic array ---------- *)
type dynamic_phext = {
  mutable slots : scroll array;
  mutable used : int;
  mutable cap : int;
  shrink_divisor : int;
  mutable resizes : int;
  mutable copied : int;
}

let empty_scroll = { at = origin; body = "" }

let dynamic_blank divisor =
  { slots = Array.make 1 empty_scroll; used = 0; cap = 1;
    shrink_divisor = divisor; resizes = 0; copied = 0 }

let dynamic_resize d new_cap =
  let nd = Array.make new_cap empty_scroll in
  Array.blit d.slots 0 nd 0 d.used;
  d.slots <- nd;
  d.cap <- new_cap;
  d.resizes <- d.resizes + 1;
  d.copied <- d.copied + d.used

let dynamic_push d s =
  if d.used = d.cap then dynamic_resize d (2 * d.cap);
  d.slots.(d.used) <- s;
  d.used <- d.used + 1

let dynamic_create ?(shrink_divisor = 4) buffer =
  if shrink_divisor < 2 then invalid_arg "shrink_divisor must be >= 2";
  let d = dynamic_blank shrink_divisor in
  List.iter (dynamic_push d) (phokenize buffer);
  d

let dynamic_load d buffer =
  let fresh = dynamic_blank d.shrink_divisor in
  d.slots <- fresh.slots; d.used <- 0; d.cap <- 1;
  d.resizes <- 0; d.copied <- 0;
  List.iter (dynamic_push d) (phokenize buffer)

let dynamic_scrolls d =
  let rec go i acc = if i < 0 then acc else go (i - 1) (d.slots.(i) :: acc) in
  go (d.used - 1) []

let dynamic_serialize d = dephokenize (dynamic_scrolls d)

let dynamic_locate d coord =
  let lo = ref 0 and hi = ref d.used and found = ref (-1) in
  while !lo < !hi && !found < 0 do
    let mid = (!lo + !hi) / 2 in
    let c = compare_coordinate d.slots.(mid).at coord in
    if c < 0 then lo := mid + 1 else if c > 0 then hi := mid else found := mid
  done;
  if !found >= 0 then (!found, true) else (!lo, false)

let dynamic_fetch d coord =
  let idx, ok = dynamic_locate d coord in
  if ok then d.slots.(idx).body else ""

let dynamic_contains d coord = snd (dynamic_locate d coord)
let dynamic_len d = d.used

let dynamic_append d coord text =
  if d.used > 0 && compare_coordinate coord d.slots.(d.used - 1).at <= 0 then
    invalid_arg "append requires a coordinate past the current tail";
  if text <> "" then dynamic_push d { at = coord; body = text }

let dynamic_shrink d =
  if d.cap > 1 && d.used <= d.cap / d.shrink_divisor then
    dynamic_resize d (max 1 (d.cap / 2))

let dynamic_delete d idx =
  for i = idx to d.used - 2 do
    d.slots.(i) <- d.slots.(i + 1)
  done;
  d.used <- d.used - 1;
  dynamic_shrink d

let dynamic_update d coord text overwrite =
  let idx, ok = dynamic_locate d coord in
  if ok then begin
    if text = "" then (if overwrite then dynamic_delete d idx)
    else
      let t = if overwrite then text else d.slots.(idx).body ^ text in
      d.slots.(idx) <- { at = coord; body = t }
  end
  else if text <> "" then begin
    if d.used = d.cap then dynamic_resize d (2 * d.cap);
    for i = d.used downto idx + 1 do
      d.slots.(i) <- d.slots.(i - 1)
    done;
    d.slots.(idx) <- { at = coord; body = text };
    d.used <- d.used + 1
  end

let dynamic_insert d coord text = dynamic_update d coord text false
let dynamic_replace d coord text = dynamic_update d coord text true

let dynamic_remove d coord =
  let idx, ok = dynamic_locate d coord in
  if ok then dynamic_delete d idx

(* ---------- TransitivePhext: branching hash map, depth 9 ---------- *)
type bnode = {
  kids : (int, bnode) Hashtbl.t;
  mutable leaf : string option;
}

let bnode () = { kids = Hashtbl.create 4; leaf = None }

type branching = { depth : int; root : bnode; mutable count : int }

let branching depth =
  if depth < 1 then invalid_arg "depth must be >= 1";
  { depth; root = bnode (); count = 0 }

let key_of coord =
  [ coord.library; coord.shelf; coord.series; coord.collection;
    coord.volume; coord.book; coord.chapter; coord.section; coord.scroll ]

let coord_of_key = function
  | [ a; b; c; d; e; f; g; h; i ] ->
      { library = a; shelf = b; series = c; collection = d; volume = e;
        book = f; chapter = g; section = h; scroll = i }
  | _ -> invalid_arg "key must have 9 components"

let rec b_fetch node = function
  | [] -> node.leaf
  | k :: rest -> (
      match Hashtbl.find_opt node.kids k with
      | None -> None
      | Some child -> b_fetch child rest)

let rec b_put node key value =
  match key with
  | [] ->
      let created = node.leaf = None in
      node.leaf <- Some value;
      created
  | k :: rest ->
      let child =
        match Hashtbl.find_opt node.kids k with
        | Some c -> c
        | None ->
            let c = bnode () in
            Hashtbl.replace node.kids k c;
            c
      in
      b_put child rest value

let rec b_remove node = function
  | [] ->
      if node.leaf <> None then begin
        node.leaf <- None;
        true
      end
      else false
  | k :: rest -> (
      match Hashtbl.find_opt node.kids k with
      | None -> false
      | Some child ->
          let removed = b_remove child rest in
          if removed && Hashtbl.length child.kids = 0 && child.leaf = None
          then Hashtbl.remove node.kids k;
          removed)

let b_items root =
  let out = ref [] in
  let rec go node key_rev =
    if List.length key_rev = 9 then begin
      match node.leaf with
      | Some v -> out := { at = coord_of_key (List.rev key_rev); body = v } :: !out
      | None -> ()
    end
    else begin
      let keys =
        Hashtbl.fold (fun k _ acc -> k :: acc) node.kids [] |> List.sort compare
      in
      List.iter (fun k -> go (Hashtbl.find node.kids k) (k :: key_rev)) keys
    end
  in
  go root [];
  List.rev !out

type transitive_phext = { mutable map : branching }

let transitive_create buffer =
  let t = { map = branching 9 } in
  List.iter
    (fun s -> if b_put t.map.root (key_of s.at) s.body then t.map.count <- t.map.count + 1)
    (phokenize buffer);
  t

let transitive_depth t = t.map.depth

let transitive_load t buffer =
  t.map <- branching 9;
  List.iter
    (fun s -> if b_put t.map.root (key_of s.at) s.body then t.map.count <- t.map.count + 1)
    (phokenize buffer)

let transitive_scrolls t = b_items t.map.root
let transitive_serialize t = dephokenize (transitive_scrolls t)

let transitive_fetch t coord =
  match b_fetch t.map.root (key_of coord) with Some v -> v | None -> ""

let transitive_contains t coord = b_fetch t.map.root (key_of coord) <> None
let transitive_len t = t.map.count

let transitive_update t coord text overwrite =
  if text = "" then begin
    if overwrite && b_remove t.map.root (key_of coord) then
      t.map.count <- t.map.count - 1
  end
  else begin
    let txt =
      if overwrite then text
      else match b_fetch t.map.root (key_of coord) with
        | Some ex -> ex ^ text
        | None -> text
    in
    if b_put t.map.root (key_of coord) txt then t.map.count <- t.map.count + 1
  end

let transitive_insert t coord text = transitive_update t coord text false
let transitive_replace t coord text = transitive_update t coord text true

let transitive_remove t coord =
  if b_remove t.map.root (key_of coord) then t.map.count <- t.map.count - 1

let transitive_append t coord text = transitive_insert t coord text
