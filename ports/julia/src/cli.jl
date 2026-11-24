# Hub-side CLI for libphext-julia (Exocortical Telephone Game, contract v2).
#
# Transport: with no argument, stdin carries ONE JSON object and stdout
# carries ONE JSON response. With the argument `serve`, the CLI reads
# one JSON request per line and answers one JSON object per line.
# Requests carry phext state as base64 under "state" (v2) or
# "state_b64" (v1 wire compat).
#
# v2 subcommands: id, keygen, seek, echo, elect, choose (insert-only),
# apply, attest, validate, verify (stress.phext walk). v1 `fetch` and
# tar-based `verify` (game_tar_b64) remain for the v1 harness.
#
# choose — this port's own deterministic adventure rule (insert-only):
#   start from the tracked position; while the candidate coordinate
#   already holds a scroll, advance it by one scroll break. Insert
#   "julia was here, turn N" at the first unused coordinate found.
# elect — popcorn: sha256("julia-elect:<position>:<turn>:<candidates>")
#   picks from the candidates other than itself (when there are any).
# echo — sha256 hex of "julia-echo:" + the ping nonce.
# attest — PGP detached armored signature (gpg, key home
#   ~/telephone-julia/keys on the hub) over the canonical descriptor
#   JSON (sorted keys, "," / ":" separators, ASCII-escaped).
# JSON is handled by the small parser/writer below because JSON.jl is
# not a Julia stdlib — this port takes no external package dependencies.
using SHA
using Base64
using Tar

include(joinpath(@__DIR__, "Phext.jl"))
using .Phext
using .Phext: fetch  # explicit: shadows Base.fetch, which `using` skips
using .Phext: replace  # same for Base.replace

const IMPL = "julia"
const ZERO = "0"^64
const KEY_HOME = "/home/wbic16/telephone-julia/keys"

# ------------------------------------------------------------ mini JSON
mutable struct JParser
    s::Vector{Char}
    i::Int
end

function jparse(text::AbstractString)
    p = JParser(collect(text), 0)
    v = jvalue(p)
    jws(p)
    p.i == length(p.s) || error("trailing JSON input")
    v
end

function jws(p::JParser)
    while p.i < length(p.s) && p.s[p.i + 1] in (' ', '\t', '\n', '\r')
        p.i += 1
    end
end

function jpeek(p::JParser)
    jws(p)
    p.s[p.i + 1]
end

function jvalue(p::JParser)
    c = jpeek(p)
    if c == '{'
        p.i += 1
        obj = Dict{String,Any}()
        jpeek(p) == '}' && (p.i += 1; return obj)
        while true
            key = jvalue(p)::String
            jpeek(p) == ':' || error("expected :")
            p.i += 1
            obj[key] = jvalue(p)
            c2 = jpeek(p)
            p.i += 1
            c2 == '}' && break
            c2 == ',' || error("expected , or }")
        end
        obj
    elseif c == '['
        p.i += 1
        arr = Any[]
        jpeek(p) == ']' && (p.i += 1; return arr)
        while true
            push!(arr, jvalue(p))
            c2 = jpeek(p)
            p.i += 1
            c2 == ']' && break
            c2 == ',' || error("expected , or ]")
        end
        arr
    elseif c == '"'
        jstring(p)
    elseif c == 't'
        jlit(p, "true"); true
    elseif c == 'f'
        jlit(p, "false"); false
    elseif c == 'n'
        jlit(p, "null"); nothing
    else
        jnumber(p)
    end
end

function jlit(p::JParser, lit::String)
    for ch in lit
        p.i += 1
        p.s[p.i] == ch || error("bad literal")
    end
end

function jnumber(p::JParser)
    jws(p)
    start = p.i
    while p.i < length(p.s) && p.s[p.i + 1] in "-+0123456789.eE"
        p.i += 1
    end
    tok = join(p.s[(start + 1):p.i])
    if occursin(r"[.eE]", tok)
        parse(Float64, tok)
    else
        parse(Int, tok)
    end
end

function jstring(p::JParser)
    jws(p)
    p.s[p.i + 1] == '"' || error("expected string")
    p.i += 1
    out = Char[]
    while true
        p.i += 1
        ch = p.s[p.i]
        if ch == '"'
            break
        elseif ch == '\\'
            p.i += 1
            esc = p.s[p.i]
            if esc == 'u'
                cp = parse(Int, join(p.s[(p.i + 1):(p.i + 4)]), base = 16)
                p.i += 4
                if 0xD800 <= cp <= 0xDBFF && p.i + 2 <= length(p.s) &&
                   p.s[p.i + 1] == '\\' && p.s[p.i + 2] == 'u'
                    lo = parse(Int, join(p.s[(p.i + 3):(p.i + 6)]), base = 16)
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    p.i += 6
                end
                push!(out, Char(cp))
            elseif esc == 'n'
                push!(out, '\n')
            elseif esc == 't'
                push!(out, '\t')
            elseif esc == 'r'
                push!(out, '\r')
            elseif esc == 'b'
                push!(out, '\b')
            elseif esc == 'f'
                push!(out, '\f')
            else
                push!(out, esc)
            end
        else
            push!(out, ch)
        end
    end
    join(out)
end

function jwrite(io::IO, v)
    if v === nothing
        print(io, "null")
    elseif v isa Bool
        print(io, v ? "true" : "false")
    elseif v isa Integer
        print(io, v)
    elseif v isa AbstractFloat
        print(io, v)
    elseif v isa AbstractString
        jwritestr(io, v)
    elseif v isa AbstractVector
        print(io, "[")
        for (i, x) in enumerate(v)
            i > 1 && print(io, ",")
            jwrite(io, x)
        end
        print(io, "]")
    elseif v isa AbstractDict
        print(io, "{")
        for (i, (k, x)) in enumerate(v)
            i > 1 && print(io, ",")
            jwritestr(io, string(k))
            print(io, ":")
            jwrite(io, x)
        end
        print(io, "}")
    else
        error("cannot write JSON for $(typeof(v))")
    end
end

function jwritestr(io::IO, s::AbstractString)
    print(io, '"')
    for ch in s
        if ch == '"'
            print(io, "\\\"")
        elseif ch == '\\'
            print(io, "\\\\")
        elseif ch == '\n'
            print(io, "\\n")
        elseif ch == '\r'
            print(io, "\\r")
        elseif ch == '\t'
            print(io, "\\t")
        elseif Int(ch) < 0x20
            print(io, "\\u", lpad(string(Int(ch), base = 16), 4, '0'))
        else
            print(io, ch)
        end
    end
    print(io, '"')
end

jstr(v) = sprint(jwrite, v)

# Canonical JSON matching python json.dumps(sort_keys, separators,
# ensure_ascii=True), for hash chains and attested descriptors.
function canon(v)
    io = IOBuffer()
    canon_write(io, v)
    String(take!(io))
end

function canon_write(io::IO, v)
    if v === nothing
        print(io, "null")
    elseif v isa Bool
        print(io, v ? "true" : "false")
    elseif v isa Integer
        print(io, v)
    elseif v isa AbstractFloat
        v == trunc(v) ? print(io, Int(v)) : print(io, v)
    elseif v isa AbstractString
        canon_str(io, v)
    elseif v isa AbstractVector
        print(io, "[")
        for (i, x) in enumerate(v)
            i > 1 && print(io, ",")
            canon_write(io, x)
        end
        print(io, "]")
    elseif v isa AbstractDict
        print(io, "{")
        for (i, k) in enumerate(sort(collect(keys(v))))
            i > 1 && print(io, ",")
            canon_str(io, string(k))
            print(io, ":")
            canon_write(io, v[k])
        end
        print(io, "}")
    else
        error("cannot canonicalize $(typeof(v))")
    end
end

function canon_str(io::IO, s::AbstractString)
    print(io, '"')
    for ch in s
        cp = Int(ch)
        if ch == '"'
            print(io, "\\\"")
        elseif ch == '\\'
            print(io, "\\\\")
        elseif ch == '\n'
            print(io, "\\n")
        elseif ch == '\r'
            print(io, "\\r")
        elseif ch == '\t'
            print(io, "\\t")
        elseif cp == 0x08
            print(io, "\\b")
        elseif cp == 0x0c
            print(io, "\\f")
        elseif 0x20 <= cp < 0x7f
            print(io, ch)
        elseif cp <= 0xffff
            print(io, "\\u", lpad(string(cp, base = 16), 4, '0'))
        else
            x = cp - 0x10000
            print(io, "\\u", string(0xd800 + (x >> 10), base = 16))
            print(io, "\\u", string(0xdc00 + (x & 0x3ff), base = 16))
        end
    end
    print(io, '"')
end

sha256hex(b) = bytes2hex(sha256(b))
hexdecode(s::AbstractString) =
    [parse(UInt8, s[(2i - 1):(2i)], base = 16) for i in 1:(length(s) ÷ 2)]
state_of(req) = base64decode(get(req, "state", get(req, "state_b64", "")))

# ------------------------------------------------------------ gpg
function gpg_run(args::Vector{String}; home::String = KEY_HOME)
    mkpath(home)
    cmd = setenv(`gpg $args`, "GNUPGHOME" => home)
    io = IOBuffer()
    ok = try
        run(pipeline(cmd, stdout = io, stderr = devnull))
        true
    catch
        false
    end
    (ok, String(take!(io)))
end

function ensure_key()
    ok, listing = gpg_run(["--batch", "--list-keys", "--with-colons"])
    if !ok || !occursin("pub:", listing)
        ok, _ = gpg_run(["--batch", "--pinentry-mode", "loopback",
                         "--passphrase", "", "--quick-generate-key",
                         "libphext-julia <julia@telephone.exocortex>",
                         "ed25519", "sign", "never"])
        ok || error("keygen failed")
    end
    ok, pubkey = gpg_run(["--batch", "--armor", "--export", "libphext-julia"])
    ok || error("pubkey export failed")
    strip(pubkey)
end

function sign_descriptor(descriptor)
    ensure_key()
    dir = mktempdir()
    try
        data = joinpath(dir, "descriptor.json")
        write(data, canon(descriptor))
        sig = joinpath(dir, "descriptor.sig")
        ok, _ = gpg_run(["--batch", "--yes", "--pinentry-mode", "loopback",
                         "--passphrase", "", "--detach-sign", "--armor",
                         "--output", sig, data])
        ok || error("attest signing failed")
        strip(read(sig, String))
    finally
        rm(dir, recursive = true, force = true)
    end
end

function verify_signature(pubkeys::String, signature::String, data::Vector{UInt8})
    dir = mktempdir()
    try
        home = joinpath(dir, "gnupg")
        mkpath(home)
        chmod(home, 0o700)
        keyfile = joinpath(dir, "keys.asc")
        write(keyfile, pubkeys)
        ok, _ = gpg_run(["--batch", "--import", keyfile], home = home)
        ok || return false
        datafile = joinpath(dir, "data")
        write(datafile, data)
        sigfile = joinpath(dir, "data.sig")
        write(sigfile, signature)
        ok, _ = gpg_run(["--batch", "--verify", sigfile, datafile], home = home)
        ok
    finally
        rm(dir, recursive = true, force = true)
    end
end

# ------------------------------------------------------------ seek
# Raw file I/O only: in-process directory walk + byte reads; the break
# walker runs in-process. No subprocesses, no search tools, no indexes.
function seek(root::String)
    target = ntuple(_ -> 13, 9)
    isdir(root) || return nothing
    files = String[]
    for name in sort(readdir(root))
        path = joinpath(root, name)
        isfile(path) && endswith(name, ".phext") && push!(files, path)
    end
    for (dir, _dirs, names) in walkdir(root)
        for name in sort(names)
            path = joinpath(dir, name)
            endswith(name, ".phext") && !(path in files) && push!(files, path)
        end
    end
    for path in files
        data = read(path)
        coord = ones(Int, 9)
        run_start = 1 # 1-based byte index of the current run start
        for i in eachindex(data)
            d = get(Phext.BREAK_DIM, data[i], 0)
            if d != 0
                if Tuple(coord) == target && i > run_start
                    text = String(data[run_start:(i - 1)])
                    title = strip(split(text, '\n')[1])
                    return Dict("impl" => IMPL, "path" => path,
                                "offset" => run_start - 1,
                                "coordinate" => "13.13.13/13.13.13/13.13.13",
                                "title" => title)
                end
                coord[d] += 1
                for lower in (d + 1):9
                    coord[lower] = 1
                end
                run_start = i + 1
            end
        end
        if Tuple(coord) == target && length(data) >= run_start
            text = String(data[run_start:end])
            title = strip(split(text, '\n')[1])
            return Dict("impl" => IMPL, "path" => path,
                        "offset" => run_start - 1,
                        "coordinate" => "13.13.13/13.13.13/13.13.13",
                        "title" => title)
        end
    end
    nothing
end

# ------------------------------------------------------------ game logic
function apply_step(data::Vector{UInt8}, step)
    op = step["op"]
    coord = Coordinate(step["coordinate"]::String)
    fetch_sha = op == "fetch" ? sha256hex(fetch(data, coord)) : nothing
    (op == "fetch" || op == "navigate") && return (data, fetch_sha)
    map = explode(data)
    if op == "insert"
        map[coord] = vcat(get(map, coord, UInt8[]),
                          text_to_bytes(step["text"]::String))
    elseif op == "replace"
        map[coord] = text_to_bytes(step["text"]::String)
    elseif op == "remove"
        delete!(map, coord)
    else
        error("unknown op $op")
    end
    (implode(map), fetch_sha)
end

fail(n, msg) = Dict{String,Any}("impl" => IMPL, "verdict" => "fail",
                                "steps_checked" => n,
                                "first_failure" => Dict("detail" => msg))

function verify_tar(tar_bytes::Vector{UInt8})
    dir = mktempdir()
    try
        Tar.extract(IOBuffer(tar_bytes), dir)
        tpath = ""
        gpath = ""
        for (root, _dirs, files) in walkdir(dir)
            "transcript.jsonl" in files && (tpath = joinpath(root, "transcript.jsonl"))
            "genesis.phext" in files && (gpath = joinpath(root, "genesis.phext"))
        end
        (isempty(tpath) || isempty(gpath)) &&
            return fail(0, "missing transcript/genesis")
        records = [jparse(line) for line in split(read(tpath, String), '\n')
                   if !isempty(strip(line))]
        isempty(records) && return fail(0, "empty transcript")
        head = ZERO
        for rec in records
            rec["prev"] == head || return fail(0, "chain prev mismatch")
            body = Dict(k => v for (k, v) in rec if k ∉ ("prev", "hash"))
            digest = sha256hex(vcat(hexdecode(head), codeunits(canon(body))))
            digest == rec["hash"] || return fail(0, "chain hash mismatch")
            head = rec["hash"]
        end
        state = read(gpath)
        sha256hex(state) == records[1]["genesis_sha256"] ||
            return fail(0, "genesis hash mismatch")
        pings = Dict(r["turn"] => r["nonce"] for r in records
                     if r["type"] == "ping")
        echoes = Dict{Any,Vector{Any}}()
        checked = 0
        for rec in records
            if rec["type"] == "echo"
                if rec["impl"] == IMPL
                    want = sha256hex(codeunits("julia-echo:" * pings[rec["turn"]]))
                    want == rec["echo"] || return fail(
                        checked, "own echo mismatch turn $(rec["turn"])")
                end
                push!(get!(echoes, rec["turn"], Any[]), rec)
            elseif rec["type"] == "handoff"
                es = get(echoes, rec["turn"], Any[])
                isempty(es) && return fail(checked, "handoff with no echoes")
                best = argmin(e -> (e["echo"], e["impl"]), es)
                best["impl"] == rec["to"] || return fail(
                    checked, "echolocation outcome mismatch turn $(rec["turn"])")
            elseif rec["type"] == "turn"
                step = rec["step"]
                if step["op"] == "fetch"
                    got = sha256hex(fetch(state, Coordinate(step["coordinate"])))
                    got == rec["fetch_sha256"] || return fail(
                        checked, "fetch mismatch turn $(rec["turn"])")
                end
                state, _ = apply_step(state, step)
                sha256hex(state) == rec["state_sha256"] || return fail(
                    checked, "state mismatch turn $(rec["turn"])")
                checked += 1
            end
        end
        Dict{String,Any}("impl" => IMPL, "verdict" => "pass",
                         "steps_checked" => checked, "first_failure" => nothing)
    finally
        rm(dir, recursive = true, force = true)
    end
end

# ------------------------------------------------------------ v2 verify
vfail(n, msg) = Dict{String,Any}("impl" => IMPL, "verdict" => "fail",
                                 "placements_checked" => n,
                                 "first_failure" => Dict("detail" => msg))

is_reserved(c::Coordinate) = c.v[1:7] == (1, 1, 1, 1, 1, 1, 1) && c.v[8] == 1 && c.v[9] <= 3
is_event(c::Coordinate) = c.v[1:6] == (1, 1, 1, 1, 1, 1) && c.v[7] == 2 && c.v[8] == 1

function verify_stress(data::Vector{UInt8}, pubkeys_arg)
    map = explode(data)
    keys_coord = Coordinate("1.1.1/1.1.1/1.1.2")
    hash_coord = Coordinate("1.1.1/1.1.1/1.1.3")
    index_coord = Coordinate("1.1.1/1.1.1/1.1.1")
    pubkeys = pubkeys_arg === nothing ? "" : pubkeys_arg
    if haskey(map, keys_coord)
        inscribed = bytes_to_text(map[keys_coord])
        isempty(pubkeys) && (pubkeys = inscribed)
        if haskey(map, hash_coord)
            want = strip(bytes_to_text(map[hash_coord]))
            sha256hex(map[keys_coord]) == want ||
                return vfail(0, "keys-hash scroll does not match keys scroll")
        end
    end
    index = Dict{String,String}()
    if haskey(map, index_coord)
        text = strip(bytes_to_text(map[index_coord]))
        if !isempty(text)
            if startswith(text, "{")
                for (k, v) in jparse(text)
                    index[k] = v
                end
            else
                for line in split(text, '\n')
                    parts = split(strip(line))
                    length(parts) == 2 && (index[parts[1]] = parts[2])
                end
            end
        end
    end
    event_coords = sort([c for c in keys(map) if is_event(c)])
    head = ZERO
    attested = Set{String}()
    checked = 0
    for ec in event_coords
        ev = try
            jparse(bytes_to_text(map[ec]))
        catch
            return vfail(checked, "event at $ec is not JSON")
        end
        ev["prev"] == head ||
            return vfail(checked, "event chain prev mismatch at $ec")
        body = Dict(k => v for (k, v) in ev if k ∉ ("prev", "hash"))
        digest = sha256hex(vcat(hexdecode(head), codeunits(canon(body))))
        digest == ev["hash"] ||
            return vfail(checked, "event chain hash mismatch at $ec")
        head = ev["hash"]
        if ev["type"] == "placement"
            desc = ev["descriptor"]
            coord_str = desc["coordinate"]
            coord = Coordinate(coord_str)
            haskey(map, coord) ||
                return vfail(checked, "placement scroll missing at $coord_str")
            sha256hex(map[coord]) == desc["scroll_sha256"] ||
                return vfail(checked, "placement scroll hash mismatch at $coord_str")
            get(index, coord_str, "") == desc["scroll_sha256"] ||
                return vfail(checked, "index hash mismatch at $coord_str")
            sig = get(ev, "signature", "")
            if isempty(pubkeys) ||
               !verify_signature(pubkeys, sig, codeunits(canon(desc)))
                return vfail(checked, "attestation signature fails at $coord_str")
            end
            push!(attested, coord_str)
            checked += 1
        end
    end
    for (coord, text) in map
        (is_reserved(coord) || is_event(coord)) && continue
        coord_str = string(coord)
        get(index, coord_str, "") == sha256hex(text) ||
            return vfail(checked, "unindexed placement at $coord_str")
        coord_str in attested ||
            return vfail(checked, "unattested placement at $coord_str")
    end
    length(index) == length(attested) ||
        return vfail(checked, "index/attestation count mismatch")
    Dict{String,Any}("impl" => IMPL, "verdict" => "pass",
                     "placements_checked" => checked, "first_failure" => nothing)
end

# ------------------------------------------------------------ dispatch
function dispatch(req)
    cmd = req["cmd"]
    if cmd == "id"
        Dict("impl" => IMPL)
    elseif cmd == "keygen"
        Dict("impl" => IMPL, "pubkey" => ensure_key())
    elseif cmd == "seek"
        found = seek(get(req, "root", ""))
        found === nothing ? Dict("impl" => IMPL, "error" => "not found") : found
    elseif cmd == "echo"
        ping = get(req, "ping", req)
        Dict("impl" => IMPL,
             "echo" => sha256hex(codeunits("julia-echo:" * ping["nonce"])))
    elseif cmd == "elect"
        candidates = [string(c) for c in req["candidates"]]
        pool = filter(c -> c != IMPL, candidates)
        isempty(pool) && (pool = candidates)
        seed = sha256hex(codeunits(
            "julia-elect:" * string(req["position"]) * ":" *
            string(req["turn"]) * ":" * join(candidates, ",")))
        idx = parse(Int, seed[1:8], base = 16) % length(pool) + 1
        Dict("elect" => pool[idx])
    elseif cmd == "choose"
        data = state_of(req)
        turn = req["turn"]
        map = explode(data)
        candidate = Coordinate(req["position"]::String)
        while haskey(map, candidate)
            candidate = Phext.apply_break(candidate, 9)
        end
        Dict("op" => "insert", "coordinate" => string(candidate),
             "text" => "julia was here, turn $turn")
    elseif cmd == "apply"
        data = state_of(req)
        out, _ = apply_step(data, req["step"])
        Dict("state_b64" => base64encode(out),
             "state_sha256" => sha256hex(out))
    elseif cmd == "attest"
        Dict("signature" => sign_descriptor(req["descriptor"]))
    elseif cmd == "validate"
        data = state_of(req)
        step = req["step"]
        coord = Coordinate(step["coordinate"]::String)
        map = explode(data)
        if !haskey(map, coord)
            Dict("impl" => IMPL, "verdict" => "fail",
                 "detail" => "placed scroll missing at $coord")
        else
            placed = map[coord]
            desc = get(req, "descriptor", nothing)
            detail = ""
            if desc !== nothing && sha256hex(placed) != desc["scroll_sha256"]
                detail = "placed scroll hash != attested scroll_sha256"
            elseif haskey(step, "text") &&
                   bytes_to_text(placed) != step["text"]
                detail = "placed scroll text != step text"
            elseif haskey(req, "prior_state")
                prior_bytes = base64decode(req["prior_state"])
                if desc !== nothing &&
                   sha256hex(prior_bytes) != desc["prior_file_sha256"]
                    detail = "prior file hash != attested prior_file_sha256"
                else
                    prior = explode(prior_bytes)
                    for (k, v) in prior
                        if !haskey(map, k) || map[k] != v
                            detail = "prior scroll overwritten or lost at $k"
                            break
                        end
                    end
                    if isempty(detail)
                        added = [k for k in keys(map) if !haskey(prior, k)]
                        if length(added) != 1 || added[1] != coord
                            detail = "expected exactly one added scroll at $coord"
                        end
                    end
                end
            end
            if isempty(detail)
                Dict("impl" => IMPL, "verdict" => "pass",
                     "detail" => "placed scroll present at unused coordinate; no prior scroll overwritten")
            else
                Dict("impl" => IMPL, "verdict" => "fail", "detail" => detail)
            end
        end
    elseif cmd == "verify"
        if haskey(req, "game_tar_b64")
            verify_tar(base64decode(req["game_tar_b64"]))
        else
            verify_stress(state_of(req), get(req, "pubkeys", nothing))
        end
    elseif cmd == "fetch"
        data = state_of(req)
        got = fetch(data, Coordinate(req["coordinate"]::String))
        Dict("text_b64" => base64encode(got), "text" => bytes_to_text(got))
    elseif cmd == "explode"
        # Hook for harness/adapter_base.py: coordinate string -> text_b64.
        map = explode(state_of(req))
        Dict("map" => Dict(string(k) => base64encode(v) for (k, v) in map))
    elseif cmd == "implode"
        map = Dict(Coordinate(k) => base64decode(v)
                   for (k, v) in req["map"])
        out = implode(map)
        Dict("state_b64" => base64encode(out),
             "state_sha256" => sha256hex(out))
    elseif cmd == "insert"
        # Game insert (adapter_base hook semantics): unused coord only.
        data = state_of(req)
        coord = Coordinate(req["coordinate"]::String)
        map = explode(data)
        if haskey(map, coord)
            Dict("error" => "coordinate already occupied")
        else
            map[coord] = base64decode(req["text_b64"])
            out = implode(map)
            Dict("state_b64" => base64encode(out),
                 "state_sha256" => sha256hex(out))
        end
    else
        error("unknown cmd $cmd")
    end
end

function main()
    if !isempty(ARGS) && ARGS[1] == "serve"
        for line in eachline(stdin)
            t = strip(line)
            isempty(t) && continue
            resp = try
                dispatch(jparse(t))
            catch e
                Dict("error" => sprint(showerror, e))
            end
            println(jstr(resp))
            flush(stdout)
        end
        return
    end
    req = jparse(read(stdin, String))
    println(jstr(dispatch(req)))
end

main()
