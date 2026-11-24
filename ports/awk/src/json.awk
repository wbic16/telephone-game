# json.awk -- minimal JSON parser + canonical serializer in pure gawk.
# Canonical form matches the harness's canon (Python json.dumps with
# sort_keys=True, separators=(",",":"), ensure_ascii=True): compact,
# keys sorted, non-ASCII escaped as \uXXXX. Number literals are kept
# verbatim from the source text so float formatting round-trips
# exactly.
#
# Values live on a node heap: node id -> NT[id] type
# ("str","num","bool","null","arr","obj"), NS[id] scalar payload,
# NC[id] child count, NCH[id SUBSEP k] child node id (arr/obj),
# NK[id SUBSEP k] key (obj). json_parse(text) returns the root id.

function json_parse(text,    root) {
    JS = text; JI = 1; JN = length(text); JNEXT = 0
    root = _jvalue()
    _jws()
    if (JI <= JN) {
        JERR = "trailing data after JSON value"
        return 0
    }
    return root
}

function _jws(    ch) {
    while (JI <= JN) {
        ch = substr(JS, JI, 1)
        if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r") JI++
        else break
    }
}

function _jnew(type,    id) {
    JNEXT++
    NT[JNEXT] = type
    return JNEXT
}

function _jvalue(    ch, id, start, rest) {
    _jws()
    ch = substr(JS, JI, 1)
    if (ch == "{") return _jobject()
    if (ch == "[") return _jarray()
    if (ch == "\"") {
        id = _jnew("str")
        NS[id] = _jstring()
        return id
    }
    if (ch == "t") { JI += 4; id = _jnew("bool"); NS[id] = 1; return id }
    if (ch == "f") { JI += 5; id = _jnew("bool"); NS[id] = 0; return id }
    if (ch == "n") { JI += 4; id = _jnew("null"); NS[id] = ""; return id }
    start = JI
    rest = substr(JS, JI)
    if (match(rest, /^[-+0-9.eE]+/)) {
        JI += RLENGTH
        id = _jnew("num")
        NS[id] = substr(JS, start, RLENGTH)
        return id
    }
    JERR = "bad JSON value at " JI
    return _jnew("null")
}

function _jstring(    out, ch, e, hex, code, hex2, lo, rest, chunk) {
    JI++  # opening quote
    out = ""
    while (JI <= JN) {
        rest = substr(JS, JI)
        if (match(rest, /["\\]/)) {
            chunk = substr(rest, 1, RSTART - 1)
            out = out chunk
            JI += RSTART - 1
            ch = substr(JS, JI, 1)
            if (ch == "\"") {
                JI++
                return out
            }
            # backslash escape
            JI++
            e = substr(JS, JI, 1)
            if (e == "\"") out = out "\""
            else if (e == "\\") out = out "\\"
            else if (e == "/") out = out "/"
            else if (e == "b") out = out "\b"
            else if (e == "f") out = out "\f"
            else if (e == "n") out = out "\n"
            else if (e == "r") out = out "\r"
            else if (e == "t") out = out "\t"
            else if (e == "u") {
                hex = substr(JS, JI + 1, 4)
                code = strtonum("0x" hex)
                JI += 4
                if (code >= 55296 && code <= 56319 && substr(JS, JI + 1, 2) == "\\u") {
                    hex2 = substr(JS, JI + 3, 4)
                    lo = strtonum("0x" hex2)
                    if (lo >= 56320 && lo <= 57343) {
                        code = 65536 + (code - 55296) * 1024 + (lo - 56320)
                        JI += 6
                    }
                }
                out = out _codepoint_char(code)
            } else {
                JERR = "bad escape \\" e
            }
            JI++
            continue
        } else {
            out = out rest
            JI = JN + 1
        }
    }
    JERR = "unterminated string"
    return out
}

function _codepoint_char(code,    b1, b2, b3, b4) {
    # Encode a codepoint as UTF-8 bytes (JSON strings on the wire are
    # UTF-8; scroll text handled by this CLI is ASCII in practice).
    if (code < 128) return sprintf("%c", code)
    if (code < 2048) {
        b1 = sprintf("%c", 192 + int(code / 64))
        b2 = sprintf("%c", 128 + (code % 64))
        return b1 b2
    }
    if (code < 65536) {
        b1 = sprintf("%c", 224 + int(code / 4096))
        b2 = sprintf("%c", 128 + (int(code / 64) % 64))
        b3 = sprintf("%c", 128 + (code % 64))
        return b1 b2 b3
    }
    b1 = sprintf("%c", 240 + int(code / 262144))
    b2 = sprintf("%c", 128 + (int(code / 4096) % 64))
    b3 = sprintf("%c", 128 + (int(code / 64) % 64))
    b4 = sprintf("%c", 128 + (code % 64))
    return b1 b2 b3 b4
}

function _jobject(    id, k, v, ch) {
    JI++  # {
    id = _jnew("obj")
    NC[id] = 0
    _jws()
    if (substr(JS, JI, 1) == "}") { JI++; return id }
    while (1) {
        _jws()
        k = _jstring()
        _jws()
        JI++  # :
        v = _jvalue()
        NC[id]++
        NK[id, NC[id]] = k
        NCH[id, NC[id]] = v
        _jws()
        ch = substr(JS, JI, 1)
        JI++
        if (ch == "}") break
        if (ch != ",") { JERR = "expected comma or end of object"; break }
    }
    return id
}

function _jarray(    id, v, ch) {
    JI++  # [
    id = _jnew("arr")
    NC[id] = 0
    _jws()
    if (substr(JS, JI, 1) == "]") { JI++; return id }
    while (1) {
        v = _jvalue()
        NC[id]++
        NCH[id, NC[id]] = v
        _jws()
        ch = substr(JS, JI, 1)
        JI++
        if (ch == "]") break
        if (ch != ",") { JERR = "expected comma or end of array"; break }
    }
    return id
}

# ---- accessors / constructors ----
function jget(id, key,    i) {
    if (NT[id] != "obj") return 0
    for (i = 1; i <= NC[id]; i++) {
        if (NK[id, i] == key) return NCH[id, i]
    }
    return 0
}
function jhas(id, key) { return jget(id, key) != 0 }
function jstr_new(s,    id) { id = _jnew("str"); NS[id] = s; return id }
function jnum_new(n,    id) { id = _jnew("num"); NS[id] = n; return id }
function jnull_new(    id) { id = _jnew("null"); NS[id] = ""; return id }
function jbool_new(b,    id) { id = _jnew("bool"); NS[id] = b ? 1 : 0; return id }
function jarr_new(    id) { id = _jnew("arr"); NC[id] = 0; return id }
function jobj_new(    id) { id = _jnew("obj"); NC[id] = 0; return id }
function jarr_push(id, child) { NC[id]++; NCH[id, NC[id]] = child }
function jobj_set(id, key, child) {
    NC[id]++
    NK[id, NC[id]] = key
    NCH[id, NC[id]] = child
}

# ---- canonical serializer ----
function json_canon(id,    out, i, keys, nk, tmp, j) {
    if (NT[id] == "null") return "null"
    if (NT[id] == "bool") return NS[id] ? "true" : "false"
    if (NT[id] == "num") return NS[id]
    if (NT[id] == "str") return _canon_str(NS[id])
    if (NT[id] == "arr") {
        out = "["
        for (i = 1; i <= NC[id]; i++) {
            out = out (i > 1 ? "," : "") json_canon(NCH[id, i])
        }
        return out "]"
    }
    if (NT[id] == "obj") {
        nk = 0
        for (i = 1; i <= NC[id]; i++) { nk++; keys[nk] = NK[id, i] }
        # insertion sort of keys (byte order)
        for (i = 2; i <= nk; i++) {
            tmp = keys[i]; j = i - 1
            while (j >= 1 && keys[j] > tmp) { keys[j + 1] = keys[j]; j-- }
            keys[j + 1] = tmp
        }
        out = "{"
        for (i = 1; i <= nk; i++) {
            out = out (i > 1 ? "," : "") _canon_str(keys[i]) ":" json_canon(jget(id, keys[i]))
        }
        return out "}"
    }
    return "null"
}

function _canon_str(s,    out, i, ch, code, hi, lo, rest, chunk) {
    out = "\""
    i = 1
    while (i <= length(s)) {
        rest = substr(s, i)
        if (match(rest, /["\\]/)) {
            chunk = substr(rest, 1, RSTART - 1)
            # escape control / non-ASCII chars inside the chunk
            out = out _escape_run(chunk)
            i += RSTART - 1
            ch = substr(s, i, 1)
            out = out (ch == "\"" ? "\\\"" : "\\\\")
            i++
            continue
        }
        out = out _escape_run(rest)
        i = length(s) + 1
    }
    return out "\""
}

function _escape_run(s,    out, i, b, ch) {
    # Escape one run of ordinary (non-quote, non-backslash) chars the
    # Python ensure_ascii way. Bytes are chars under LC_ALL=C; game
    # strings are ASCII, where byte-wise \uXXXX escaping is exactly
    # Python's codepoint-wise form.
    out = ""
    for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        b = _byte_value(ch)
        if (b == 8) out = out "\\b"
        else if (b == 9) out = out "\\t"
        else if (b == 10) out = out "\\n"
        else if (b == 12) out = out "\\f"
        else if (b == 13) out = out "\\r"
        else if (b < 32 || b > 126) out = out sprintf("\\u%04x", b)
        else out = out ch
    }
    return out
}

function _byte_value(ch,    i) {
    # Bytes are single chars under LC_ALL=C; build the value table once.
    if (!BV_READY) {
        for (i = 1; i < 256; i++) BV[sprintf("%c", i)] = i
        BV_READY = 1
    }
    return (ch in BV) ? BV[ch] : 63
}
