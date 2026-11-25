# telephone.awk -- Exocortical Telephone Game CLI (contract v2) for
# the gawk libphext port. Wire protocol: one JSON request in, one JSON
# response out; with the argument "serve" it loops over JSON lines.
# Commands: id, echo, elect, choose, apply, keygen, attest, validate
# (both the prior_state form and the driver's init/event_coord/
# index_line form), init, verify. All phext operations use this port's
# own phext.awk; JSON uses this port's own json.awk. PGP via subprocess
# gpg (key home $TELEPHONE_GNUPGHOME or ~/telephone-awk/gnupg; private
# keys never leave it). sha256 via subprocess sha256sum; base64 is
# implemented in awk below.

BEGIN {
    IMPL = "awk"
    INDEX_CS = "1.1.1/1.1.1/1.1.1"
    KEYS_CS = "1.1.1/1.1.1/1.1.2"
    KH_CS = "1.1.1/1.1.1/1.1.3"
    KEY_UID = "libphext telephone awk"
    if ("TELEPHONE_GNUPGHOME" in ENVIRON && ENVIRON["TELEPHONE_GNUPGHOME"] != "") {
        GNUPG_HOME = ENVIRON["TELEPHONE_GNUPGHOME"]
    } else {
        GNUPG_HOME = ENVIRON["HOME"] "/telephone-awk/gnupg"
    }
    system("mkdir -p '" GNUPG_HOME "' && chmod 700 '" GNUPG_HOME "'")
    ENVIRON["GNUPGHOME"] = GNUPG_HOME
    TMPBASE = "/tmp/telephone-awk-" PROCINFO["pid"]
    B64A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    CACHE_SET = 0

    serve = (ARGC > 1 && ARGV[1] == "serve")
    ARGV[1] = ""  # do not treat as an input file
    if (serve) {
        while ((getline line) > 0) {
            if (line ~ /^[ \t]*$/) continue
            if (substr(line, 1, 4) == "GZ1:") line = gz_unframe(substr(line, 5))
            resp = handle(line)
            if (length(resp) > 8192) resp = gz_frame(resp)
            print resp
            fflush()
        }
    } else {
        if ((getline line) > 0) {
            resp = handle(line)
            print resp
            fflush()
        }
    }
    exit
}

# ------------------------------------------------------------ utilities
# Game-scale framing (2026-11-24): lines over 8 KB may arrive
# gzip-framed as "GZ1:" + base64(gzip(line)) -- the fleet-ssh channel
# is ~25-70 KB/s and raw base64 state lines took minutes at 1,000
# placements. gawk has no gzip, so (de)framing shells to the system
# base64(1)/gzip(1) on temp files (mirrors the lua/fortran ports).
# Lossless; plain lines unchanged. Framed payloads are single-line
# JSON (no raw newlines), so one getline reads a whole frame.
function gz_unframe(payload,    fb, fo, line) {
    fb = TMPBASE "-gz.b64"
    fo = TMPBASE "-gz.out"
    write_file(fb, payload)
    system("base64 -d '" fb "' | gzip -dc > '" fo "'")
    line = ""
    if ((getline line < fo) <= 0) line = ""
    close(fo)
    system("rm -f '" fb "' '" fo "'")
    return line
}
function gz_frame(data,    fi, fb, line) {
    fi = TMPBASE "-gz.in"
    fb = TMPBASE "-gz.b64"
    write_file(fi, data)
    system("gzip -c '" fi "' | base64 -w0 > '" fb "'")
    line = ""
    if ((getline line < fb) <= 0) line = ""
    close(fb)
    system("rm -f '" fi "' '" fb "'")
    return "GZ1:" line
}
function write_file(path, data) {
    printf "%s", data > path
    close(path)
}
function read_text_file(path,    content, line, first) {
    content = ""
    first = 1
    while ((getline line < path) > 0) {
        content = content (first ? "" : "\n") line
        first = 0
    }
    close(path)
    if (!first) content = content "\n"
    return content
}
function sha256hex(data,    tmp, cmd, line, parts) {
    tmp = TMPBASE "-sha"
    write_file(tmp, data)
    cmd = "sha256sum '" tmp "'"
    cmd | getline line
    close(cmd)
    split(line, parts, " ")
    system("rm -f '" tmp "'")
    return parts[1]
}
function b64encode(data,    out, i, n, b1, b2, b3, c) {
    out = ""
    n = length(data)
    for (i = 1; i <= n; i += 3) {
        b1 = _byte_value(substr(data, i, 1))
        b2 = (i + 1 <= n) ? _byte_value(substr(data, i + 1, 1)) : 0
        b3 = (i + 2 <= n) ? _byte_value(substr(data, i + 2, 1)) : 0
        out = out substr(B64A, int(b1 / 4) + 1, 1)
        out = out substr(B64A, (b1 % 4) * 16 + int(b2 / 16) + 1, 1)
        out = out ((i + 1 <= n) ? substr(B64A, (b2 % 16) * 4 + int(b3 / 64) + 1, 1) : "=")
        out = out ((i + 2 <= n) ? substr(B64A, b3 % 64 + 1, 1) : "=")
    }
    return out
}
function b64decode(s,    out, i, n, v1, v2, v3, v4, clean) {
    gsub(/[ \t\r\n]/, "", s)
    out = ""
    n = length(s)
    for (i = 1; i <= n; i += 4) {
        v1 = index(B64A, substr(s, i, 1)) - 1
        v2 = index(B64A, substr(s, i + 1, 1)) - 1
        v3 = (substr(s, i + 2, 1) == "=") ? -1 : index(B64A, substr(s, i + 2, 1)) - 1
        v4 = (substr(s, i + 3, 1) == "=") ? -1 : index(B64A, substr(s, i + 3, 1)) - 1
        out = out sprintf("%c", v1 * 4 + int(v2 / 16))
        if (v3 >= 0) out = out sprintf("%c", (v2 % 16) * 16 + int(v3 / 4))
        if (v4 >= 0) out = out sprintf("%c", (v3 % 4) * 64 + v4)
    }
    return out
}
function trim(s) {
    gsub(/^[ \t\r\n]+/, "", s)
    gsub(/[ \t\r\n]+$/, "", s)
    return s
}
function trim_nl(s) {
    sub(/\n$/, "", s)
    return s
}

# ------------------------------------------------------------ gpg
function gpg_prefix() {
    return "gpg --batch --yes --pinentry-mode loopback --passphrase '' "
}
function do_keygen(    cmd, line, found, pub, resp) {
    cmd = gpg_prefix() "--list-keys --with-colons"
    found = 0
    while ((cmd | getline line) > 0) {
        if (line ~ /^pub:/) found = 1
    }
    close(cmd)
    if (!found) {
        system(gpg_prefix() "--quick-generate-key '" KEY_UID "' ed25519 sign never")
    }
    cmd = gpg_prefix() "--armor --export '" KEY_UID "'"
    pub = ""
    while ((cmd | getline line) > 0) pub = pub line "\n"
    close(cmd)
    resp = jobj_new()
    jobj_set(resp, "impl", jstr_new(IMPL))
    jobj_set(resp, "pubkey", jstr_new(pub))
    return resp
}
function detach_sign(data,    plain, sigf, out) {
    plain = TMPBASE "-desc"
    sigf = TMPBASE "-desc.asc"
    write_file(plain, data)
    system(gpg_prefix() "--detach-sign --armor --local-user '" KEY_UID "' --output '" sigf "' '" plain "'")
    out = read_text_file(sigf)
    system("rm -f '" plain "' '" sigf "'")
    return out
}
function verify_signature(pubkeys, data, signature,    dir, home, kf, pf, sf, rc) {
    dir = TMPBASE "-verify"
    home = dir "/gnupg"
    system("rm -rf '" dir "' && mkdir -p '" home "' && chmod 700 '" home "'")
    kf = dir "/keys.asc"; pf = dir "/data"; sf = dir "/sig.asc"
    write_file(kf, pubkeys)
    write_file(pf, data)
    write_file(sf, signature)
    rc = system("gpg --batch --yes --homedir '" home "' --import '" kf "' 2>/dev/null")
    if (rc == 0) {
        rc = system("gpg --batch --yes --homedir '" home "' --verify '" sf "' '" pf "' 2>/dev/null")
    }
    system("rm -rf '" dir "'")
    return rc == 0
}

# ------------------------------------------------------------ game logic
function echo_value(ping,    game, round, nonce, g, r, nn) {
    game = ""; round = ""; nonce = ""
    g = jget(ping, "game"); if (g) game = NS[g]
    r = jget(ping, "round")
    if (r) round = NS[r]
    else { r = jget(ping, "turn"); if (r) round = NS[r] }
    nn = jget(ping, "nonce"); if (nn) nonce = NS[nn]
    return sha256hex(IMPL "|" game "|" round "|" nonce)
}
function elect_winner(position, cand_node, turn,    n, i, joined, hex, b0, resp) {
    n = NC[cand_node]
    joined = ""
    for (i = 1; i <= n; i++) {
        joined = joined (i > 1 ? "," : "") NS[NCH[cand_node, i]]
    }
    hex = sha256hex(position sprintf("%c", turn % 256) joined)
    b0 = strtonum("0x" substr(hex, 1, 2))
    resp = jobj_new()
    jobj_set(resp, "elect", jstr_new(NS[NCH[cand_node, (b0 % n) + 1]]))
    return resp
}
function wrap999(v) { return (v - 1) % 999 + 1 }
function next_coord_str(cs,    a, d) {
    split(cs, a, ",")
    for (d = 9; d >= 1; d--) {
        if (a[d] < 999) { a[d]++; break }
        a[d] = 1
    }
    return a[1] "," a[2] "," a[3] "," a[4] "," a[5] "," a[6] "," a[7] "," a[8] "," a[9]
}
function choose_adventure(state, position, turn,    pos, hex, b1, b2, dim, cand, cs, resp, a) {
    explode(state)
    # EXPL is keyed by string coords; work in that space
    pos = coord_parse(position)
    split(pos, a, ",")
    hex = sha256hex(position sprintf("%c", turn % 256) state)
    b1 = strtonum("0x" substr(hex, 3, 2))
    b2 = strtonum("0x" substr(hex, 5, 2))
    dim = (b1 % 9) + 1
    a[dim] = wrap999(a[dim] + 1 + (b2 % 3))
    cand = a[1] "," a[2] "," a[3] "," a[4] "," a[5] "," a[6] "," a[7] "," a[8] "," a[9]
    cs = coord_str(cand)
    while ((cs in EXPL) || cs == INDEX_CS || cs == KEYS_CS || cs == KH_CS) {
        cand = next_coord_str(cand)
        cs = coord_str(cand)
    }
    resp = jobj_new()
    jobj_set(resp, "op", jstr_new("insert"))
    jobj_set(resp, "coordinate", jstr_new(cs))
    jobj_set(resp, "text", jstr_new(IMPL " turn " turn " at " cs))
    return resp
}
function apply_step(state, step,    op, cs, coord, text, newstate, resp, fh) {
    op = NS[jget(step, "op")]
    cs = NS[jget(step, "coordinate")]
    coord = coord_parse(cs)
    text = jget(step, "text") ? NS[jget(step, "text")] : ""
    fh = ""
    if (op == "insert") newstate = insert(state, coord, text)
    else if (op == "replace") newstate = replace(state, coord, text)
    else if (op == "remove") newstate = remove(state, coord)
    else if (op == "fetch") { newstate = state; fh = sha256hex(fetch(state, coord)) }
    else newstate = state
    resp = jobj_new()
    jobj_set(resp, "state_b64", jstr_new(b64encode(newstate)))
    jobj_set(resp, "state_sha256", jstr_new(sha256hex(newstate)))
    if (fh != "") jobj_set(resp, "fetch_sha256", jstr_new(fh))
    else jobj_set(resp, "fetch_sha256", jnull_new())
    APPLY_STATE = newstate
    return resp
}
function vfail(detail,    resp) {
    resp = jobj_new()
    jobj_set(resp, "impl", jstr_new(IMPL))
    jobj_set(resp, "verdict", jstr_new("fail"))
    jobj_set(resp, "detail", jstr_new(detail))
    return resp
}
function vpass(detail,    resp) {
    resp = jobj_new()
    jobj_set(resp, "impl", jstr_new(IMPL))
    jobj_set(resp, "verdict", jstr_new("pass"))
    if (detail != "") jobj_set(resp, "detail", jstr_new(detail))
    return resp
}
function do_validate(req, state,    step, op, prior_node, prior, cs, coord, text, cnt, k) {
    step = jget(req, "step")
    op = NS[jget(step, "op")]
    cs = NS[jget(step, "coordinate")]
    coord = coord_parse(cs)
    text = jget(step, "text") ? NS[jget(step, "text")] : ""
    prior_node = jget(req, "prior_state")
    if (prior_node) {
        if (op != "insert") return vfail("step op is not insert")
        if (fetch(state, coord) != text) {
            return vfail("placed scroll absent or content differs at " cs)
        }
        prior = b64decode(NS[prior_node])
        if (fetch(prior, coord) != "") {
            return vfail("coordinate was not unused in the prior state")
        }
        explode(prior)
        for (k in EXPL) BEFORE[k] = EXPL[k]
        explode(state)
        cnt = 0
        for (k in EXPL) cnt++
        bcnt = 0
        for (k in BEFORE) bcnt++
        if (cnt != bcnt + 1) return vfail("scroll count did not grow by exactly one")
        for (k in BEFORE) {
            if (!(k in EXPL) || EXPL[k] != BEFORE[k]) {
                return vfail("a prior scroll was overwritten: " k)
            }
        }
        delete BEFORE
        return vpass("placed at unused coordinate; all prior scrolls intact")
    }
    # driver form: cached prior map + event_coord + index_line
    if (!CACHE_SET) return vfail("validate called before init")
    explode(state)
    for (k in EXPL) NEW[k] = EXPL[k]
    if (!(cs in NEW) || NEW[cs] != text) {
        delete NEW
        return vfail("placed scroll missing or altered")
    }
    for (k in CACHE) {
        if (k == INDEX_CS) continue
        if (!(k in NEW) || NEW[k] != CACHE[k]) {
            delete NEW
            return vfail("prior scroll overwritten at " k)
        }
    }
    ev = NS[jget(req, "event_coord")]
    for (k in NEW) {
        if (!(k in CACHE) && k != cs && k != ev) {
            delete NEW
            return vfail("unexpected new scroll at " k)
        }
    }
    idx = (INDEX_CS in NEW) ? NEW[INDEX_CS] : ""
    line = NS[jget(req, "index_line")]
    if (substr(trim_nl(idx), length(trim_nl(idx)) - length(trim_nl(line)) + 1) != trim_nl(line)) {
        delete NEW
        return vfail("index does not record the placement")
    }
    delete CACHE
    for (k in NEW) CACHE[k] = NEW[k]
    delete NEW
    return vpass("")
}
function verify_fail(n, msg,    resp, ff) {
    resp = jobj_new()
    jobj_set(resp, "impl", jstr_new(IMPL))
    jobj_set(resp, "verdict", jstr_new("fail"))
    jobj_set(resp, "placements_checked", jnum_new(n))
    ff = jobj_new()
    jobj_set(ff, "detail", jstr_new(msg))
    jobj_set(resp, "first_failure", ff)
    return resp
}
function do_verify(state, pubkeys,    keys_text, idx, lines, i, fields, seq, ev, body, prev_hash, checked, cs, th, fh, ab, turn_raw, actor, desc, k, resp) {
    explode(state)
    for (k in EXPL) SC[k] = EXPL[k]
    if (!(KEYS_CS in SC) || SC[KEYS_CS] == "") {
        delete SC
        return verify_fail(0, "no public-keys scroll at 1.1.1/1.1.1/1.1.2")
    }
    keys_text = SC[KEYS_CS]
    if (trim(pubkeys) != trim(keys_text)) {
        delete SC
        return verify_fail(0, "supplied pubkeys do not match the inscribed keys scroll")
    }
    if (!(KH_CS in SC)) {
        delete SC
        return verify_fail(0, "no keys-hash scroll at 1.1.1/1.1.1/1.1.3")
    }
    if (trim(SC[KH_CS]) != sha256hex(keys_text)) {
        delete SC
        return verify_fail(0, "keys-hash scroll does not match the keys scroll")
    }
    delete IDX
    if (INDEX_CS in SC) {
        split(SC[INDEX_CS], lines, "\n")
        for (i in lines) {
            if (lines[i] == "" || lines[i] ~ /^#/) continue
            split(trim(lines[i]), fields, /[ \t]+/)
            if (length(fields) != 4) {
                delete SC
                return verify_fail(0, "malformed index line: " lines[i])
            }
            IDX[fields[2]] = fields[1] SUBSEP fields[3] SUBSEP fields[4]
        }
    }
    checked = 0
    prev_hash = ""
    delete SEEN
    for (seq = 1; ; seq++) {
        evcs = "1.1.1/1.1.1/2.1." seq
        if (!(evcs in SC)) break
        ev = json_parse(SC[evcs])
        if (!ev || !jhas(ev, "body")) {
            delete SC
            return verify_fail(checked, "event " seq " lacks a body object")
        }
        body = jget(ev, "body")
        if (seq == 1) {
            if (NT[jget(ev, "prev")] != "null") {
                delete SC
                return verify_fail(checked, "event 1 prev is not null")
            }
        } else {
            if (NS[jget(ev, "prev")] != prev_hash) {
                delete SC
                return verify_fail(checked, "event chain broken at seq " seq)
            }
        }
        prev_hash = sha256hex(json_canon(body))
        if (!jhas(body, "type") || NS[jget(body, "type")] != "placement") continue
        cs = NS[jget(body, "coord")]
        th = NS[jget(body, "text_sha256")]
        fh = NS[jget(body, "file_sha256")]
        ab = NS[jget(body, "att")]
        turn_raw = NS[jget(body, "turn")]
        actor = NS[jget(body, "actor")]
        if (cs == "" || th == "" || fh == "" || ab == "") {
            delete SC
            return verify_fail(checked, "event " seq " lacks coord/text_sha256/file_sha256/att")
        }
        if (cs in SEEN) {
            delete SC
            return verify_fail(checked, "coordinate reused at " cs)
        }
        if (!(cs in SC)) {
            delete SC
            return verify_fail(checked, "placement missing at " cs)
        }
        if (sha256hex(SC[cs]) != th) {
            delete SC
            return verify_fail(checked, "placement hash mismatch at " cs)
        }
        if (!(cs in IDX)) {
            delete SC
            return verify_fail(checked, "index mismatch at " cs)
        }
        split(IDX[cs], fields, SUBSEP)
        if (fields[2] != th || fields[1] != turn_raw || fields[3] != actor) {
            delete SC
            return verify_fail(checked, "index mismatch at " cs)
        }
        desc = jobj_new()
        jobj_set(desc, "turn", jget(body, "turn"))
        jobj_set(desc, "coordinate", jstr_new(cs))
        jobj_set(desc, "scroll_sha256", jstr_new(th))
        jobj_set(desc, "file_sha256", jstr_new(fh))
        if (!verify_signature(pubkeys, json_canon(desc), b64decode(ab))) {
            delete SC
            return verify_fail(checked, "event " seq " signature: gpg verify failed")
        }
        SEEN[cs] = 1
        checked++
    }
    if (checked == 0) {
        delete SC
        return verify_fail(0, "no placement events found")
    }
    for (k in IDX) {
        if (!(k in SEEN)) {
            delete SC
            return verify_fail(checked, "index lists a placement with no event: " k)
        }
    }
    delete SC
    resp = jobj_new()
    jobj_set(resp, "impl", jstr_new(IMPL))
    jobj_set(resp, "verdict", jstr_new("pass"))
    jobj_set(resp, "placements_checked", jnum_new(checked))
    jobj_set(resp, "first_failure", jnull_new())
    return resp
}
function req_state(req,    s) {
    s = jget(req, "state")
    if (s) return b64decode(NS[s])
    s = jget(req, "state_b64")
    if (s) return b64decode(NS[s])
    return ""
}
function handle(line,    req, cmd, resp, ping, pos, turn, step, desc) {
    req = json_parse(line)
    if (!req) {
        resp = jobj_new()
        jobj_set(resp, "error", jstr_new("JSON parse error: " JERR))
        return json_canon(resp)
    }
    cmd = NS[jget(req, "cmd")]
    if (cmd == "id") {
        resp = jobj_new(); jobj_set(resp, "impl", jstr_new(IMPL))
        return json_canon(resp)
    }
    if (cmd == "echo") {
        resp = jobj_new()
        jobj_set(resp, "impl", jstr_new(IMPL))
        jobj_set(resp, "echo", jstr_new(echo_value(jget(req, "ping"))))
        return json_canon(resp)
    }
    if (cmd == "elect") {
        turn = NS[jget(req, "turn")] + 0
        return json_canon(elect_winner(NS[jget(req, "position")], jget(req, "candidates"), turn))
    }
    if (cmd == "choose") {
        turn = NS[jget(req, "turn")] + 0
        return json_canon(choose_adventure(req_state(req), NS[jget(req, "position")], turn))
    }
    if (cmd == "apply") {
        return json_canon(apply_step(req_state(req), jget(req, "step")))
    }
    if (cmd == "keygen") {
        return json_canon(do_keygen())
    }
    if (cmd == "attest") {
        resp = jobj_new()
        jobj_set(resp, "signature", jstr_new(detach_sign(json_canon(jget(req, "descriptor")))))
        return json_canon(resp)
    }
    if (cmd == "init") {
        explode(req_state(req))
        delete CACHE
        for (k in EXPL) CACHE[k] = EXPL[k]
        CACHE_SET = 1
        resp = jobj_new()
        jobj_set(resp, "impl", jstr_new(IMPL))
        jobj_set(resp, "verdict", jstr_new("pass"))
        return json_canon(resp)
    }
    if (cmd == "validate") {
        return json_canon(do_validate(req, req_state(req)))
    }
    if (cmd == "verify") {
        return json_canon(do_verify(req_state(req), NS[jget(req, "pubkeys")]))
    }
    resp = jobj_new()
    jobj_set(resp, "error", jstr_new("unknown cmd " cmd))
    return json_canon(resp)
}
