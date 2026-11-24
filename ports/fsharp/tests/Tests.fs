// Tests.fs -- unit + conformance tests for the F# libphext port.
// Run on the hub:  dotnet run --project tests/tests.fsproj
// Fixtures: set PHEXT_FIXTURES to harness/fixtures (16 input.phext
// files under chains/ and ranges/); every input must round-trip byte-
// identically through explode/implode and normalize idempotently.
module Tests

open System
open System.IO
open System.Text

let mutable failures = 0
let check (cond: bool) (name: string) =
    if cond then printfn "ok - %s" name
    else
        printfn "FAIL - %s" name
        failures <- failures + 1

let C = Phext.Coordinate.Parse
let B (s: string) = Encoding.Latin1.GetBytes(s)

[<EntryPoint>]
let main _ =
    check ((C "2.3.4/5.6.7/8.9.10").ToString() = "2.3.4/5.6.7/8.9.10") "coord round-trip"
    check ((C "1.1.1/1.1.1/1.1.2").CompareTo(C "1.1.1/1.1.1/1.1.10") < 0) "coord order"
    check (try C "1.1.1/1.1.1/1.1.0" |> ignore; false with _ -> true) "coord rejects 0"
    check (try C "1.1.1/1.1.1" |> ignore; false with _ -> true) "coord rejects short"

    let sb = string (char 23)
    let sc = string (char 24)
    let buf = B ("alpha" + sb + "beta" + sc + "gamma")
    check (Phext.fetch buf (C "1.1.1/1.1.1/1.1.1") = B "alpha") "fetch first"
    check (Phext.fetch buf (C "1.1.1/1.1.1/1.1.2") = B "beta") "fetch scroll 2"
    check (Phext.fetch buf (C "1.1.1/1.1.1/1.2.1") = B "gamma") "fetch section 2 scroll 1"
    check (Phext.fetch buf (C "1.1.1/1.1.1/1.1.9") = [||]) "fetch gap is empty"
    check (Phext.normalize buf = buf) "normalize idempotent on canonical"

    let mutable b2 = Phext.insert [||] (C "1.1.1/1.1.1/1.1.2") (B "second")
    check (Phext.fetch b2 (C "1.1.1/1.1.1/1.1.2") = B "second") "insert creates"
    b2 <- Phext.insert b2 (C "1.1.1/1.1.1/1.1.2") (B "+more")
    check (Phext.fetch b2 (C "1.1.1/1.1.1/1.1.2") = B "second+more") "insert concatenates"
    b2 <- Phext.replace b2 (C "1.1.1/1.1.1/1.1.2") (B "replaced")
    check (Phext.fetch b2 (C "1.1.1/1.1.1/1.1.2") = B "replaced") "replace overwrites"

    // remove is coordinate-preserving: later scrolls do NOT shift
    let b3 = B ("one" + sb + "two" + sb + "three")
    let b3r = Phext.remove b3 (C "1.1.1/1.1.1/1.1.2")
    check (Phext.fetch b3r (C "1.1.1/1.1.1/1.1.1") = B "one") "remove keeps first"
    check (Phext.fetch b3r (C "1.1.1/1.1.1/1.1.2") = [||]) "remove empties target"
    check (Phext.fetch b3r (C "1.1.1/1.1.1/1.1.3") = B "three") "remove does not shift later scrolls"

    let gap = Phext.insert [||] (C "3.1.4/1.5.9/2.6.5") (B "far")
    check (Phext.implode (Phext.explode gap) = gap) "explode/implode gap round-trip"

    // DynamicPhext and TransitivePhext equivalence over an edit sequence
    let coords =
        [ "1.1.1/1.1.1/1.1.1"; "1.1.1/1.1.1/1.1.2"; "1.1.1/1.1.1/1.2.1"
          "2.1.1/1.1.1/1.1.1"; "1.1.1/1.1.1/1.1.3" ] |> List.map C
    let dyn = Phext.DynamicPhext()
    let trn = Phext.TransitivePhext()
    let mutable buf2 : byte[] = [||]
    coords |> List.iteri (fun i c ->
        buf2 <- Phext.insert buf2 c (B (sprintf "text%d" (i + 1)))
        dyn.Insert(c, B (sprintf "text%d" (i + 1)))
        trn.Insert(c, B (sprintf "text%d" (i + 1)))
        check (dyn.Serialize() = buf2) (sprintf "dynamic == buffer after insert %d" (i + 1))
        check (trn.Serialize() = buf2) (sprintf "transitive == buffer after insert %d" (i + 1)))
    let mid = coords.[1]
    buf2 <- Phext.remove buf2 mid
    dyn.Remove(mid)
    trn.Remove(mid)
    check (dyn.Serialize() = buf2) "dynamic == buffer after remove"
    check (trn.Serialize() = buf2) "transitive == buffer after remove"
    check (dyn.Fetch(mid) = [||] && trn.Fetch(mid) = [||]) "stores fetch removed as empty"
    check (dyn.Count = 4 && trn.Count = 4) "store lengths"
    dyn.Replace(coords.[0], [||])
    buf2 <- Phext.remove buf2 coords.[0]
    check (dyn.Serialize() = buf2) "dynamic replace-empty removes"
    check (trn.Depth = 9) "transitive depth 9"

    // shared fixtures: 16/16 byte-identical round-trips
    match Environment.GetEnvironmentVariable("PHEXT_FIXTURES") with
    | null | "" -> printfn "skip - PHEXT_FIXTURES not set (fixtures check skipped)"
    | root ->
        let files =
            Directory.GetFiles(root, "input.phext", SearchOption.AllDirectories)
            |> Array.sort
        check (files.Length = 16) (sprintf "found 16 fixture inputs (got %d)" files.Length)
        let mutable okc = 0
        for f in files do
            let data = File.ReadAllBytes(f)
            if Phext.implode (Phext.explode data) = data &&
               Phext.normalize (Phext.normalize data) = Phext.normalize data then
                okc <- okc + 1
            else
                printfn "FAIL - fixture round-trip: %s" f
                failures <- failures + 1
        check (okc = 16) (sprintf "fixtures round-trip %d/16" okc)

    printfn "%s" (if failures > 0 then sprintf "FAILURES: %d" failures else "PASS")
    if failures > 0 then 1 else 0
