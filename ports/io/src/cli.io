// cli.io -- Exocortical Telephone Game adapter CLI (contract v2)
// for the Io libphext port. Mirrors harness/adapter_base.py and
// the wave-4/5/6a hub CLIs: one JSON object in, one JSON object
// out; state as base64; serve mode speaks JSON lines with GZ1
// framing over 8 KB. Io Sequences are byte-safe, so phext bytes
// move natively; sha256/gzip/gpg go through the standard CLI
// tools over temp files (Io core has no crypto).

doFile("src/phext.io")

// ----------------------------------------------------------------
// JSON: nodes are JVal objects. kind: 0 null, 1 true, 2 false,
// 3 string, 4 number (raw token), 5 array (items = List of JVal),
// 6 object (items = List of list(key, JVal)). Canonical writing
// sorts object keys and uses (",", ":") separators.

JVal := Object clone do(
    kind := 0
    sval := ""
    items := nil

    get := method(key,
        if(kind != 6, return nil)
        items foreach(pair, if(pair at(0) == key, return pair at(1)))
        nil
    )
    gets := method(key,
        v := get(key)
        if(v == nil, "", v sval)
    )
    set := method(key, v,
        items append(list(key, v))
        self
    )
    canon := method(
        if(kind == 0, return "null")
        if(kind == 1, return "true")
        if(kind == 2, return "false")
        if(kind == 3, return Json escape(sval))
        if(kind == 4, return sval)
        if(kind == 5,
            out := Sequence clone appendSeq("[")
            items foreach(i, v,
                if(i > 0, out appendSeq(","))
                out appendSeq(v canon)
            )
            out appendSeq("]")
            return out
        )
        // object: sort member keys
        keys := items map(p, p at(0)) sort
        out := Sequence clone appendSeq("{")
        keys foreach(i, k,
            if(i > 0, out appendSeq(","))
            out appendSeq(Json escape(k))
            out appendSeq(":")
            out appendSeq(get(k) canon)
        )
        out appendSeq("}")
        out
    )
)

Json := Object clone do(
    jstr := method(s,
        v := JVal clone
        v kind = 3
        v sval = s
        v
    )
    jnum := method(n,
        v := JVal clone
        v kind = 4
        v sval = n asString
        v
    )
    jbool := method(b,
        v := JVal clone
        v kind = if(b, 1, 2)
        v
    )
    jnull := method(
        v := JVal clone
        v kind = 0
        v
    )
    jarr := method(
        v := JVal clone
        v kind = 5
        v items = List clone
        v
    )
    jobj := method(
        v := JVal clone
        v kind = 6
        v items = List clone
        v
    )

    escape := method(s,
        // fast path: nothing to escape (the common case, incl.
        // base64 payloads) -- quote and go
        needs := false
        for(i, 0, s size - 1,
            b := s at(i)
            if(b < 32 or b == 34 or b == 92 or b >= 127, needs = true)
        )
        out := Sequence clone append(34)
        if(needs not,
            out appendSeq(s),
            for(i, 0, s size - 1,
                b := s at(i)
                if(b == 34, out appendSeq("\\\""),
                    if(b == 92, out appendSeq("\\\\"),
                        if(b == 10, out appendSeq("\\n"),
                            if(b == 13, out appendSeq("\\r"),
                                if(b == 9, out appendSeq("\\t"),
                                    if(b == 8, out appendSeq("\\b"),
                                        if(b == 12, out appendSeq("\\f"),
                                            if(b < 32 or b >= 127,
                                                out appendSeq("\\u00")
                                                hex := "0123456789abcdef"
                                                out append(hex at((b / 16) floor))
                                                out append(hex at(b % 16)),
                                                out append(b)
                                            )
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )
        out append(34)
        out
    )

    // recursive descent parser; one instance per parse
    parserProto := Object clone do(
        src := ""
        pos := 0
        skipWs := method(
            while(pos < src size and (src at(pos) == 32 or src at(pos) == 10 or src at(pos) == 13 or src at(pos) == 9),
                pos = pos + 1
            )
        )
        parseStringRaw := method(
            pos = pos + 1  // opening quote
            start := pos
            hasesc := false
            done := false
            while(done not,
                ch := src at(pos)
                if(ch == 34, done = true,
                    if(ch == 92, hasesc = true; pos = pos + 2, pos = pos + 1)
                )
            )
            raw := src exSlice(start, pos)
            pos = pos + 1  // closing quote
            if(hasesc, unescape(raw), raw)
        )
        unescape := method(raw,
            out := Sequence clone
            i := 0
            n := raw size
            while(i < n,
                ch := raw at(i)
                if(ch == 92 and i + 1 < n,
                    e := raw at(i + 1)
                    i = i + 2
                    if(e == 110, out append(10),
                        if(e == 116, out append(9),
                            if(e == 114, out append(13),
                                if(e == 98, out append(8),
                                    if(e == 102, out append(12),
                                        if(e == 117,
                                            v := 0
                                            for(q, 0, 3,
                                                h := raw at(i + q)
                                                d := 0
                                                if(h >= 48 and h <= 57, d = h - 48,
                                                    if(h >= 97 and h <= 102, d = h - 87,
                                                        if(h >= 65 and h <= 70, d = h - 55)))
                                                v = v * 16 + d
                                            )
                                            i = i + 4
                                            if(v <= 255, out append(v),
                                                out append(192 + (v / 64) floor)
                                                out append(128 + (v % 64))),
                                            out append(e)
                                        )
                                    )
                                )
                            )
                        )
                    ),
                    out append(ch)
                    i = i + 1
                )
            )
            out
        )
        parseValue := method(
            skipWs
            ch := src at(pos)
            if(ch == 123,  // {
                v := Json jobj
                pos = pos + 1
                skipWs
                if(src at(pos) != 125,
                    more := true
                    while(more,
                        skipWs
                        k := parseStringRaw
                        skipWs
                        pos = pos + 1  // colon
                        v set(k, parseValue)
                        skipWs
                        if(src at(pos) == 44, pos = pos + 1, more = false)
                    )
                )
                pos = pos + 1
                return v
            )
            if(ch == 91,  // [
                v := Json jarr
                pos = pos + 1
                skipWs
                if(src at(pos) != 93,
                    more := true
                    while(more,
                        v items append(parseValue)
                        skipWs
                        if(src at(pos) == 44, pos = pos + 1, more = false)
                    )
                )
                pos = pos + 1
                return v
            )
            if(ch == 34, return Json jstr(parseStringRaw))
            if(ch == 116, pos = pos + 4; return Json jbool(true))   // true
            if(ch == 102, pos = pos + 5; return Json jbool(false)) // false
            if(ch == 110, pos = pos + 4; return Json jnull)        // null
            start := pos
            while(pos < src size and ((src at(pos) >= 48 and src at(pos) <= 57) or src at(pos) == 45 or src at(pos) == 43 or src at(pos) == 46 or src at(pos) == 101 or src at(pos) == 69),
                pos = pos + 1
            )
            v := JVal clone
            v kind = 4
            v sval = src exSlice(start, pos)
            v
        )
    )

    parse := method(text,
        p := parserProto clone
        p src = text
        p pos = 0
        p parseValue
    )
)

// ----------------------------------------------------------------
// byte utilities via the standard CLI tools

Tmp := Object clone do(
    counter := 0
    next := method(tag,
        counter = counter + 1
        "/tmp/tel-io-" .. tag .. "-" .. counter asString
    )
)

writeFileBytes := method(path, data,
    // this Io build has no openForWriting; openForUpdating
    // creates the file if needed (temp names are unique, so
    // the missing truncate is harmless)
    f := File with(path) openForUpdating
    f write(data)
    f close
)

readFileBytes := method(path,
    f := File with(path)
    if(f exists not, return "")
    f openForReading
    data := f readToEnd
    f close
    data
)

sha256hex := method(data,
    fb := Tmp next("sha")
    writeFileBytes(fb, data)
    System system("sha256sum " .. fb .. " > " .. fb .. ".out")
    out := readFileBytes(fb .. ".out")
    System system("rm -f " .. fb .. " " .. fb .. ".out")
    if(out size >= 64, out exSlice(0, 64), "")
)

gzipBytes := method(data,
    fb := Tmp next("gz")
    writeFileBytes(fb, data)
    System system("gzip -c " .. fb .. " > " .. fb .. ".out")
    out := readFileBytes(fb .. ".out")
    System system("rm -f " .. fb .. " " .. fb .. ".out")
    out
)

gunzipBytes := method(data,
    fb := Tmp next("gz")
    writeFileBytes(fb, data)
    System system("gzip -dc " .. fb .. " > " .. fb .. ".out 2>/dev/null")
    out := readFileBytes(fb .. ".out")
    System system("rm -f " .. fb .. " " .. fb .. ".out")
    out
)

b64enc := method(data, data asBase64)
b64dec := method(text, text fromBase64)

// ----------------------------------------------------------------
// game logic (mirrors harness/adapter_base.py)

IMPL := "io"
GNUPG_HOME := "/home/wbic16/telephone-io/gnupg"
INDEX_COORD := list(1, 1, 1, 1, 1, 1, 1, 1, 1)
KEYS_COORD := list(1, 1, 1, 1, 1, 1, 1, 1, 2)
KH_COORD := list(1, 1, 1, 1, 1, 1, 1, 1, 3)
EVENT_PREFIX := list(1, 1, 1, 1, 1, 1, 2, 1)

Cache := Object clone do(
    entries := nil
    valid := false
)

// explode a state into a Map: coordKey -> list(coord, text)
stateMap := method(data,
    m := Map clone
    PhextLib phokenize(data) foreach(e,
        m atPut(PhextLib coordKey(e at(0)), e)
    )
    m
)

mapFetch := method(m, coord,
    e := m at(PhextLib coordKey(coord))
    if(e == nil, "", e at(1))
)

gpgKeygen := method(
    fb := Tmp next("kg")
    System system("GNUPGHOME=" .. GNUPG_HOME .. " gpg --batch --yes --list-keys --with-colons > " .. fb .. " 2>/dev/null")
    keys := readFileBytes(fb)
    if(keys findSeq("pub") == nil,
        System system("GNUPGHOME=" .. GNUPG_HOME .. " gpg --batch --yes --pinentry-mode loopback --passphrase '' --quick-generate-key telephone-io ed25519 sign never 2>/dev/null")
    )
    System system("GNUPGHOME=" .. GNUPG_HOME .. " gpg --batch --yes --armor --export telephone-io > " .. fb .. " 2>/dev/null")
    pub := readFileBytes(fb)
    System system("rm -f " .. fb)
    o := Json jobj
    o set("impl", Json jstr(IMPL))
    o set("pubkey", Json jstr(pub))
    o
)

gpgAttest := method(descriptor,
    fb := Tmp next("at")
    writeFileBytes(fb, descriptor canon)
    System system("GNUPGHOME=" .. GNUPG_HOME .. " gpg --batch --yes --pinentry-mode loopback --passphrase '' --detach-sign --armor -u telephone-io -o " .. fb .. ".sig " .. fb .. " 2>/dev/null")
    sig := readFileBytes(fb .. ".sig")
    System system("rm -f " .. fb .. " " .. fb .. ".sig")
    o := Json jobj
    o set("signature", Json jstr(sig))
    o
)

verifySignature := method(pubkeys, data, sigB64,
    dir := Tmp next("vf")
    home := dir .. "/gnupg"
    System system("mkdir -p " .. home)
    System system("chmod 700 " .. home)
    writeFileBytes(dir .. "/sig.asc", b64dec(sigB64))
    writeFileBytes(dir .. "/data", data)
    writeFileBytes(dir .. "/keys", pubkeys)
    rc := System system("GNUPGHOME=" .. home .. " gpg --batch --yes --import " .. dir .. "/keys 2>/dev/null && GNUPGHOME=" .. home .. " gpg --batch --yes --verify " .. dir .. "/sig.asc " .. dir .. "/data 2>/dev/null")
    System system("rm -rf " .. dir)
    rc == 0
)

doEcho := method(ping,
    inner := Json jobj
    inner set("impl", Json jstr(IMPL))
    inner set("ping", ping)
    o := Json jobj
    o set("impl", Json jstr(IMPL))
    o set("echo", Json jstr(sha256hex(inner canon)))
    o
)

doElect := method(req,
    cands := req get("candidates")
    names := cands items map(v, v sval)
    pool := names select(n, n != IMPL)
    if(pool size == 0, pool = names)
    joined := names join(",")
    seed := sha256hex(IMPL .. "-elect:" .. (req gets("position")) .. ":" .. (req gets("turn")) .. ":" .. joined)
    acc := 0
    for(i, 0, 7,
        h := seed at(i)
        d := 0
        if(h >= 48 and h <= 57, d = h - 48,
            if(h >= 97 and h <= 102, d = h - 87,
                if(h >= 65 and h <= 70, d = h - 55)))
        acc = (acc * 16 + d) % pool size
    )
    o := Json jobj
    o set("elect", Json jstr(pool at(acc)))
    o
)

stateOf := method(req, b64dec(req gets("state")))

doChoose := method(req,
    m := stateMap(stateOf(req))
    pos := PhextLib parseCoord(req gets("position"))
    while(mapFetch(m, pos) != "",
        pos atPut(8, pos at(8) + 1)
    )
    o := Json jobj
    o set("op", Json jstr("insert"))
    o set("coordinate", Json jstr(PhextLib coordString(pos)))
    o set("text", Json jstr(IMPL .. " was here, turn " .. (req gets("turn"))))
    o
)

doApply := method(req,
    data := stateOf(req)
    step := req get("step")
    coord := PhextLib parseCoord(step gets("coordinate"))
    entries := PhextLib phokenize(data)
    key := PhextLib coordKey(coord)
    occupied := entries detect(e, PhextLib coordKey(e at(0)) == key) != nil
    if(occupied,
        o := Json jobj
        o set("error", Json jstr("coordinate already occupied"))
        return o
    )
    entries append(list(coord, step gets("text")))
    out := PhextLib dephokenize(entries)
    o := Json jobj
    o set("state_b64", Json jstr(b64enc(out)))
    o set("state_sha256", Json jstr(sha256hex(out)))
    o
)

doInit := method(req,
    Cache entries = PhextLib phokenize(stateOf(req))
    Cache valid = true
    o := Json jobj
    o set("impl", Json jstr(IMPL))
    o set("verdict", Json jstr("pass"))
    o
)

vfail := method(detail,
    o := Json jobj
    o set("impl", Json jstr(IMPL))
    o set("verdict", Json jstr("fail"))
    o set("detail", Json jstr(detail))
    o
)

rstripNl := method(s,
    n := s size
    while(n > 0 and s at(n - 1) == 10, n = n - 1)
    s exSlice(0, n)
)

doValidate := method(req,
    data := stateOf(req)
    step := req get("step")
    newEntries := PhextLib phokenize(data)
    newMap := Map clone
    newEntries foreach(e, newMap atPut(PhextLib coordKey(e at(0)), e))
    coord := PhextLib parseCoord(step gets("coordinate"))
    ev := PhextLib parseCoord(req gets("event_coord"))
    placed := mapFetch(newMap, coord)
    if(placed != step gets("text"),
        return vfail("placed scroll missing or altered")
    )
    old := Cache entries
    result := nil
    old foreach(e,
        if(result == nil and PhextLib coordCmp(e at(0), INDEX_COORD) != 0,
            if(mapFetch(newMap, e at(0)) != e at(1),
                result = vfail("prior scroll overwritten at " .. PhextLib coordString(e at(0)))
            )
        )
    )
    if(result == nil,
        oldKeys := Map clone
        old foreach(e, oldKeys atPut(PhextLib coordKey(e at(0)), true))
        newEntries foreach(e,
            if(result == nil and oldKeys hasKey(PhextLib coordKey(e at(0))) not,
                if(PhextLib coordCmp(e at(0), coord) != 0 and PhextLib coordCmp(e at(0), ev) != 0,
                    result = vfail("unexpected new scroll at " .. PhextLib coordString(e at(0)))
                )
            )
        )
    )
    if(result == nil,
        idx := rstripNl(mapFetch(newMap, INDEX_COORD))
        line := rstripNl(req gets("index_line"))
        ends := false
        if(line size == 0, ends = true,
            if(line size <= idx size and idx exSlice(idx size - line size, idx size) == line, ends = true))
        if(ends not, result = vfail("index does not record the placement"))
    )
    if(result == nil,
        Cache entries = newEntries
        o := Json jobj
        o set("impl", Json jstr(IMPL))
        o set("verdict", Json jstr("pass"))
        result = o
    )
    result
)

vfailN := method(n, msg,
    ff := Json jobj
    ff set("detail", Json jstr(msg))
    o := Json jobj
    o set("impl", Json jstr(IMPL))
    o set("verdict", Json jstr("fail"))
    o set("placements_checked", Json jnum(n))
    o set("first_failure", ff)
    o
)

doVerify := method(req,
    data := stateOf(req)
    entries := PhextLib phokenize(data)
    m := Map clone
    entries foreach(e, m atPut(PhextLib coordKey(e at(0)), e))
    keysText := mapFetch(m, KEYS_COORD)
    kh := mapFetch(m, KH_COORD) strip
    if(sha256hex(keysText) != kh,
        return vfailN(0, "keys-hash scroll does not match keys")
    )
    placements := Map clone  // coordKey -> text_sha256
    nplaced := 0
    prevHash := nil
    expect := 1
    result := nil
    entries foreach(e,
        if(result != nil, return)
        c := e at(0)
        isEvent := true
        for(d, 0, 7,
            want := if(d == 6, 2, 1)
            if(c at(d) != want, isEvent = false)
        )
        if(isEvent,
            seq := c at(8)
            if(seq != expect,
                result = vfailN(nplaced, "event seq gap at " .. seq asString),
                ev := Json parse(e at(1))
                body := ev get("body")
                prevNode := ev get("prev")
                prevOk := false
                if(prevHash == nil, prevOk = (prevNode != nil and prevNode kind == 0),
                    if(prevNode != nil and prevNode kind == 3, prevOk = (prevNode sval == prevHash)))
                if(prevOk not,
                    result = vfailN(nplaced, "event chain broken at seq " .. seq asString),
                    prevHash = sha256hex(body canon)
                    if(body gets("type") == "placement",
                        cs := body gets("coord")
                        pcoord := PhextLib parseCoord(cs)
                        pkey := PhextLib coordKey(pcoord)
                        if(placements hasKey(pkey),
                            result = vfailN(nplaced, "coordinate reused at seq " .. seq asString),
                            txt := mapFetch(m, pcoord)
                            wantHash := body gets("text_sha256")
                            if(txt size == 0 or sha256hex(txt) != wantHash,
                                result = vfailN(nplaced, "placement scroll hash mismatch seq " .. seq asString),
                                desc := Json jobj
                                desc set("turn", body get("turn"))
                                desc set("coordinate", Json jstr(cs))
                                desc set("scroll_sha256", Json jstr(wantHash))
                                desc set("file_sha256", Json jstr(body gets("file_sha256")))
                                if(verifySignature(keysText, desc canon, body gets("att")) not,
                                    result = vfailN(nplaced, "attestation fails at seq " .. seq asString),
                                    placements atPut(pkey, wantHash)
                                    nplaced = nplaced + 1
                                )
                            )
                        )
                    )
                    expect = expect + 1
                )
            )
        )
    )
    if(result != nil, return result)
    // index cross-check
    idxText := mapFetch(m, INDEX_COORD)
    lines := 0
    idxText split("\n") foreach(ln,
        if(result == nil and ln size > 0 and ln at(0) != 35,
            lines = lines + 1
            parts := ln split(" ")
            if(parts size < 4,
                result = vfailN(nplaced, "index hash mismatch: " .. ln exSlice(0, (ln size) min(40))),
                cs := parts at(1)
                h := parts at(2)
                pcoord := PhextLib parseCoord(cs)
                pv := placements at(PhextLib coordKey(pcoord))
                if(pv == nil or pv != h,
                    result = vfailN(nplaced, "index hash mismatch: " .. ln exSlice(0, (ln size) min(40)))
                )
            )
        )
    )
    if(result != nil, return result)
    if(lines != nplaced, return vfailN(nplaced, "index lines != placements"))
    o := Json jobj
    o set("impl", Json jstr(IMPL))
    o set("verdict", Json jstr("pass"))
    o set("placements_checked", Json jnum(nplaced))
    o set("first_failure", Json jnull)
    o
)

dispatch := method(req,
    cmd := req gets("cmd")
    if(cmd == "id",
        o := Json jobj
        o set("impl", Json jstr(IMPL))
        return o
    )
    if(cmd == "keygen", return gpgKeygen)
    if(cmd == "echo", return doEcho(req get("ping")))
    if(cmd == "elect", return doElect(req))
    if(cmd == "choose", return doChoose(req))
    if(cmd == "apply", return doApply(req))
    if(cmd == "attest", return gpgAttest(req get("descriptor")))
    if(cmd == "init", return doInit(req))
    if(cmd == "validate", return doValidate(req))
    if(cmd == "verify", return doVerify(req))
    o := Json jobj
    o set("error", Json jstr("unknown cmd " .. cmd))
    o
)

handleLine := method(line,
    raw := line
    if(raw size >= 4 and raw exSlice(0, 4) == "GZ1:",
        raw = gunzipBytes(b64dec(raw exSlice(4, raw size)))
    )
    req := Json parse(raw)
    out := dispatch(req) canon
    if(out size > 8192,
        return "GZ1:" .. b64enc(gzipBytes(out))
    )
    out
)

handleLineSafe := method(line,
    // Io try returns nil on success (the Exception on failure);
    // the value is captured by side assignment
    resp := nil
    ex := try(resp = handleLine(line))
    if(ex == nil, resp,
        o := Json jobj
        o set("error", Json jstr("io cli error"))
        o canon
    )
)

// ----------------------------------------------------------------
mode := System args at(1)
if(mode == "serve",
    inp := File standardInput
    out := File standardOutput
    loop(
        line := inp readLine
        if(line == nil, break)
        if(line size > 0,
            out write(handleLineSafe(line) .. "\n")
            out flush
        )
    ),
    // one-shot: a single newline-terminated request line
    inp := File standardInput
    line := inp readLine
    if(line != nil and line size > 0,
        writeln(handleLineSafe(line))
    )
)
