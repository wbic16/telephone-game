(* phext.sml - libphext port for ML (Standard ML, TIOBE #43).
   0.6.1 parity semantics; normative reference: libphext-py.
   9-dimensional plain-text format: scrolls addressed by a coordinate,
   separated by dimension-break bytes. Breaks (dim -> byte):
   0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
   4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
   8 scroll 0x17. Newline is ordinary text. Coordinates are int lists
   of length 9, each >= 1. Strings are byte strings. MLton target;
   Basis Library only (the explode map is a hand-rolled hash table -
   the Basis has no Map structure). *)

structure Phext =
struct

type coord = int list
type scroll = { coord : coord, text : string }

val breaks = [0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17]

fun dropWhile p [] = []
  | dropWhile p (x :: rest) = if p x then dropWhile p rest else x :: rest

fun breakDim b =
  let
    fun go [] _ = ~1
      | go (x :: rest) d = if x = b then d else go rest (d + 1)
  in go breaks 0 end

fun coordCompare (a : coord, b : coord) : order =
  let
    fun go [] [] = EQUAL
      | go (x :: xs) (y :: ys) =
          if x < y then LESS else if x > y then GREATER else go xs ys
      | go _ _ = EQUAL
  in go a b end


(* insertion sort helper kept local (Basis has no list sort) *)
structure ListMergeSortImpl =
struct
  fun sort entries =
    let
      fun insert (x as (xk, _)) [] = [x]
        | insert (x as (xk, _)) ((y as (yk, _)) :: rest) =
            (case coordCompare (xk, yk) of
               GREATER => y :: insert x rest
             | _ => x :: y :: rest)
      fun isort [] = []
        | isort (x :: rest) = insert x (isort rest)
    in isort entries end
end

fun parseCoordinate (s0 : string) : coord option =
  let
    val s = String.implode
      (List.filter (fn ch => ch <> #" " andalso ch <> #"\t" andalso ch <> #"\n")
                   (String.explode (String.map (fn ch => ch) s0)))
    (* trim: drop surrounding whitespace by filtering ends *)
    fun trim str =
      let
        val cs = String.explode str
        val cs = List.rev (dropWhile Char.isSpace (List.rev (dropWhile Char.isSpace cs)))
      in String.implode cs end
    val s = trim s0
    val groups = String.fields (fn ch => ch = #"/") s
    fun digits str =
      String.size str > 0 andalso List.all Char.isDigit (String.explode str)
  in
    if List.length groups <> 3 then NONE
    else
      let
        val parts = List.concat (List.map (String.fields (fn ch => ch = #".")) groups)
      in
        if List.length parts <> 9 orelse not (List.all digits parts) then NONE
        else
          let val v = List.map (fn p => case Int.fromString p of SOME n => n | NONE => 0) parts
          in if List.exists (fn n => n < 1) v then NONE else SOME v end
      end
  end

fun formatCoordinate (c : coord) : string =
  case c of
    [a, b, cc, d, e, f, g, h, i] =>
      String.concat [ Int.toString a, ".", Int.toString b, ".", Int.toString cc, "/",
                      Int.toString d, ".", Int.toString e, ".", Int.toString f, "/",
                      Int.toString g, ".", Int.toString h, ".", Int.toString i ]
  | _ => raise Fail "coordinate must have 9 components"

fun applyBreak (coord : coord, d : int) : coord =
  let
    fun go _ [] = []
      | go i (x :: rest) =
          if i < d then x :: go (i + 1) rest
          else if i = d then (x + 1) :: List.map (fn _ => 1) rest
          else []
  in go 0 coord end

fun phokenize (buffer : string) : scroll list =
  let
    val len = String.size buffer
    fun byteAt i = Char.ord (String.sub (buffer, i))
    fun walk i walker acc =
      if i >= len then List.rev acc
      else
        let val d = breakDim (byteAt i) in
          if d >= 0 then walk (i + 1) (applyBreak (walker, d)) acc
          else
            let
              fun run j =
                if j < len andalso breakDim (byteAt j) < 0 then run (j + 1) else j
              val j = run i
            in
              walk j walker ({ coord = walker,
                               text = String.substring (buffer, i, j - i) } :: acc)
            end
        end
  in walk 0 [1, 1, 1, 1, 1, 1, 1, 1, 1] [] end

fun advance (loc : coord, target : coord) : string * coord =
  if coordCompare (loc, target) <> LESS then ("", loc)
  else
    let
      fun firstDiff i =
        if List.nth (loc, i) = List.nth (target, i) then firstDiff (i + 1) else i
      val d = firstDiff 0
      fun setAt (xs, i, v) =
        List.tabulate (List.length xs, fn j => if j = i then v else List.nth (xs, j))
      val first = String.implode
        (List.tabulate (List.nth (target, d) - List.nth (loc, d),
                        fn _ => Char.chr (List.nth (breaks, d))))
      val reached0 = List.tabulate
        (9, fn j => if j < d then List.nth (loc, j)
                    else if j = d then List.nth (target, d) else 1)
      fun lower k (bytes, reached) =
        if k > 8 then (bytes, reached)
        else
          let
            val b = String.implode
              (List.tabulate (List.nth (target, k) - 1,
                              fn _ => Char.chr (List.nth (breaks, k))))
          in lower (k + 1) (bytes ^ b, setAt (reached, k, List.nth (target, k))) end
      val (rest, reached) = lower (d + 1) ("", reached0)
    in (first ^ rest, reached) end

fun dephokenize (scrolls : scroll list) : string =
  let
    fun go _ [] acc = String.concat (List.rev acc)
      | go loc (s :: rest) acc =
          let val (bytes, loc') = advance (loc, #coord s)
          in go loc' rest ((#text s) :: bytes :: acc) end
  in go [1, 1, 1, 1, 1, 1, 1, 1, 1] scrolls [] end

fun normalize buffer = dephokenize (phokenize buffer)

fun fetch buffer coord =
  case List.find (fn s => coordCompare (#coord s, coord) = EQUAL) (phokenize buffer) of
    SOME s => #text s
  | NONE => ""

fun update buffer coord text overwrite =
  let
    val nxt = { coord = coord, text = text }
    fun go [] placed acc =
          List.rev (if placed then acc else nxt :: acc)
      | go (s :: rest) placed acc =
          if not placed andalso coordCompare (#coord s, coord) = GREATER
          then go rest true (s :: nxt :: acc)
          else if not placed andalso coordCompare (#coord s, coord) = EQUAL
          then
            let val merged = if overwrite then nxt
                             else { coord = coord, text = #text s ^ text }
            in go rest true (merged :: acc) end
          else go rest placed (s :: acc)
  in dephokenize (go (phokenize buffer) false []) end

fun insert buffer coord text = update buffer coord text false
fun replace buffer coord text = update buffer coord text true

(* remove is COORDINATE-PRESERVING: the scroll becomes empty, the
   delimiters stay, later scrolls do NOT shift. *)
fun remove buffer coord = normalize (update buffer coord "" true)

(* ---- scroll map: hand-rolled hash table keyed by coordinate ---- *)
structure ScrollMap =
struct
  type t = (coord * string) list Array.array * int ref
  fun create () : t = (Array.array (1024, []), ref 0)
  fun hashOf (c : coord) : int =
    List.foldl (fn (x, a) => (a * 31 + x) mod 999983) 7 c
  fun put ((tab, count) : t) (key, value) =
    let
      val i = hashOf key mod Array.length tab
      val bucket = Array.sub (tab, i)
    in
      case List.find (fn (k, _) => coordCompare (k, key) = EQUAL) bucket of
        SOME _ => Array.update (tab, i,
                    List.map (fn (k, v) => if coordCompare (k, key) = EQUAL
                                            then (k, value) else (k, v)) bucket)
      | NONE => (Array.update (tab, i, (key, value) :: bucket); count := !count + 1)
    end
  fun get ((tab, _) : t) key =
    let val bucket = Array.sub (tab, hashOf key mod Array.length tab)
    in case List.find (fn (k, _) => coordCompare (k, key) = EQUAL) bucket of
         SOME (_, v) => SOME v
       | NONE => NONE
    end
  fun mem m key = case get m key of SOME _ => true | NONE => false
  fun size ((_, count) : t) = !count
  fun foldl f acc ((tab, _) : t) =
    Array.foldl (fn (bucket, a) => List.foldl (fn ((k, v), a2) => f (k, v, a2)) a bucket) acc tab
  fun toList m = foldl (fn (k, v, acc) => (k, v) :: acc) [] m
end

fun explode buffer =
  let
    val m = ScrollMap.create ()
    val () = List.app (fn s => ScrollMap.put m (#coord s, #text s)) (phokenize buffer)
  in m end

fun implode m =
  let
    val entries = ScrollMap.toList m
    val sorted = ListMergeSortImpl.sort entries
  in dephokenize (List.map (fn (c, t) => { coord = c, text = t }) sorted) end

(* ---------- DynamicPhext: capacity-managed dynamic array ---------- *)
type dynamicPhext =
  { slots : scroll Array.array ref,
    used : int ref,
    cap : int ref,
    shrinkDivisor : int,
    resizes : int ref,
    copied : int ref }

val emptyScroll : scroll = { coord = [1, 1, 1, 1, 1, 1, 1, 1, 1], text = "" }

fun dynamicBlank divisor : dynamicPhext =
  { slots = ref (Array.array (1, emptyScroll)), used = ref 0, cap = ref 1,
    shrinkDivisor = divisor, resizes = ref 0, copied = ref 0 }

fun dynamicResize (d : dynamicPhext) newCap =
  let
    val old = !(#slots d)
    val nd = Array.tabulate (newCap, fn i =>
               if i < !(#used d) then Array.sub (old, i) else emptyScroll)
  in
    #slots d := nd;
    #cap d := newCap;
    #resizes d := !(#resizes d) + 1;
    #copied d := !(#copied d) + !(#used d)
  end

fun dynamicPush (d : dynamicPhext) s =
  (if !(#used d) = !(#cap d) then dynamicResize d (2 * !(#cap d)) else ();
   Array.update (!(#slots d), !(#used d), s);
   #used d := !(#used d) + 1)

fun dynamicCreateWith divisor buffer =
  if divisor < 2 then raise Fail "shrink_divisor must be >= 2"
  else
    let val d = dynamicBlank divisor
    in List.app (dynamicPush d) (phokenize buffer); d end

fun dynamicCreate buffer = dynamicCreateWith 4 buffer

fun dynamicLoad (d : dynamicPhext) buffer =
  (#slots d := Array.array (1, emptyScroll);
   #used d := 0; #cap d := 1; #resizes d := 0; #copied d := 0;
   List.app (dynamicPush d) (phokenize buffer))

fun dynamicScrolls (d : dynamicPhext) =
  List.tabulate (!(#used d), fn i => Array.sub (!(#slots d), i))

fun dynamicSerialize d = dephokenize (dynamicScrolls d)

fun dynamicLocate (d : dynamicPhext) coord =
  let
    val lo = ref 0 val hi = ref (!(#used d)) val found = ref ~1
  in
    while (!lo < !hi andalso !found < 0) do
      let
        val mid = (!lo + !hi) div 2
        val c = coordCompare (#coord (Array.sub (!(#slots d), mid)), coord)
      in
        case c of
          LESS => lo := mid + 1
        | GREATER => hi := mid
        | EQUAL => found := mid
      end;
    if !found >= 0 then (!found, true) else (!lo, false)
  end

fun dynamicFetch d coord =
  let val (idx, ok) = dynamicLocate d coord
  in if ok then #text (Array.sub (!(#slots d), idx)) else "" end

fun dynamicContains d coord = #2 (dynamicLocate d coord)
fun dynamicLen (d : dynamicPhext) = !(#used d)
fun dynamicCapacity (d : dynamicPhext) = !(#cap d)

fun dynamicAppend (d : dynamicPhext) coord text =
  (if !(#used d) > 0 andalso
        coordCompare (coord, #coord (Array.sub (!(#slots d), !(#used d) - 1))) <> GREATER
   then raise Fail "append requires a coordinate past the current tail"
   else ();
   if text <> "" then dynamicPush d { coord = coord, text = text } else ())

fun dynamicShrink (d : dynamicPhext) =
  if !(#cap d) > 1 andalso !(#used d) <= !(#cap d) div (#shrinkDivisor d)
  then dynamicResize d (Int.max (1, !(#cap d) div 2))
  else ()

fun dynamicDelete (d : dynamicPhext) idx =
  let
    fun shift i =
      if i >= !(#used d) - 1 then ()
      else (Array.update (!(#slots d), i, Array.sub (!(#slots d), i + 1)); shift (i + 1))
  in
    shift idx;
    #used d := !(#used d) - 1;
    dynamicShrink d
  end

fun dynamicUpdate (d : dynamicPhext) coord text overwrite =
  let val (idx, ok) = dynamicLocate d coord in
    if ok then
      if text = "" then (if overwrite then dynamicDelete d idx else ())
      else
        let val t = if overwrite then text
                    else #text (Array.sub (!(#slots d), idx)) ^ text
        in Array.update (!(#slots d), idx, { coord = coord, text = t }) end
    else if text <> "" then
      (if !(#used d) = !(#cap d) then dynamicResize d (2 * !(#cap d)) else ();
       let
         fun shift i =
           if i <= idx then ()
           else (Array.update (!(#slots d), i, Array.sub (!(#slots d), i - 1));
                 shift (i - 1))
       in
         shift (!(#used d));
         Array.update (!(#slots d), idx, { coord = coord, text = text });
         #used d := !(#used d) + 1
       end)
    else ()
  end

fun dynamicInsert d coord text = dynamicUpdate d coord text false
fun dynamicReplace d coord text = dynamicUpdate d coord text true

fun dynamicRemove d coord =
  let val (idx, ok) = dynamicLocate d coord
  in if ok then dynamicDelete d idx else () end

(* ---------- TransitivePhext: branching hash map, depth 9 ---------- *)
datatype bnode = BNode of { kids : (int * bnode) list ref, leaf : string option ref }

type transitivePhext = { root : bnode, count : int ref, depth : int }

fun newBNode () = BNode { kids = ref [], leaf = ref NONE }

fun transitiveCreate buffer =
  let
    val t = { root = newBNode (), count = ref 0, depth = 9 }
    fun put node [] value =
          let val BNode { leaf, ... } = node in
            (case !leaf of
               NONE => (leaf := SOME value; true)
             | SOME _ => (leaf := SOME value; false))
          end
      | put node (k :: rest) value =
          let
            val BNode { kids, ... } = node
            val child =
              case List.find (fn (kk, _) => kk = k) (!kids) of
                SOME (_, c) => c
              | NONE =>
                  let val c = newBNode ()
                  in kids := (k, c) :: !kids; c end
          in put child rest value end
    val () = List.app
      (fn s => if put (#root t) (#coord s) (#text s)
               then #count t := !(#count t) + 1 else ())
      (phokenize buffer)
  in t end

fun transitiveDepth (t : transitivePhext) = #depth t

fun transitiveLoad (t : transitivePhext) buffer =
  let
    val BNode { kids, leaf } = #root t
    val () = kids := []
    val () = leaf := NONE
    val () = #count t := 0
    fun put node [] value =
          let val BNode { leaf = lf, ... } = node in
            (case !lf of
               NONE => (lf := SOME value; true)
             | SOME _ => (lf := SOME value; false))
          end
      | put node (k :: rest) value =
          let
            val BNode { kids = kd, ... } = node
            val child =
              case List.find (fn (kk, _) => kk = k) (!kd) of
                SOME (_, c) => c
              | NONE =>
                  let val c = newBNode ()
                  in kd := (k, c) :: !kd; c end
          in put child rest value end
    val () = List.app
      (fn sc => if put (#root t) (#coord sc) (#text sc)
                then #count t := !(#count t) + 1 else ())
      (phokenize buffer)
  in () end

fun bFetch node [] =
      let val BNode { leaf, ... } = node in !leaf end
  | bFetch node (k :: rest) =
      let val BNode { kids, ... } = node in
        case List.find (fn (kk, _) => kk = k) (!kids) of
          SOME (_, c) => bFetch c rest
        | NONE => NONE
      end

fun transitiveFetch (t : transitivePhext) coord =
  case bFetch (#root t) coord of SOME v => v | NONE => ""

fun transitiveContains (t : transitivePhext) coord =
  case bFetch (#root t) coord of SOME _ => true | NONE => false

fun transitiveLen (t : transitivePhext) = !(#count t)

fun bItems node prefix acc =
  let val BNode { kids, leaf } = node in
    if List.length prefix = 9 then
      (case !leaf of
         SOME v => { coord = prefix, text = v } :: acc
       | NONE => acc)
    else
      let
        val sorted = List.foldl
          (fn (x as (xk, _), acc2) =>
             let fun ins [] = [x]
                   | ins ((y as (yk, _)) :: rest) =
                       if xk <= yk then x :: y :: rest else y :: ins rest
             in ins acc2 end) [] (!kids)
      in
        List.foldl (fn ((k, child), a) => bItems child (prefix @ [k]) a) acc sorted
      end
  end

fun transitiveScrolls (t : transitivePhext) =
  List.rev (bItems (#root t) [] [])

fun transitiveSerialize t = dephokenize (transitiveScrolls t)

fun bPut node [] value =
      let val BNode { leaf, ... } = node in
        (case !leaf of
           NONE => (leaf := SOME value; true)
         | SOME _ => (leaf := SOME value; false))
      end
  | bPut node (k :: rest) value =
      let
        val BNode { kids, ... } = node
        val child =
          case List.find (fn (kk, _) => kk = k) (!kids) of
            SOME (_, c) => c
          | NONE => let val c = newBNode () in kids := (k, c) :: !kids; c end
      in bPut child rest value end

fun bRemove node [] =
      let val BNode { leaf, ... } = node in
        case !leaf of
          SOME _ => (leaf := NONE; true)
        | NONE => false
      end
  | bRemove node (k :: rest) =
      let val BNode { kids, ... } = node in
        case List.find (fn (kk, _) => kk = k) (!kids) of
          NONE => false
        | SOME (_, child) =>
            let
              val removed = bRemove child rest
              val BNode { kids = ck, leaf = cl } = child
            in
              if removed andalso null (!ck) andalso !cl = NONE
              then kids := List.filter (fn (kk, _) => kk <> k) (!kids)
              else ();
              removed
            end
      end

fun transitiveUpdate (t : transitivePhext) coord text overwrite =
  if text = "" then
    (if overwrite andalso bRemove (#root t) coord
     then #count t := !(#count t) - 1 else ())
  else
    let
      val txt = if overwrite then text
                else (case bFetch (#root t) coord of
                        SOME ex => ex ^ text
                      | NONE => text)
    in
      if bPut (#root t) coord txt then #count t := !(#count t) + 1 else ()
    end

fun transitiveInsert t coord text = transitiveUpdate t coord text false
fun transitiveReplace t coord text = transitiveUpdate t coord text true

fun transitiveRemove (t : transitivePhext) coord =
  if bRemove (#root t) coord then #count t := !(#count t) - 1 else ()

fun transitiveAppend t coord text = transitiveInsert t coord text

end
