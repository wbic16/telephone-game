// Program.fs -- Exocortical Telephone Game CLI (contract v2) for the
// F# libphext port. Wire protocol: one JSON request in, one JSON
// response out; with the argument "serve" it loops over JSON lines.
// Commands: id, echo, elect, choose, apply, keygen, attest, validate
// (both the prior_state form and the driver's init/event_coord/
// index_line form), init, verify. All phext operations use this port's
// own Phext.fs; canonical JSON is this port's own writer (compact,
// sorted keys, Python ensure_ascii escaping, number literals kept
// verbatim). PGP via subprocess gpg (key home $TELEPHONE_GNUPGHOME or
// ~/telephone-fsharp/gnupg; private keys never leave it).
module Program

open System
open System.IO
open System.Text
open System.Text.Json
open System.Security.Cryptography
open System.Diagnostics

let IMPL = "fsharp"
let latin1 = Encoding.Latin1
let utf8 = Encoding.UTF8

// ------------------------------------------------------------ JSON values
type JVal =
    | JNull
    | JBool of bool
    | JNum of string
    | JStr of string
    | JArr of JVal list
    | JObj of (string * JVal) list

let rec fromElement (el: JsonElement) : JVal =
    match el.ValueKind with
    | JsonValueKind.Null | JsonValueKind.Undefined -> JNull
    | JsonValueKind.True -> JBool true
    | JsonValueKind.False -> JBool false
    | JsonValueKind.Number -> JNum (el.GetRawText())
    | JsonValueKind.String -> JStr (el.GetString())
    | JsonValueKind.Array -> JArr [ for e in el.EnumerateArray() -> fromElement e ]
    | JsonValueKind.Object ->
        JObj [ for p in el.EnumerateObject() -> (p.Name, fromElement p.Value) ]
    | _ -> JNull

let parseJson (text: string) : JVal =
    use doc = JsonDocument.Parse(text)
    fromElement doc.RootElement

let canonString (s: string) : string =
    let sb = StringBuilder()
    sb.Append('"') |> ignore
    // iterate by Unicode scalar via Rune enumeration
    let mutable i = 0
    while i < s.Length do
        let (rune, len) =
            if Char.IsHighSurrogate(s.[i]) && i + 1 < s.Length && Char.IsLowSurrogate(s.[i + 1]) then
                (Text.Rune(Char.ConvertToUtf32(s.[i], s.[i + 1])), 2)
            else
                (Text.Rune(int s.[i]), 1)
        i <- i + len
        let v = rune.Value
        match v with
        | 0x22 -> sb.Append("\\\"") |> ignore
        | 0x5C -> sb.Append("\\\\") |> ignore
        | 0x08 -> sb.Append("\\b") |> ignore
        | 0x0C -> sb.Append("\\f") |> ignore
        | 0x0A -> sb.Append("\\n") |> ignore
        | 0x0D -> sb.Append("\\r") |> ignore
        | 0x09 -> sb.Append("\\t") |> ignore
        | _ when v < 0x20 || v > 0x7E ->
            if v > 0xFFFF then
                let x = v - 0x10000
                sb.Append(sprintf "\\u%04x\\u%04x" (0xD800 + (x >>> 10)) (0xDC00 + (x &&& 0x3FF))) |> ignore
            else
                sb.Append(sprintf "\\u%04x" v) |> ignore
        | _ -> sb.Append(rune.ToString()) |> ignore
    sb.Append('"') |> ignore
    sb.ToString()

let rec canon (v: JVal) : string =
    match v with
    | JNull -> "null"
    | JBool b -> if b then "true" else "false"
    | JNum raw -> raw
    | JStr s -> canonString s
    | JArr items -> "[" + String.Join(",", items |> List.map canon) + "]"
    | JObj pairs ->
        let sorted = pairs |> List.sortBy fst
        "{" + String.Join(",", sorted |> List.map (fun (k, x) -> canonString k + ":" + canon x)) + "}"

let jget (v: JVal) (key: string) : JVal option =
    match v with
    | JObj pairs -> pairs |> List.tryFind (fun (k, _) -> k = key) |> Option.map snd
    | _ -> None

let jstr (v: JVal) : string =
    match v with JStr s -> s | JNum n -> n | _ -> ""

let jnumRaw (v: JVal) : string =
    match v with JNum n -> n | JStr s -> s | _ -> "0"

// ------------------------------------------------------------ utilities
let sha256hex (b: byte[]) : string =
    Convert.ToHexString(SHA256.HashData(b)).ToLowerInvariant()

let b64enc (b: byte[]) = Convert.ToBase64String(b)
let b64dec (s: string) : byte[] =
    try Convert.FromBase64String(s) with _ -> [||]

let coordOf (s: string) = Phext.Coordinate.Parse(s)
let INDEX_COORD = coordOf "1.1.1/1.1.1/1.1.1"
let KEYS_COORD = coordOf "1.1.1/1.1.1/1.1.2"
let KH_COORD = coordOf "1.1.1/1.1.1/1.1.3"
let eventCoord (seq: int) : Phext.Coordinate =
    { Parts = [| 1; 1; 1; 1; 1; 1; 2; 1; seq |] }

// ------------------------------------------------------------ gpg
let gnupgHome () =
    match Environment.GetEnvironmentVariable("TELEPHONE_GNUPGHOME") with
    | null | "" ->
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                     "telephone-" + IMPL, "gnupg")
    | h -> h

let KEY_UID = "libphext telephone " + IMPL

let runGpg (home: string) (args: string list) (input: byte[] option) : byte[] =
    Directory.CreateDirectory(home) |> ignore
    let psi = ProcessStartInfo("gpg")
    psi.ArgumentList.Add("--batch")
    psi.ArgumentList.Add("--yes")
    psi.ArgumentList.Add("--pinentry-mode")
    psi.ArgumentList.Add("loopback")
    psi.ArgumentList.Add("--passphrase")
    psi.ArgumentList.Add("")
    psi.ArgumentList.Add("--homedir")
    psi.ArgumentList.Add(home)
    for a in args do psi.ArgumentList.Add(a)
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError <- true
    psi.RedirectStandardInput <- input.IsSome
    psi.UseShellExecute <- false
    use p = Process.Start(psi)
    match input with
    | Some bytes ->
        p.StandardInput.BaseStream.Write(bytes, 0, bytes.Length)
        p.StandardInput.Close()
    | None -> ()
    let out = p.StandardOutput.ReadToEnd()
    let err = p.StandardError.ReadToEnd()
    p.WaitForExit()
    if p.ExitCode <> 0 then failwithf "gpg %A failed: %s" args err
    utf8.GetBytes(out)

let keygen () : string =
    let home = gnupgHome ()
    let listing = runGpg home [ "--list-keys"; "--with-colons" ] None |> utf8.GetString
    if not (listing.Contains("pub:")) then
        runGpg home [ "--quick-gen-key"; KEY_UID; "ed25519"; "sign"; "never" ] None |> ignore
    let pub = runGpg home [ "--armor"; "--export"; KEY_UID ] None |> utf8.GetString
    if pub.EndsWith("\n") then pub else pub + "\n"

let detachSign (data: byte[]) : string =
    let dir = Path.Combine(Path.GetTempPath(), "telephone-" + IMPL + "-sign-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(dir) |> ignore
    try
        let plain = Path.Combine(dir, "descriptor.json")
        let sigPath = Path.Combine(dir, "descriptor.asc")
        File.WriteAllBytes(plain, data)
        runGpg (gnupgHome ()) [ "--detach-sign"; "--armor"; "--local-user"; KEY_UID;
                                "--output"; sigPath; plain ] None |> ignore
        File.ReadAllText(sigPath)
    finally
        try Directory.Delete(dir, true) with _ -> ()

let verifySignature (pubkeys: string) (data: byte[]) (signature: string) : unit =
    let dir = Path.Combine(Path.GetTempPath(), "telephone-" + IMPL + "-verify-" + Guid.NewGuid().ToString("N"))
    let home = Path.Combine(dir, "gnupg")
    Directory.CreateDirectory(home) |> ignore
    try
        let kf = Path.Combine(dir, "keys.asc")
        let pf = Path.Combine(dir, "descriptor.json")
        let sf = Path.Combine(dir, "descriptor.asc")
        File.WriteAllText(kf, pubkeys)
        File.WriteAllBytes(pf, data)
        File.WriteAllText(sf, signature)
        runGpg home [ "--import"; kf ] None |> ignore
        runGpg home [ "--verify"; sf; pf ] None |> ignore
    finally
        try Directory.Delete(dir, true) with _ -> ()

// ------------------------------------------------------------ game logic
let echoValue (ping: JVal) : string =
    let game = jget ping "game" |> Option.map jstr |> Option.defaultValue ""
    let round =
        match jget ping "round" with
        | Some r -> jnumRaw r
        | None -> jget ping "turn" |> Option.map jnumRaw |> Option.defaultValue ""
    let nonce = jget ping "nonce" |> Option.map jstr |> Option.defaultValue ""
    sha256hex (utf8.GetBytes(sprintf "%s|%s|%s|%s" IMPL game round nonce))

let electWinner (position: string) (candidates: string list) (turn: int) : string =
    let mutable seedInput = ResizeArray<byte>()
    seedInput.AddRange(utf8.GetBytes(position))
    seedInput.Add(byte (turn % 256))
    seedInput.AddRange(utf8.GetBytes(String.Join(",", candidates)))
    let h = SHA256.HashData(seedInput.ToArray())
    candidates.[int h.[0] % candidates.Length]

let wrap999 v = (v - 1) % 999 + 1

let nextCoord (c: Phext.Coordinate) : Phext.Coordinate =
    let p = Array.copy c.Parts
    let mutable d = 8
    let mutable done_ = false
    while d >= 0 && not done_ do
        if p.[d] < 999 then
            p.[d] <- p.[d] + 1
            done_ <- true
        else
            p.[d] <- 1
            d <- d - 1
    { Parts = p }

let chooseAdventure (state: byte[]) (position: string) (turn: int) : JVal =
    let pos = coordOf position
    let used = Phext.explode state |> ref
    for rc in [ INDEX_COORD; KEYS_COORD; KH_COORD ] do
        used.Value <- Map.add rc [| 0uy |] used.Value
    let mutable seedInput = ResizeArray<byte>()
    seedInput.AddRange(utf8.GetBytes(position))
    seedInput.Add(byte (turn % 256))
    seedInput.AddRange(state)
    let seed = SHA256.HashData(seedInput.ToArray())
    let mutable cand = pos
    let dim = int seed.[1] % 9
    let p = Array.copy cand.Parts
    p.[dim] <- wrap999 (p.[dim] + 1 + int seed.[2] % 3)
    cand <- { Parts = p }
    while Map.containsKey cand used.Value do
        cand <- nextCoord cand
    let cs = cand.ToString()
    JObj [ "op", JStr "insert"; "coordinate", JStr cs
           "text", JStr (sprintf "%s turn %d at %s" IMPL turn cs) ]

let applyStep (state: byte[]) (step: JVal) : byte[] * JVal =
    let op = jget step "op" |> Option.map jstr |> Option.defaultValue ""
    let coord = coordOf (jget step "coordinate" |> Option.map jstr |> Option.defaultValue "1.1.1/1.1.1/1.1.1")
    let text = jget step "text" |> Option.map jstr |> Option.defaultValue "" |> latin1.GetBytes
    let mutable fetchHash : string option = None
    let newState =
        match op with
        | "insert" -> Phext.insert state coord text
        | "replace" -> Phext.replace state coord text
        | "remove" -> Phext.remove state coord
        | "fetch" ->
            fetchHash <- Some (sha256hex (Phext.fetch state coord))
            state
        | _ -> state
    let resp =
        JObj [ "state_b64", JStr (b64enc newState)
               "state_sha256", JStr (sha256hex newState)
               "fetch_sha256", (match fetchHash with Some h -> JStr h | None -> JNull) ]
    (newState, resp)

// validate: cache for the driver's form
let mutable cacheMap : Map<Phext.Coordinate, byte[]> option = None

let vfail (detail: string) : JVal =
    JObj [ "impl", JStr IMPL; "verdict", JStr "fail"; "detail", JStr detail ]

let doValidate (req: JVal) (state: byte[]) : JVal =
    let step = jget req "step" |> Option.defaultValue JNull
    let op = jget step "op" |> Option.map jstr |> Option.defaultValue ""
    match jget req "prior_state" with
    | Some priorB64 ->
        if op <> "insert" then vfail "step op is not insert"
        else
            let coordS = jget step "coordinate" |> Option.map jstr |> Option.defaultValue ""
            let coord = coordOf coordS
            let text = jget step "text" |> Option.map jstr |> Option.defaultValue "" |> latin1.GetBytes
            let prior = b64dec (jstr priorB64)
            if Phext.fetch state coord <> text then
                vfail ("placed scroll absent or content differs at " + coordS)
            elif Phext.fetch prior coord <> [||] then
                vfail "coordinate was not unused in the prior state"
            else
                let before = Phext.explode prior
                let after = Phext.explode state
                if after.Count <> before.Count + 1 then
                    vfail "scroll count did not grow by exactly one"
                else
                    match before |> Map.tryFindKey (fun c t -> not (Map.containsKey c after) || after.[c] <> t) with
                    | Some c -> vfail ("a prior scroll was overwritten: " + c.ToString())
                    | None ->
                        JObj [ "impl", JStr IMPL; "verdict", JStr "pass"
                               "detail", JStr "placed at unused coordinate; all prior scrolls intact" ]
    | None ->
        match cacheMap with
        | None -> vfail "validate called before init"
        | Some old ->
            let newMap = Phext.explode state
            let coordS = jget step "coordinate" |> Option.map jstr |> Option.defaultValue ""
            let coord = coordOf coordS
            let evCoord = coordOf (jget req "event_coord" |> Option.map jstr |> Option.defaultValue "1.1.1/1.1.1/1.1.1")
            let indexLine = jget req "index_line" |> Option.map jstr |> Option.defaultValue ""
            let text = jget step "text" |> Option.map jstr |> Option.defaultValue "" |> latin1.GetBytes
            if (match Map.tryFind coord newMap with Some t -> t | None -> [||]) <> text then
                vfail "placed scroll missing or altered"
            else
                let isOverwritten c t =
                    c <> INDEX_COORD
                    && (not (Map.containsKey c newMap) || newMap.[c] <> t)
                let overwritten = old |> Map.tryFindKey isOverwritten
                match overwritten with
                | Some c -> vfail ("prior scroll overwritten at " + c.ToString())
                | None ->
                    let unexpected =
                        newMap |> Map.tryFindKey (fun c _ ->
                            not (Map.containsKey c old) && c <> coord && c <> evCoord)
                    match unexpected with
                    | Some c -> vfail ("unexpected new scroll at " + c.ToString())
                    | None ->
                        let idx = match Map.tryFind INDEX_COORD newMap with Some t -> latin1.GetString(t) | None -> ""
                        if not (idx.TrimEnd('\n').EndsWith(indexLine.TrimEnd('\n'))) then
                            vfail "index does not record the placement"
                        else
                            cacheMap <- Some newMap
                            JObj [ "impl", JStr IMPL; "verdict", JStr "pass" ]

let verifyFail (n: int) (msg: string) : JVal =
    JObj [ "impl", JStr IMPL; "verdict", JStr "fail"
           "placements_checked", JNum (string n)
           "first_failure", JObj [ "detail", JStr msg ] ]

let doVerify (state: byte[]) (pubkeys: string) : JVal =
    let scrolls = Phext.explode state
    match Map.tryFind KEYS_COORD scrolls with
    | None -> verifyFail 0 "no public-keys scroll at 1.1.1/1.1.1/1.1.2"
    | Some keysBytes when keysBytes.Length = 0 ->
        verifyFail 0 "no public-keys scroll at 1.1.1/1.1.1/1.1.2"
    | Some keysBytes ->
        let keysText = latin1.GetString(keysBytes)
        if pubkeys.TrimEnd([| ' '; '\t'; '\r'; '\n' |]) <> keysText.TrimEnd([| ' '; '\t'; '\r'; '\n' |]) then
            verifyFail 0 "supplied pubkeys do not match the inscribed keys scroll"
        else
            match Map.tryFind KH_COORD scrolls with
            | None -> verifyFail 0 "no keys-hash scroll at 1.1.1/1.1.1/1.1.3"
            | Some khBytes ->
                if (latin1.GetString(khBytes)).Trim() <> sha256hex keysBytes then
                    verifyFail 0 "keys-hash scroll does not match the keys scroll"
                else
                    let index = Collections.Generic.Dictionary<string, string[]>()
                    match Map.tryFind INDEX_COORD scrolls with
                    | Some idxBytes ->
                        for line in (latin1.GetString(idxBytes)).Split('\n') do
                            let t = line.Trim()
                            if t <> "" && not (t.StartsWith("#")) then
                                let fields = t.Split([| ' '; '\t' |], StringSplitOptions.RemoveEmptyEntries)
                                if fields.Length = 4 then index.[fields.[1]] <- fields
                    | None -> ()
                    let mutable checked = 0
                    let mutable failure : string option = None
                    let seen = Collections.Generic.HashSet<string>()
                    let mutable prevHash = ""
                    let mutable seq = 1
                    let mutable go = true
                    while go && failure.IsNone do
                        match Map.tryFind (eventCoord seq) scrolls with
                        | None -> go <- false
                        | Some evBytes ->
                            let evText = utf8.GetString(evBytes)
                            let ev = try parseJson evText with _ -> JNull
                            match jget ev "body" with
                            | None -> failure <- Some (sprintf "event %d lacks a body object" seq)
                            | Some body ->
                                if seq = 1 then
                                    match jget ev "prev" with
                                    | Some JNull -> ()
                                    | _ -> failure <- Some "event 1 prev is not null"
                                else
                                    match jget ev "prev" with
                                    | Some (JStr p) when p = prevHash -> ()
                                    | _ -> failure <- Some (sprintf "event chain broken at seq %d" seq)
                                if failure.IsNone then
                                    prevHash <- sha256hex (utf8.GetBytes(canon body))
                                    if (jget body "type" |> Option.map jstr) = Some "placement" then
                                        let coordS = jget body "coord" |> Option.map jstr |> Option.defaultValue ""
                                        let textHash = jget body "text_sha256" |> Option.map jstr |> Option.defaultValue ""
                                        let fileHash = jget body "file_sha256" |> Option.map jstr |> Option.defaultValue ""
                                        let attB64 = jget body "att" |> Option.map jstr |> Option.defaultValue ""
                                        let turnRaw = jget body "turn" |> Option.map jnumRaw |> Option.defaultValue ""
                                        let actor = jget body "actor" |> Option.map jstr |> Option.defaultValue ""
                                        if coordS = "" || textHash = "" || fileHash = "" || attB64 = "" then
                                            failure <- Some (sprintf "event %d lacks coord/text_sha256/file_sha256/att" seq)
                                        elif seen.Contains(coordS) then
                                            failure <- Some ("coordinate reused at " + coordS)
                                        elif not (Map.containsKey (coordOf coordS) scrolls) then
                                            failure <- Some ("placement missing at " + coordS)
                                        elif sha256hex scrolls.[coordOf coordS] <> textHash then
                                            failure <- Some ("placement hash mismatch at " + coordS)
                                        elif not (index.ContainsKey(coordS)) ||
                                             index.[coordS].[2] <> textHash ||
                                             index.[coordS].[0] <> turnRaw ||
                                             index.[coordS].[3] <> actor then
                                            failure <- Some ("index mismatch at " + coordS)
                                        else
                                            let desc =
                                                JObj [ "turn", (jget body "turn" |> Option.defaultValue JNull)
                                                       "coordinate", JStr coordS
                                                       "scroll_sha256", JStr textHash
                                                       "file_sha256", JStr fileHash ]
                                            let sigText = latin1.GetString(b64dec attB64)
                                            match (try Ok (verifySignature pubkeys (utf8.GetBytes(canon desc)) sigText) with e -> Error e.Message) with
                                            | Error m -> failure <- Some (sprintf "event %d signature: %s" seq m)
                                            | Ok () ->
                                                seen.Add(coordS) |> ignore
                                                checked <- checked + 1
                            seq <- seq + 1
                    match failure with
                    | Some msg -> verifyFail checked msg
                    | None ->
                        if checked = 0 then verifyFail 0 "no placement events found"
                        else
                            match index.Keys |> Seq.tryFind (fun cs -> not (seen.Contains(cs))) with
                            | Some cs -> verifyFail checked ("index lists a placement with no event: " + cs)
                            | None ->
                                JObj [ "impl", JStr IMPL; "verdict", JStr "pass"
                                       "placements_checked", JNum (string checked)
                                       "first_failure", JNull ]

// ------------------------------------------------------------ dispatch
let reqState (req: JVal) : byte[] =
    match jget req "state" with
    | Some s -> b64dec (jstr s)
    | None ->
        match jget req "state_b64" with
        | Some s -> b64dec (jstr s)
        | None -> [||]

let handle (line: string) : JVal =
    let req = parseJson line
    let cmd = jget req "cmd" |> Option.map jstr |> Option.defaultValue ""
    match cmd with
    | "id" -> JObj [ "impl", JStr IMPL ]
    | "echo" ->
        let ping = jget req "ping" |> Option.defaultValue JNull
        JObj [ "impl", JStr IMPL; "echo", JStr (echoValue ping) ]
    | "elect" ->
        let candidates =
            match jget req "candidates" with
            | Some (JArr items) -> items |> List.map jstr
            | _ -> []
        if candidates.IsEmpty then failwith "elect: no candidates"
        let position = jget req "position" |> Option.map jstr |> Option.defaultValue ""
        let turn = jget req "turn" |> Option.map jnumRaw |> Option.defaultValue "0" |> int
        JObj [ "elect", JStr (electWinner position candidates turn) ]
    | "choose" ->
        let position = jget req "position" |> Option.map jstr |> Option.defaultValue ""
        let turn = jget req "turn" |> Option.map jnumRaw |> Option.defaultValue "0" |> int
        chooseAdventure (reqState req) position turn
    | "apply" ->
        let step = jget req "step" |> Option.defaultValue JNull
        snd (applyStep (reqState req) step)
    | "keygen" -> JObj [ "impl", JStr IMPL; "pubkey", JStr (keygen ()) ]
    | "attest" ->
        let desc = jget req "descriptor" |> Option.defaultValue JNull
        JObj [ "signature", JStr (detachSign (utf8.GetBytes(canon desc))) ]
    | "init" ->
        cacheMap <- Some (Phext.explode (reqState req))
        JObj [ "impl", JStr IMPL; "verdict", JStr "pass" ]
    | "validate" -> doValidate req (reqState req)
    | "verify" ->
        let pubkeys = jget req "pubkeys" |> Option.map jstr |> Option.defaultValue ""
        doVerify (reqState req) pubkeys
    | _ -> failwithf "unknown cmd %s" cmd

let emit (v: JVal) =
    Console.Out.Write(canon v + "\n")
    Console.Out.Flush()

[<EntryPoint>]
let main argv =
    if argv.Length > 0 && argv.[0] = "serve" then
        let reader = new StreamReader(Console.OpenStandardInput())
        let mutable line = reader.ReadLine()
        while not (isNull line) do
            if line.Trim() <> "" then
                try emit (handle line)
                with e -> emit (JObj [ "error", JStr (e.GetType().Name + ": " + e.Message) ])
            line <- reader.ReadLine()
        0
    else
        let input = Console.In.ReadToEnd().TrimEnd('\r', '\n')
        try
            emit (handle input)
            0
        with e ->
            Console.Error.WriteLine(e.Message)
            1
