// Phext.fs -- libphext port for F# (0.6.1 parity semantics; normative
// reference: libphext-py). Phext is a 9-dimensional plain-text format:
// scrolls of text addressed by a Coordinate, separated in the byte
// stream by dimension-break bytes.
//
// Dimension breaks (dimension index -> byte):
//   0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
//   4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
//   8 scroll 0x17.
// A break at dimension d increments component d and resets all lower
// components to 1. Scroll text is a maximal run of non-break bytes;
// the newline byte 0x0A is ordinary text, NOT a break. All operations
// are on raw bytes (byte[]); text is never interpreted as UTF-8.
//
// Remove is COORDINATE-PRESERVING: the scroll's text is deleted and
// every other scroll keeps its coordinate (the delimiters needed to
// reach it stay); later scrolls do NOT shift.
module Phext

open System
open System.Collections.Generic

let DimensionBreaks : byte[] =
    [| 0x01uy; 0x1Fuy; 0x1Euy; 0x1Duy; 0x1Cuy; 0x1Auy; 0x19uy; 0x18uy; 0x17uy |]

let private breakDimension (b: byte) : int =
    match Array.IndexOf(DimensionBreaks, b) with
    | -1 -> -1
    | d -> d

let isBreak (b: byte) = breakDimension b >= 0

/// A 9-component phext address, each component >= 1, ordered
/// lexicographically. String form: a.b.c/d.e.f/g.h.i
[<CustomEquality; CustomComparison>]
type Coordinate =
    { Parts : int[] }
    static member Default = { Parts = [| 1; 1; 1; 1; 1; 1; 1; 1; 1 |] }
    static member Parse(s: string) : Coordinate =
        let groups = s.Trim().Split('/')
        if groups.Length <> 3 then failwithf "invalid coordinate %s" s
        let parts =
            [| for g in groups do
                   for p in g.Split('.') do
                       match Int32.TryParse(p) with
                       | true, n when n >= 1 -> yield n
                       | _ -> failwithf "invalid coordinate %s" s |]
        if parts.Length <> 9 then failwithf "invalid coordinate %s" s
        { Parts = parts }
    override c.ToString() =
        let p = c.Parts
        sprintf "%d.%d.%d/%d.%d.%d/%d.%d.%d" p.[0] p.[1] p.[2] p.[3] p.[4] p.[5] p.[6] p.[7] p.[8]
    member c.CompareTo(o: Coordinate) =
        let rec loop i =
            if i = 9 then 0
            elif c.Parts.[i] <> o.Parts.[i] then compare c.Parts.[i] o.Parts.[i]
            else loop (i + 1)
        loop 0
    interface IComparable with
        member c.CompareTo(obj) =
            match obj with
            | :? Coordinate as o -> c.CompareTo(o)
            | _ -> 1
    override c.Equals(obj) =
        match obj with
        | :? Coordinate as o -> c.CompareTo(o) = 0
        | _ -> false
    override c.GetHashCode() =
        let mutable h = 17
        for p in c.Parts do h <- h * 31 + p
        h
    /// Advance at dimension d: component d increments, lower reset to 1.
    member c.ApplyBreak(d: int) : Coordinate =
        let p = Array.copy c.Parts
        p.[d] <- p.[d] + 1
        for j in d + 1 .. 8 do p.[j] <- 1
        { Parts = p }

type PositionedScroll = { Coord : Coordinate; Text : byte[] }

/// Split a buffer into its ordered (coordinate, text) scrolls.
let phokenize (buffer: byte[]) : PositionedScroll list =
    let out = ResizeArray<PositionedScroll>()
    let mutable walker = Coordinate.Default
    let mutable i = 0
    while i < buffer.Length do
        let d = breakDimension buffer.[i]
        if d >= 0 then
            walker <- walker.ApplyBreak(d)
            i <- i + 1
        else
            let start = i
            while i < buffer.Length && not (isBreak buffer.[i]) do i <- i + 1
            out.Add({ Coord = walker; Text = buffer.[start .. i - 1] })
    List.ofSeq out

let private advance (loc: byref<Coordinate>) (target: Coordinate) : byte[] =
    if loc.CompareTo(target) >= 0 then [||]
    else
        let mutable d = 0
        while loc.Parts.[d] = target.Parts.[d] do d <- d + 1
        let out = ResizeArray<byte>()
        for _ in loc.Parts.[d] .. target.Parts.[d] - 1 do out.Add(DimensionBreaks.[d])
        let reached = Array.copy loc.Parts
        reached.[d] <- target.Parts.[d]
        for j in d + 1 .. 8 do reached.[j] <- 1
        for lower in d + 1 .. 8 do
            for _ in 1 .. target.Parts.[lower] - 1 do out.Add(DimensionBreaks.[lower])
            reached.[lower] <- target.Parts.[lower]
        loc <- { Parts = reached }
        out.ToArray()

/// Serialize scrolls (ascending coordinate order) into canonical bytes.
let dephokenize (scrolls: PositionedScroll list) : byte[] =
    let out = ResizeArray<byte>()
    let mutable loc = Coordinate.Default
    for ps in scrolls do
        out.AddRange(advance &loc ps.Coord)
        out.AddRange(ps.Text)
    out.ToArray()

let normalize (buffer: byte[]) : byte[] = dephokenize (phokenize buffer)

let fetch (buffer: byte[]) (coord: Coordinate) : byte[] =
    match phokenize buffer |> List.tryFind (fun ps -> ps.Coord = coord) with
    | Some ps -> ps.Text
    | None -> [||]

let private update (buffer: byte[]) (coord: Coordinate) (text: byte[]) (overwrite: bool) : byte[] =
    let items = phokenize buffer
    let result = ResizeArray<PositionedScroll>()
    let mutable appended = false
    for ps in items do
        if ps.Coord.CompareTo(coord) > 0 && not appended then
            result.Add({ Coord = coord; Text = text })
            appended <- true
        if ps.Coord = coord && not appended then
            let t = if overwrite then text else Array.append ps.Text text
            result.Add({ Coord = coord; Text = t })
            appended <- true
        else
            result.Add(ps)
    if not appended then result.Add({ Coord = coord; Text = text })
    dephokenize (List.ofSeq result)

/// Insert adds text at coord: existing scroll text + new text.
let insert (buffer: byte[]) (coord: Coordinate) (text: byte[]) : byte[] =
    update buffer coord text false

/// Replace overwrites the scroll at coord (creating it if absent).
let replace (buffer: byte[]) (coord: Coordinate) (text: byte[]) : byte[] =
    update buffer coord text true

/// Remove deletes the scroll at coord, coordinate-preserving.
let remove (buffer: byte[]) (coord: Coordinate) : byte[] =
    normalize (update buffer coord [||] true)

let explode (buffer: byte[]) : Map<Coordinate, byte[]> =
    phokenize buffer |> List.map (fun ps -> ps.Coord, ps.Text) |> Map.ofList

let implode (m: Map<Coordinate, byte[]>) : byte[] =
    m |> Map.toList |> List.map (fun (c, t) -> { Coord = c; Text = t }) |> dephokenize

// ---------------------------------------------------------------------
/// Dynamic-array scroll store (mirror of phext/dynamic.py): capacity
/// starts at 1, doubles when full, halves at quarter-full; kept in
/// strictly increasing coordinate order; serialize() is byte-identical
/// to the buffer API. Stores never hold an empty scroll.
type DynamicPhext(?buffer: byte[], ?shrinkDivisor: int) =
    let shrinkDiv = defaultArg shrinkDivisor 4
    do if shrinkDiv < 2 then invalidArg "shrinkDivisor" "must be >= 2"
    let mutable data : PositionedScroll[] = Array.zeroCreate 1
    let mutable capacity = 1
    let mutable n = 0
    let mutable resizeCount = 0
    let mutable elementsCopied = 0
    let resize (newCap: int) =
        let nd = Array.zeroCreate newCap
        Array.Copy(data, nd, n)
        data <- nd
        capacity <- newCap
        resizeCount <- resizeCount + 1
        elementsCopied <- elementsCopied + n
    let growIfFull () = if n = capacity then resize (2 * capacity)
    let shrinkIfSparse () =
        if capacity > 1 && n <= capacity / shrinkDiv then
            resize (max 1 (capacity / 2))
    let find (coord: Coordinate) : int * bool =
        let mutable lo, hi = 0, n
        let mutable found = -1
        while lo < hi && found < 0 do
            let mid = (lo + hi) / 2
            let cmp = data.[mid].Coord.CompareTo(coord)
            if cmp < 0 then lo <- mid + 1
            elif cmp > 0 then hi <- mid
            else found <- mid
        if found >= 0 then (found, true) else (lo, false)
    let push (ps: PositionedScroll) =
        growIfFull ()
        data.[n] <- ps
        n <- n + 1
    let removeAt (idx: int) =
        for i in idx .. n - 2 do data.[i] <- data.[i + 1]
        n <- n - 1
        data.[n] <- Unchecked.defaultof<PositionedScroll>
        shrinkIfSparse ()
    do match buffer with
       | Some b when b.Length > 0 ->
           for ps in phokenize b do push ps
       | _ -> ()
    member _.Capacity = capacity
    member _.ResizeCount = resizeCount
    member _.ElementsCopied = elementsCopied
    member _.Count = n
    member _.Scrolls = [ for i in 0 .. n - 1 -> data.[i] ]
    member x.Serialize() = dephokenize x.Scrolls
    member _.Fetch(coord: Coordinate) =
        match find coord with
        | idx, true -> data.[idx].Text
        | _ -> [||]
    member _.Contains(coord: Coordinate) = snd (find coord)
    member _.Append(coord: Coordinate, text: byte[]) =
        if n > 0 && coord.CompareTo(data.[n - 1].Coord) <= 0 then
            invalidArg "coord" "append requires a coordinate past the current tail"
        if text.Length > 0 then push { Coord = coord; Text = text }
    member _.Update(coord: Coordinate, text: byte[], overwrite: bool) =
        match find coord with
        | idx, true ->
            if text.Length = 0 then
                if overwrite then removeAt idx
            else
                let t = if overwrite then text else Array.append data.[idx].Text text
                data.[idx] <- { Coord = coord; Text = t }
        | idx, false ->
            if text.Length > 0 then
                growIfFull ()
                for i in n .. -1 .. idx + 1 do data.[i] <- data.[i - 1]
                data.[idx] <- { Coord = coord; Text = text }
                n <- n + 1
    member x.Insert(coord: Coordinate, text: byte[]) = x.Update(coord, text, false)
    member x.Replace(coord: Coordinate, text: byte[]) = x.Update(coord, text, true)
    member _.Remove(coord: Coordinate) =
        match find coord with
        | idx, true -> removeAt idx
        | _ -> ()

// ---------------------------------------------------------------------
/// Branching hash-map store (mirror of phext/transitive.py): one
/// Dictionary layer per coordinate dimension (depth 9, derived from
/// the coordinate), leaves holding scroll text. Serialization walks
/// the hierarchy in sorted key order at every level.
type TransitivePhext(?buffer: byte[]) =
    let depth = 9
    let mutable root : Dictionary<int, obj> = Dictionary()
    let mutable count = 0
    let rec putRec (node: Dictionary<int, obj>) (key: int[]) (level: int) (value: byte[]) : bool =
        let comp = key.[level]
        if level = depth - 1 then
            let created = not (node.ContainsKey comp)
            node.[comp] <- box value
            created
        else
            let child =
                match node.TryGetValue comp with
                | true, (:? Dictionary<int, obj> as d) -> d
                | _ ->
                    let d = Dictionary<int, obj>()
                    node.[comp] <- box d
                    d
            putRec child key (level + 1) value
    let rec fetchRec (node: Dictionary<int, obj>) (key: int[]) (level: int) : byte[] option =
        match node.TryGetValue key.[level] with
        | false, _ -> None
        | true, v ->
            if level = depth - 1 then Some (unbox<byte[]> v)
            else fetchRec (unbox<Dictionary<int, obj>> v) key (level + 1)
    let rec removeRec (node: Dictionary<int, obj>) (key: int[]) (level: int) : bool =
        let comp = key.[level]
        if not (node.ContainsKey comp) then false
        elif level = depth - 1 then
            node.Remove comp |> ignore
            true
        else
            let child = unbox<Dictionary<int, obj>> node.[comp]
            let removed = removeRec child key (level + 1)
            if removed && child.Count = 0 then node.Remove comp |> ignore
            removed
    let rec itemsRec (node: Dictionary<int, obj>) (prefix: int list) (out: ResizeArray<PositionedScroll>) =
        let keys = List.ofSeq node.Keys |> List.sort
        for comp in keys do
            if List.length prefix = depth - 1 then
                out.Add({ Coord = { Parts = Array.ofList (prefix @ [comp]) }
                          Text = unbox<byte[]> node.[comp] })
            else
                itemsRec (unbox<Dictionary<int, obj>> node.[comp]) (prefix @ [comp]) out
    do match buffer with
       | Some b when b.Length > 0 ->
           for ps in phokenize b do
               if putRec root ps.Coord.Parts 0 ps.Text then count <- count + 1
       | _ -> ()
    member _.Depth = depth
    member _.Count = count
    member _.Scrolls =
        let out = ResizeArray<PositionedScroll>()
        itemsRec root [] out
        List.ofSeq out
    member x.Serialize() = dephokenize x.Scrolls
    member _.Fetch(coord: Coordinate) =
        match fetchRec root coord.Parts 0 with
        | Some t -> t
        | None -> [||]
    member _.Contains(coord: Coordinate) = (fetchRec root coord.Parts 0).IsSome
    member _.Remove(coord: Coordinate) =
        if removeRec root coord.Parts 0 then count <- count - 1
    member x.Update(coord, text: byte[], overwrite: bool) =
        if text.Length = 0 then
            if overwrite then x.Remove(coord)
        else
            let t =
                if overwrite then text
                else match fetchRec root coord.Parts 0 with
                     | Some existing -> Array.append existing text
                     | None -> text
            if putRec root coord.Parts 0 t then count <- count + 1
    member x.Insert(coord: Coordinate, text: byte[]) = x.Update(coord, text, false)
    member x.Replace(coord: Coordinate, text: byte[]) = x.Update(coord, text, true)
    member x.Append(coord: Coordinate, text: byte[]) = x.Insert(coord, text)
