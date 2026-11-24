(* phext.ml - libphext port for OCaml (0.6.1 parity semantics; normative
   reference: libphext-py). 9-dimensional plain-text format: scrolls
   addressed by a coordinate, separated by dimension-break bytes.
   Breaks (dim -> byte): 0 library 0x01, 1 shelf 0x1F, 2 series 0x1E,
   3 collection 0x1D, 4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19,
   7 section 0x18, 8 scroll 0x17. Newline is ordinary text.
   Coordinates are int array of length 9, each >= 1. Strings are bytes. *)

let breaks = [| 0x01; 0x1F; 0x1E; 0x1D; 0x1C; 0x1A; 0x19; 0x18; 0x17 |]

let break_dim b =
  let rec go d = if d > 8 then -1 else if breaks.(d) = b then d else go (d + 1) in
  go 0

type coord = int array
type positioned_scroll = { coord : coord; text : string }

let parse_coordinate s =
  let s = String.trim s in
  let groups = String.split_on_char '/' s in
  if List.length groups <> 3 then None
  else
    try
      let parts = ref [] in
      List.iter
        (fun g ->
          List.iter
            (fun p ->
              if p = "" then raise Not_found;
              String.iter
                (fun ch -> if ch < '0' || ch > '9' then raise Not_found)
                p;
              let n = int_of_string p in
              if n < 1 then raise Not_found;
              parts := n :: !parts)
            (String.split_on_char '.' g))
        groups;
      let parts = List.rev !parts in
      if List.length parts <> 9 then None else Some (Array.of_list parts)
    with Not_found -> None

let format_coordinate c =
  Printf.sprintf "%d.%d.%d/%d.%d.%d/%d.%d.%d" c.(0) c.(1) c.(2) c.(3) c.(4)
    c.(5) c.(6) c.(7) c.(8)

let compare_coord a b =
  let rec go i =
    if i > 8 then 0
    else if a.(i) <> b.(i) then compare a.(i) b.(i)
    else go (i + 1)
  in
  go 0

let apply_break coord d =
  coord.(d) <- coord.(d) + 1;
  for k = d + 1 to 8 do
    coord.(k) <- 1
  done

let phokenize buffer =
  let len = String.length buffer in
  let walker = Array.make 9 1 in
  let out = ref [] in
  let i = ref 0 in
  while !i < len do
    let d = break_dim (Char.code buffer.[!i]) in
    if d >= 0 then begin
      apply_break walker d;
      incr i
    end
    else begin
      let start = !i in
      while !i < len && break_dim (Char.code buffer.[!i]) < 0 do
        incr i
      done;
      out := { coord = Array.copy walker; text = String.sub buffer start (!i - start) } :: !out
    end
  done;
  List.rev !out

let advance loc target =
  if compare_coord loc target >= 0 then ""
  else begin
    let d = ref 0 in
    while loc.(!d) = target.(!d) do
      incr d
    done;
    let buf = Buffer.create 16 in
    for _ = 1 to target.(!d) - loc.(!d) do
      Buffer.add_char buf (Char.chr breaks.(!d))
    done;
    let reached = Array.copy loc in
    reached.(!d) <- target.(!d);
    for k = !d + 1 to 8 do
      reached.(k) <- 1
    done;
    for lower = !d + 1 to 8 do
      for _ = 1 to target.(lower) - 1 do
        Buffer.add_char buf (Char.chr breaks.(lower))
      done;
      reached.(lower) <- target.(lower)
    done;
    Array.blit reached 0 loc 0 9;
    Buffer.contents buf
  end

let dephokenize scrolls =
  let loc = Array.make 9 1 in
  let buf = Buffer.create 256 in
  List.iter
    (fun ps ->
      Buffer.add_string buf (advance loc ps.coord);
      Buffer.add_string buf ps.text)
    scrolls;
  Buffer.contents buf

let normalize buffer = dephokenize (phokenize buffer)

let fetch buffer coord =
  let rec go = function
    | [] -> ""
    | ps :: rest -> if compare_coord ps.coord coord = 0 then ps.text else go rest
  in
  go (phokenize buffer)

let update buffer coord text overwrite =
  let items = phokenize buffer in
  let nxt = ref { coord; text } in
  let appended = ref false in
  let result = ref [] in
  List.iter
    (fun ps ->
      if (not !appended) && compare_coord ps.coord coord > 0 then begin
        result := !nxt :: !result;
        appended := true
      end;
      if (not !appended) && compare_coord ps.coord coord = 0 then begin
        if not overwrite then nxt := { coord; text = ps.text ^ !nxt.text };
        result := !nxt :: !result;
        appended := true
      end
      else result := ps :: !result)
    items;
  if not !appended then result := !nxt :: !result;
  dephokenize (List.rev !result)

let insert buffer coord text = update buffer coord text false
let replace buffer coord text = update buffer coord text true

(* remove is COORDINATE-PRESERVING: the scroll becomes empty, delimiters
   stay, later scrolls do NOT shift. *)
let remove buffer coord = normalize (update buffer coord "" true)

let explode buffer =
  let tbl = Hashtbl.create 64 in
  List.iter (fun ps -> Hashtbl.replace tbl (format_coordinate ps.coord) ps.text) (phokenize buffer);
  tbl

let implode tbl =
  let scrolls =
    Hashtbl.fold
      (fun k v acc -> match parse_coordinate k with Some c -> { coord = c; text = v } :: acc | None -> acc)
      tbl []
  in
  let sorted = List.sort (fun a b -> compare_coord a.coord b.coord) scrolls in
  dephokenize sorted

(* ---------- DynamicPhext: capacity-managed dynamic array ---------- *)
type dynamic_phext = {
  mutable data : positioned_scroll array;
  mutable n : int;
  mutable capacity : int;
  shrink_divisor : int;
  mutable resize_count : int;
  mutable elements_copied : int;
}

let dummy_ps = { coord = Array.make 9 1; text = "" }

let dynamic_create ?(shrink_divisor = 4) buffer =
  if shrink_divisor < 2 then invalid_arg "shrink_divisor must be >= 2";
  let d =
    { data = Array.make 1 dummy_ps; n = 0; capacity = 1; shrink_divisor;
      resize_count = 0; elements_copied = 0 }
  in
  let resize new_cap =
    let nd = Array.make new_cap dummy_ps in
    Array.blit d.data 0 nd 0 d.n;
    d.data <- nd;
    d.capacity <- new_cap;
    d.resize_count <- d.resize_count + 1;
    d.elements_copied <- d.elements_copied + d.n
  in
  ignore resize;
  if buffer <> "" then begin
    List.iter
      (fun ps ->
        if d.n = d.capacity then begin
          let nd = Array.make (2 * d.capacity) dummy_ps in
          Array.blit d.data 0 nd 0 d.n;
          d.data <- nd;
          d.capacity <- 2 * d.capacity;
          d.resize_count <- d.resize_count + 1;
          d.elements_copied <- d.elements_copied + d.n
        end;
        d.data.(d.n) <- ps;
        d.n <- d.n + 1)
      (phokenize buffer)
  end;
  d

let dynamic_resize d new_cap =
  let nd = Array.make new_cap dummy_ps in
  Array.blit d.data 0 nd 0 d.n;
  d.data <- nd;
  d.capacity <- new_cap;
  d.resize_count <- d.resize_count + 1;
  d.elements_copied <- d.elements_copied + d.n

let dynamic_grow_if_full d =
  if d.n = d.capacity then dynamic_resize d (2 * d.capacity)

let dynamic_shrink_if_sparse d =
  if d.capacity > 1 && d.n <= d.capacity / d.shrink_divisor then
    dynamic_resize d (max 1 (d.capacity / 2))

let dynamic_push d ps =
  dynamic_grow_if_full d;
  d.data.(d.n) <- ps;
  d.n <- d.n + 1

let dynamic_load d buffer =
  d.capacity <- 1;
  d.data <- Array.make 1 dummy_ps;
  d.n <- 0;
  d.resize_count <- 0;
  d.elements_copied <- 0;
  List.iter (dynamic_push d) (phokenize buffer)

let dynamic_scrolls d =
  let out = ref [] in
  for i = d.n - 1 downto 0 do
    out := d.data.(i) :: !out
  done;
  !out

let dynamic_serialize d = dephokenize (dynamic_scrolls d)

let dynamic_find d coord =
  let lo = ref 0 and hi = ref d.n in
  let found = ref (-1) in
  while !lo < !hi && !found < 0 do
    let mid = (!lo + !hi) / 2 in
    let c = compare_coord d.data.(mid).coord coord in
    if c < 0 then lo := mid + 1
    else if c > 0 then hi := mid
    else found := mid
  done;
  if !found >= 0 then (!found, true) else (!lo, false)

let dynamic_fetch d coord =
  let idx, found = dynamic_find d coord in
  if found then d.data.(idx).text else ""

let dynamic_contains d coord = snd (dynamic_find d coord)
let dynamic_len d = d.n

let dynamic_append d coord text =
  if d.n > 0 && compare_coord coord d.data.(d.n - 1).coord <= 0 then
    invalid_arg "append requires a coordinate past the current tail";
  if text <> "" then dynamic_push d { coord; text }

let dynamic_remove_at d idx =
  for i = idx to d.n - 2 do
    d.data.(i) <- d.data.(i + 1)
  done;
  d.n <- d.n - 1;
  dynamic_shrink_if_sparse d

let dynamic_update d coord text overwrite =
  let idx, found = dynamic_find d coord in
  if found then begin
    if text = "" then begin
      if overwrite then dynamic_remove_at d idx
    end
    else begin
      let t = if overwrite then text else d.data.(idx).text ^ text in
      d.data.(idx) <- { coord; text = t }
    end
  end
  else if text <> "" then begin
    dynamic_grow_if_full d;
    for i = d.n downto idx + 1 do
      d.data.(i) <- d.data.(i - 1)
    done;
    d.data.(idx) <- { coord; text };
    d.n <- d.n + 1
  end

let dynamic_insert d coord text = dynamic_update d coord text false
let dynamic_replace d coord text = dynamic_update d coord text true

let dynamic_remove d coord =
  let idx, found = dynamic_find d coord in
  if found then dynamic_remove_at d idx

(* ---------- TransitivePhext: branching hash map, depth 9 ---------- *)
type bnode = {
  children : (int, bnode) Hashtbl.t;
  mutable leaf : string option;
}

let new_bnode () = { children = Hashtbl.create 8; leaf = None }

type branching_map = { depth : int; root : bnode; mutable count : int }

let branching_create depth =
  if depth < 1 then invalid_arg "depth must be >= 1";
  { depth; root = new_bnode (); count = 0 }

let branching_fetch m key =
  let rec go node level =
    match Hashtbl.find_opt node.children key.(level) with
    | None -> None
    | Some child -> if level = m.depth - 1 then child.leaf else go child (level + 1)
  in
  go m.root 0

let branching_put m key value =
  let rec go node level =
    let child =
      match Hashtbl.find_opt node.children key.(level) with
      | Some c -> c
      | None ->
          let c = new_bnode () in
          Hashtbl.replace node.children key.(level) c;
          c
    in
    if level = m.depth - 1 then begin
      let created = child.leaf = None in
      child.leaf <- Some value;
      created
    end
    else go child (level + 1)
  in
  let created = go m.root 0 in
  if created then m.count <- m.count + 1;
  created

let branching_remove m key =
  let rec go node level =
    match Hashtbl.find_opt node.children key.(level) with
    | None -> false
    | Some child ->
        if level = m.depth - 1 then begin
          if child.leaf <> None then begin
            child.leaf <- None;
            true
          end
          else false
        end
        else begin
          let removed = go child (level + 1) in
          if removed && Hashtbl.length child.children = 0 && child.leaf = None then
            Hashtbl.remove node.children key.(level);
          removed
        end
  in
  let removed = go m.root 0 in
  if removed then m.count <- m.count - 1;
  removed

let branching_items m =
  let out = ref [] in
  let rec go node level prefix =
    let keys = Hashtbl.fold (fun k _ acc -> k :: acc) node.children [] in
    let keys = List.sort compare keys in
    List.iter
      (fun k ->
        let child = Hashtbl.find node.children k in
        prefix.(level) <- k;
        if level = m.depth - 1 then begin
          match child.leaf with
          | Some v -> out := { coord = Array.copy prefix; text = v } :: !out
          | None -> ()
        end
        else go child (level + 1) prefix)
      keys
  in
  go m.root 0 (Array.make m.depth 0);
  List.rev !out

type transitive_phext = { mutable tmap : branching_map }

let transitive_create buffer =
  let t = { tmap = branching_create 9 } in
  if buffer <> "" then
    List.iter (fun ps -> ignore (branching_put t.tmap ps.coord ps.text)) (phokenize buffer);
  t

let transitive_depth t = t.tmap.depth

let transitive_load t buffer =
  t.tmap <- branching_create 9;
  List.iter (fun ps -> ignore (branching_put t.tmap ps.coord ps.text)) (phokenize buffer)

let transitive_scrolls t = branching_items t.tmap
let transitive_serialize t = dephokenize (transitive_scrolls t)

let transitive_fetch t coord =
  match branching_fetch t.tmap coord with Some v -> v | None -> ""

let transitive_contains t coord = branching_fetch t.tmap coord <> None
let transitive_len t = t.tmap.count

let transitive_update t coord text overwrite =
  if text = "" then begin
    if overwrite then ignore (branching_remove t.tmap coord)
  end
  else begin
    let txt =
      if overwrite then text
      else
        match branching_fetch t.tmap coord with
        | Some ex -> ex ^ text
        | None -> text
    in
    ignore (branching_put t.tmap coord txt)
  end

let transitive_insert t coord text = transitive_update t coord text false
let transitive_replace t coord text = transitive_update t coord text true
let transitive_remove t coord = ignore (branching_remove t.tmap coord)
let transitive_append t coord text = transitive_insert t coord text
