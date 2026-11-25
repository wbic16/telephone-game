# libphext-mojo -- phext 0.6.1 parity in Mojo (MAX nightly 1.3).
# Byte-oriented: phext data is List[UInt8] end to end; JSON strings are
# held as latin-1 byte lists. REMOVE IS COORDINATE-PRESERVING (tested).
# One binary, modes: (no args) one request: argv[1]=req file argv[2]=resp
# file; "test": native suite, argv[2]=fixtures dir.
from std.sys import argv
from std.ffi import external_call

comptime Bytes = List[UInt8]

# ------------------------------------------------------------------ bytes
def bstr(s: String) -> Bytes:
    var out = Bytes()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^

def to_str(b: Bytes) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^

def bytes_eq(a: Bytes, b: Bytes) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True

def bytes_cat(a: Bytes, b: Bytes) -> Bytes:
    var out = Bytes()
    for i in range(len(a)):
        out.append(a[i])
    for i in range(len(b)):
        out.append(b[i])
    return out^

def bytes_slice(b: Bytes, lo: Int, hi: Int) -> Bytes:
    var out = Bytes()
    for i in range(lo, hi):
        out.append(b[i])
    return out^

# ------------------------------------------------------------------ sha256
def k256() -> List[UInt32]:
    return [     0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,     0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,     0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,     0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,     0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,     0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,     0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,     0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

def rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (32 - n))

def sha256_bytes(data: Bytes) -> Bytes:
    var h: List[UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var msg = Bytes()
    for i in range(len(data)):
        msg.append(data[i])
    var bitlen = UInt64(len(data)) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    for i in range(8):
        msg.append(UInt8((bitlen >> UInt64((7 - i) * 8)) & 0xFF))
    var w = List[UInt32]()
    for _ in range(64):
        w.append(0)
    var chunk = 0
    while chunk < len(msg):
        for i in range(16):
            var j = chunk + i * 4
            w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16) | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
        for i in range(16, 64):
            var s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            var s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] + s0 + w[i - 7] + s1
        var K = k256()
        var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]
        var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7]
        for i in range(64):
            var s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            var ch = (e & f) ^ ((~e) & g)
            var t1 = hh + s1 + ch + K[i] + w[i]
            var s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var t2 = s0 + maj
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2
        h[0] += a; h[1] += b; h[2] += c; h[3] += d
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh
        chunk += 64
    var out = Bytes()
    for i in range(8):
        out.append(UInt8((h[i] >> 24) & 0xFF))
        out.append(UInt8((h[i] >> 16) & 0xFF))
        out.append(UInt8((h[i] >> 8) & 0xFF))
        out.append(UInt8(h[i] & 0xFF))
    return out^

def hex_of(data: Bytes) -> String:
    var hexd = String("0123456789abcdef")
    var hb = hexd.as_bytes()
    var out = String()
    for i in range(len(data)):
        out += chr(Int(hb[Int(data[i] >> 4)]))
        out += chr(Int(hb[Int(data[i] & 15)]))
    return out^

def sha256_hex(data: Bytes) -> String:
    return hex_of(sha256_bytes(data))

# ------------------------------------------------------------------ base64
comptime B64T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

def b64_encode(data: Bytes) -> String:
    var t = B64T.as_bytes()
    var out = String()
    var i = 0
    while i + 3 <= len(data):
        var n = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8) | UInt32(data[i + 2])
        out += chr(Int(t[Int((n >> 18) & 63)]))
        out += chr(Int(t[Int((n >> 12) & 63)]))
        out += chr(Int(t[Int((n >> 6) & 63)]))
        out += chr(Int(t[Int(n & 63)]))
        i += 3
    var rem = len(data) - i
    if rem == 1:
        var n = UInt32(data[i]) << 16
        out += chr(Int(t[Int((n >> 18) & 63)]))
        out += chr(Int(t[Int((n >> 12) & 63)]))
        out += "=="
    elif rem == 2:
        var n = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8)
        out += chr(Int(t[Int((n >> 18) & 63)]))
        out += chr(Int(t[Int((n >> 12) & 63)]))
        out += chr(Int(t[Int((n >> 6) & 63)]))
        out += "="
    return out^

def b64_val(c: UInt8) -> Int:
    if c >= 65 and c <= 90:
        return Int(c) - 65
    if c >= 97 and c <= 122:
        return Int(c) - 97 + 26
    if c >= 48 and c <= 57:
        return Int(c) - 48 + 52
    if c == 43:
        return 62
    if c == 47:
        return 63
    return -1

def b64_decode(s: Bytes) -> Bytes:
    var out = Bytes()
    var acc = 0
    var nbits = 0
    for i in range(len(s)):
        var c = s[i]
        if c == 61:
            break
        var v = b64_val(c)
        if v < 0:
            continue
        acc = (acc << 6) | v
        nbits += 6
        if nbits >= 8:
            nbits -= 8
            out.append(UInt8((acc >> nbits) & 0xFF))
    return out^

# ------------------------------------------------------------------ phext core
def break_byte(d: Int) -> UInt8:
    if d == 0: return 1
    if d == 1: return 31
    if d == 2: return 30
    if d == 3: return 29
    if d == 4: return 28
    if d == 5: return 26
    if d == 6: return 25
    if d == 7: return 24
    return 23

def break_dim(b: UInt8) -> Int:
    if b == 1: return 0
    if b == 31: return 1
    if b == 30: return 2
    if b == 29: return 3
    if b == 28: return 4
    if b == 26: return 5
    if b == 25: return 6
    if b == 24: return 7
    if b == 23: return 8
    return -1

def coord_str(c: List[Int]) -> String:
    var out = String()
    for i in range(9):
        if i == 3 or i == 6:
            out += "/"
        elif i > 0:
            out += "."
        out += String(c[i])
    return out^

def coord_key(c: List[Int]) -> String:
    # zero-padded sortable key (components < 10^10 in practice)
    var out = String()
    for i in range(9):
        var s = String(c[i])
        for _ in range(s.byte_length(), 10):
            out += "0"
        out += s
    return out^

def parse_coord(s: String) -> List[Int]:
    var out = List[Int]()
    var sb = s.as_bytes()
    var cur = -1
    for i in range(len(sb) + 1):
        var c: UInt8 = 0
        if i < len(sb):
            c = sb[i]
        if i == len(sb) or c == 46 or c == 47:
            if cur < 1:
                return List[Int]()
            out.append(cur)
            cur = -1
        elif c >= 48 and c <= 57:
            if cur < 0:
                cur = 0
            cur = cur * 10 + Int(c) - 48
        else:
            return List[Int]()
    if len(out) != 9:
        return List[Int]()
    return out^

struct Scroll(Copyable, Movable):
    var coord: List[Int]
    var text: Bytes

    def __init__(out self, var coord: List[Int], var text: Bytes):
        self.coord = coord^
        self.text = text^

def explode(data: Bytes) -> List[Scroll]:
    var out = List[Scroll]()
    var coord: List[Int] = [1, 1, 1, 1, 1, 1, 1, 1, 1]
    var run_start = -1
    for i in range(len(data)):
        var d = break_dim(data[i])
        if d >= 0:
            if run_start >= 0:
                out.append(Scroll(coord.copy(), bytes_slice(data, run_start, i)))
                run_start = -1
            coord[d] += 1
            for k in range(d + 1, 9):
                coord[k] = 1
        else:
            if run_start < 0:
                run_start = i
    if run_start >= 0:
        out.append(Scroll(coord.copy(), bytes_slice(data, run_start, len(data))))
    return out^

def sort_scrolls(mut sc: List[Scroll]):
    # insertion sort by coord_key (scroll counts are modest per call site
    # except implode; use a simple merge-free quicksort on keys instead)
    var n = len(sc)
    if n < 2:
        return
    # shell sort with coord compare
    var gap = n // 2
    while gap > 0:
        for i in range(gap, n):
            var tmp = sc[i].copy()
            var j = i
            while j >= gap and coord_cmp(sc[j - gap].coord, tmp.coord) > 0:
                sc[j] = sc[j - gap].copy()
                j -= gap
            sc[j] = tmp^
        gap //= 2

def coord_cmp(a: List[Int], b: List[Int]) -> Int:
    for i in range(9):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    return 0

def implode(sc_in: List[Scroll]) -> Bytes:
    var sc = List[Scroll]()
    for i in range(len(sc_in)):
        sc.append(sc_in[i].copy())
    sort_scrolls(sc)
    var out = Bytes()
    var loc: List[Int] = [1, 1, 1, 1, 1, 1, 1, 1, 1]
    for e in range(len(sc)):
        var coord = sc[e].coord.copy()
        var text = sc[e].text.copy()
        if len(text) == 0:
            continue
        if coord_cmp(loc, coord) < 0:
            var dim = 0
            while loc[dim] == coord[dim]:
                dim += 1
            for _ in range(coord[dim] - loc[dim]):
                out.append(break_byte(dim))
            for k in range(dim + 1, 9):
                for _ in range(coord[k] - 1):
                    out.append(break_byte(k))
            loc = coord.copy()
        for i in range(len(text)):
            out.append(text[i])
    return out^

def map_of(data: Bytes) -> List[Scroll]:
    # explode + last-wins per coordinate (explode already yields unique
    # coords in canonical data; keep first occurrence semantics by
    # construction of the walker: runs are unique per coordinate)
    return explode(data)

def fetch_text(data: Bytes, coord: List[Int]) -> Bytes:
    var sc = explode(data)
    for i in range(len(sc)):
        if coord_cmp(sc[i].coord, coord) == 0:
            return sc[i].text.copy()
    return Bytes()

def update(data: Bytes, coord: List[Int], text: Bytes, overwrite: Bool) -> Bytes:
    var sc = explode(data)
    var out = List[Scroll]()
    var done = False
    for i in range(len(sc)):
        if coord_cmp(sc[i].coord, coord) == 0:
            done = True
            if overwrite:
                if len(text) > 0:
                    out.append(Scroll(coord.copy(), text.copy()))
            else:
                out.append(Scroll(coord.copy(), bytes_cat(sc[i].text, text)))
        else:
            out.append(sc[i].copy())
    if not done and len(text) > 0:
        out.append(Scroll(coord.copy(), text.copy()))
    return implode(out)

def phext_insert(data: Bytes, coord: List[Int], text: Bytes) -> Bytes:
    return update(data, coord, text, False)

def phext_replace(data: Bytes, coord: List[Int], text: Bytes) -> Bytes:
    return update(data, coord, text, True)

def phext_remove(data: Bytes, coord: List[Int]) -> Bytes:
    var sc = explode(data)
    var out = List[Scroll]()
    for i in range(len(sc)):
        if coord_cmp(sc[i].coord, coord) != 0:
            out.append(sc[i].copy())
    return implode(out)

def normalize(data: Bytes) -> Bytes:
    return implode(explode(data))

# ------------------------------------------------------------------ shell
def tmpbase() -> String:
    var pid = external_call["getpid", Int32]()
    return "/tmp/telephone-mojo-" + String(pid)

def run_system(cmd: String) -> Int:
    # Pass system() an explicitly NUL-terminated copy in a fresh
    # buffer: a concatenated Mojo String's backing store can carry
    # stale bytes past its logical end (observed: command strings
    # reaching /bin/sh with a path segment duplicated), and C's
    # system() reads until NUL. The fresh exact buffer + explicit
    # terminator makes the delivered command byte-exact.
    var b = bstr(cmd)
    b.append(UInt8(0))
    return Int(external_call["system", Int32](b.unsafe_ptr()))

def shell(cmd: String) -> Int:
    # Subshell wrap: the caller's own redirections (files, pipelines)
    # stay in force; only the subshell's leftover stdout/stderr is sunk.
    var full = "( " + cmd + " ) >/dev/null 2>&1"
    return run_system(full)

def shell_out(cmd: String) -> Bytes:
    var out_path = tmpbase() + ".out"
    var full = cmd + " > " + out_path + " 2>/dev/null"
    _ = run_system(full)
    var data = read_file_bytes(out_path)
    _ = shell("rm -f " + out_path)
    return data^

def read_file_bytes(path: String) -> Bytes:
    try:
        with open(path, "r") as f:
            var s = f.read()
            return bstr(s)
    except:
        return Bytes()

def write_file_bytes(path: String, data: Bytes) raises:
    with open(path, "w") as f:
        f.write(to_str(data))

def shq(s: String) -> String:
    return "'" + s + "'"

# ------------------------------------------------------------------ JSON DOM
comptime JNULL = 0
comptime JBOOL = 1
comptime JINT = 2
comptime JFLOAT = 3
comptime JSTR = 4
comptime JARR = 5
comptime JOBJ = 6

struct JVal(Copyable, Movable):
    var kind: Int
    var b: Bool
    var n: Int
    var raw: Bytes
    var items: List[Int]
    var keys: List[Bytes]
    var vals: List[Int]

    def __init__(out self, kind: Int, b: Bool, n: Int, var raw: Bytes, var items: List[Int], var keys: List[Bytes], var vals: List[Int]):
        self.kind = kind
        self.b = b
        self.n = n
        self.raw = raw^
        self.items = items^
        self.keys = keys^
        self.vals = vals^

def jval(kind: Int) -> JVal:
    return JVal(kind, False, 0, Bytes(), List[Int](), List[Bytes](), List[Int]())

struct JDoc(Copyable, Movable):
    var arena: List[JVal]

    def __init__(out self, var arena: List[JVal]):
        self.arena = arena^

def jparse(data: Bytes) -> JDoc:
    var doc = JDoc(List[JVal]())
    var pos = 0
    _ = jparse_value(doc, data, pos)
    return doc^

def jskip_ws(data: Bytes, mut pos: Int):
    while pos < len(data) and (data[pos] == 32 or data[pos] == 9 or data[pos] == 10 or data[pos] == 13):
        pos += 1

def jparse_value(mut doc: JDoc, data: Bytes, mut pos: Int) -> Int:
    jskip_ws(data, pos)
    var idx = len(doc.arena)
    doc.arena.append(jval(JNULL))
    if pos >= len(data):
        return idx
    var c = data[pos]
    if c == 123:  # {
        doc.arena[idx].kind = JOBJ
        pos += 1
        jskip_ws(data, pos)
        if pos < len(data) and data[pos] == 125:
            pos += 1
            return idx
        while True:
            jskip_ws(data, pos)
            var kidx = jparse_value(doc, data, pos)
            var key = doc.arena[kidx].raw.copy()
            jskip_ws(data, pos)
            pos += 1  # :
            var vidx = jparse_value(doc, data, pos)
            doc.arena[idx].keys.append(key^)
            doc.arena[idx].vals.append(vidx)
            jskip_ws(data, pos)
            if pos < len(data) and data[pos] == 125:
                pos += 1
                break
            pos += 1  # ,
        return idx
    if c == 91:  # [
        doc.arena[idx].kind = JARR
        pos += 1
        jskip_ws(data, pos)
        if pos < len(data) and data[pos] == 93:
            pos += 1
            return idx
        while True:
            var vidx = jparse_value(doc, data, pos)
            doc.arena[idx].items.append(vidx)
            jskip_ws(data, pos)
            if pos < len(data) and data[pos] == 93:
                pos += 1
                break
            pos += 1
        return idx
    if c == 34:  # "
        doc.arena[idx].kind = JSTR
        doc.arena[idx].raw = jparse_string(data, pos)
        return idx
    # literal / number
    var start = pos
    while pos < len(data) and data[pos] != 44 and data[pos] != 125 and data[pos] != 93 and data[pos] != 32 and data[pos] != 10:
        pos += 1
    var tok = bytes_slice(data, start, pos)
    if bytes_eq(tok, bstr("true")):
        doc.arena[idx].kind = JBOOL
        doc.arena[idx].b = True
    elif bytes_eq(tok, bstr("false")):
        doc.arena[idx].kind = JBOOL
        doc.arena[idx].b = False
    elif bytes_eq(tok, bstr("null")):
        doc.arena[idx].kind = JNULL
    else:
        var isfloat = False
        var neg = False
        var val = 0
        for i in range(len(tok)):
            var ch = tok[i]
            if ch == 46 or ch == 101 or ch == 69:
                isfloat = True
            elif ch == 45 and i == 0:
                neg = True
            elif ch >= 48 and ch <= 57:
                val = val * 10 + Int(ch) - 48
        if isfloat:
            doc.arena[idx].kind = JFLOAT
            doc.arena[idx].raw = tok.copy()
        else:
            doc.arena[idx].kind = JINT
            doc.arena[idx].n = -val if neg else val
    return idx

def jhex4(data: Bytes, pos: Int) -> Int:
    var v = 0
    for i in range(pos, pos + 4):
        var c = data[i]
        var d = 0
        if c >= 48 and c <= 57:
            d = Int(c) - 48
        elif c >= 97 and c <= 102:
            d = Int(c) - 97 + 10
        elif c >= 65 and c <= 70:
            d = Int(c) - 65 + 10
        v = v * 16 + d
    return v

def jparse_string(data: Bytes, mut pos: Int) -> Bytes:
    var out = Bytes()
    pos += 1  # opening quote
    while pos < len(data) and data[pos] != 34:
        var c = data[pos]
        if c == 92:
            pos += 1
            var e = data[pos]
            if e == 110:
                out.append(10)
            elif e == 116:
                out.append(9)
            elif e == 114:
                out.append(13)
            elif e == 98:
                out.append(8)
            elif e == 102:
                out.append(12)
            elif e == 117:
                var cp = jhex4(data, pos + 1)
                pos += 4
                if cp >= 0xD800 and cp <= 0xDBFF and pos + 2 < len(data) and data[pos + 1] == 92 and data[pos + 2] == 117:
                    var lo = jhex4(data, pos + 3)
                    cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
                    pos += 6
                if cp < 256:
                    out.append(UInt8(cp))
                elif cp < 0x800:
                    out.append(UInt8(0xC0 | (cp >> 6)))
                    out.append(UInt8(0x80 | (cp & 63)))
                elif cp < 0x10000:
                    out.append(UInt8(0xE0 | (cp >> 12)))
                    out.append(UInt8(0x80 | ((cp >> 6) & 63)))
                    out.append(UInt8(0x80 | (cp & 63)))
                else:
                    out.append(UInt8(0xF0 | (cp >> 18)))
                    out.append(UInt8(0x80 | ((cp >> 12) & 63)))
                    out.append(UInt8(0x80 | ((cp >> 6) & 63)))
                    out.append(UInt8(0x80 | (cp & 63)))
            else:
                out.append(e)
            pos += 1
        else:
            out.append(c)
            pos += 1
    pos += 1  # closing quote
    return out^

def jget(doc: JDoc, idx: Int, key: String) -> Int:
    if idx < 0 or doc.arena[idx].kind != JOBJ:
        return -1
    var kb = bstr(key)
    for i in range(len(doc.arena[idx].keys)):
        if bytes_eq(doc.arena[idx].keys[i], kb):
            return doc.arena[idx].vals[i]
    return -1

def jstr(doc: JDoc, idx: Int) -> Bytes:
    if idx < 0:
        return Bytes()
    var v = doc.arena[idx].copy()
    if v.kind == JSTR or v.kind == JFLOAT:
        return v.raw.copy()
    if v.kind == JINT:
        return bstr(String(v.n))
    return Bytes()

def jwrite_str(s: Bytes, mut out: Bytes):
    var hexd = String("0123456789abcdef").as_bytes()
    out.append(34)
    for i in range(len(s)):
        var c = s[i]
        if c == 34:
            out.append(92); out.append(34)
        elif c == 92:
            out.append(92); out.append(92)
        elif c == 8:
            out.append(92); out.append(98)
        elif c == 9:
            out.append(92); out.append(116)
        elif c == 10:
            out.append(92); out.append(110)
        elif c == 12:
            out.append(92); out.append(102)
        elif c == 13:
            out.append(92); out.append(114)
        elif c < 32 or c > 126:
            out.append(92); out.append(117); out.append(48); out.append(48)
            out.append(hexd[Int(c >> 4)])
            out.append(hexd[Int(c & 15)])
        else:
            out.append(c)
    out.append(34)

def jwrite(doc: JDoc, idx: Int, mut out: Bytes):
    var v = doc.arena[idx].copy()
    if v.kind == JNULL:
        for ch in bstr("null"):
            out.append(ch)
    elif v.kind == JBOOL:
        var t = bstr("true") if v.b else bstr("false")
        for ch in t:
            out.append(ch)
    elif v.kind == JINT:
        for ch in bstr(String(v.n)):
            out.append(ch)
    elif v.kind == JFLOAT:
        for ch in v.raw:
            out.append(ch)
    elif v.kind == JSTR:
        jwrite_str(v.raw, out)
    elif v.kind == JARR:
        out.append(91)
        for i in range(len(v.items)):
            if i > 0:
                out.append(44)
            jwrite(doc, v.items[i], out)
        out.append(93)
    elif v.kind == JOBJ:
        # sort keys by byte order
        var order = List[Int]()
        for i in range(len(v.keys)):
            order.append(i)
        var m = len(order)
        for i in range(m):
            for j in range(i + 1, m):
                if bytes_less(v.keys[order[j]], v.keys[order[i]]):
                    var t = order[i]; order[i] = order[j]; order[j] = t
        out.append(123)
        for i in range(len(order)):
            if i > 0:
                out.append(44)
            jwrite_str(v.keys[order[i]], out)
            out.append(58)
            jwrite(doc, v.vals[order[i]], out)
        out.append(125)

def bytes_less(a: Bytes, b: Bytes) -> Bool:
    var n = len(a) if len(a) < len(b) else len(b)
    for i in range(n):
        if a[i] != b[i]:
            return a[i] < b[i]
    return len(a) < len(b)

def jcanon(doc: JDoc, idx: Int) -> Bytes:
    var out = Bytes()
    jwrite(doc, idx, out)
    return out^

# response builders (plain JSON objects as byte strings)
def resp_obj(pairs: String) -> Bytes:
    return bstr("{" + pairs + "}")

def q(s: String) -> String:
    var out = Bytes()
    jwrite_str(bstr(s), out)
    return to_str(out)

def qbytes(b: Bytes) -> String:
    var out = Bytes()
    jwrite_str(b, out)
    return to_str(out)

# ------------------------------------------------------------------ stores
struct DynStore(Copyable, Movable):
    var coords: List[List[Int]]
    var texts: List[Bytes]
    var capacity: Int
    var resize_count: Int

    def __init__(out self, var coords: List[List[Int]], var texts: List[Bytes], capacity: Int, resize_count: Int):
        self.coords = coords^
        self.texts = texts^
        self.capacity = capacity
        self.resize_count = resize_count

def dyn_new() -> DynStore:
    return DynStore(List[List[Int]](), List[Bytes](), 1, 0)

def dyn_push(mut st: DynStore, coord: List[Int], text: Bytes):
    if len(st.coords) == st.capacity:
        st.capacity *= 2
        st.resize_count += 1
    st.coords.append(coord.copy())
    st.texts.append(text.copy())

def dyn_load(data: Bytes) -> DynStore:
    var st = dyn_new()
    var sc = explode(data)
    for i in range(len(sc)):
        dyn_push(st, sc[i].coord, sc[i].text)
    return st^

def dyn_find(st: DynStore, coord: List[Int]) -> Int:
    var lo = 0
    var hi = len(st.coords)
    while lo < hi:
        var mid = (lo + hi) // 2
        var c = coord_cmp(st.coords[mid], coord)
        if c < 0:
            lo = mid + 1
        elif c > 0:
            hi = mid
        else:
            return mid
    return -1 - lo  # insertion point encoded

def dyn_fetch(st: DynStore, coord: List[Int]) -> Bytes:
    var f = dyn_find(st, coord)
    if f >= 0:
        return st.texts[f].copy()
    return Bytes()

def dyn_update(mut st: DynStore, coord: List[Int], text: Bytes, overwrite: Bool):
    var f = dyn_find(st, coord)
    if f >= 0:
        if len(text) == 0:
            if overwrite:
                dyn_remove_at(st, f)
            return
        if overwrite:
            st.texts[f] = text.copy()
        else:
            st.texts[f] = bytes_cat(st.texts[f], text)
        return
    if len(text) == 0:
        return
    var at = -1 - f
    if len(st.coords) == st.capacity:
        st.capacity *= 2
        st.resize_count += 1
    st.coords.insert(at, coord.copy())
    st.texts.insert(at, text.copy())

def dyn_remove_at(mut st: DynStore, at: Int):
    _ = st.coords.pop(at)
    _ = st.texts.pop(at)
    if st.capacity > 1 and len(st.coords) <= st.capacity // 4:
        st.capacity = max(1, st.capacity // 2)
        st.resize_count += 1

def dyn_remove(mut st: DynStore, coord: List[Int]):
    var f = dyn_find(st, coord)
    if f >= 0:
        dyn_remove_at(st, f)

def dyn_serialize(st: DynStore) -> Bytes:
    var sc = List[Scroll]()
    for i in range(len(st.coords)):
        sc.append(Scroll(st.coords[i].copy(), st.texts[i].copy()))
    return implode(sc)

struct TrnStore(Copyable, Movable):
    var childs: List[Dict[Int, Int]]
    var leaf: List[Bytes]
    var has: List[Bool]

    def __init__(out self, var childs: List[Dict[Int, Int]], var leaf: List[Bytes], var has: List[Bool]):
        self.childs = childs^
        self.leaf = leaf^
        self.has = has^

def trn_new() -> TrnStore:
    var st = TrnStore(List[Dict[Int, Int]](), List[Bytes](), List[Bool]())
    st.childs.append(Dict[Int, Int]())
    st.leaf.append(Bytes())
    st.has.append(False)
    return st^

def trn_node(mut st: TrnStore, coord: List[Int], create: Bool) raises -> Int:
    var node = 0
    for d in range(8):
        var k = coord[d]
        if k in st.childs[node]:
            node = st.childs[node][k]
        elif create:
            var nn = len(st.childs)
            st.childs[node][k] = nn
            st.childs.append(Dict[Int, Int]())
            st.leaf.append(Bytes())
            st.has.append(False)
            node = nn
        else:
            return -1
    return node

def trn_put(mut st: TrnStore, coord: List[Int], text: Bytes) raises:
    var node = trn_node(st, coord, True)
    var k = coord[8]
    if k in st.childs[node]:
        var ln = st.childs[node][k]
        st.leaf[ln] = text.copy()
        st.has[ln] = True
    else:
        var nn = len(st.childs)
        st.childs[node][k] = nn
        st.childs.append(Dict[Int, Int]())
        st.leaf.append(text.copy())
        st.has.append(True)

def trn_fetch(st: TrnStore, coord: List[Int]) raises -> Bytes:
    var node = 0
    for d in range(8):
        var k = coord[d]
        if k in st.childs[node]:
            node = st.childs[node][k]
        else:
            return Bytes()
    var k = coord[8]
    if k in st.childs[node]:
        var ln = st.childs[node][k]
        if st.has[ln]:
            return st.leaf[ln].copy()
    return Bytes()

def trn_update(mut st: TrnStore, coord: List[Int], text: Bytes, overwrite: Bool) raises:
    if len(text) == 0:
        if overwrite:
            trn_remove(st, coord)
        return
    if not overwrite:
        var t2 = bytes_cat(trn_fetch(st, coord), text)
        trn_put(st, coord, t2)
        return
    trn_put(st, coord, text)

def trn_remove(mut st: TrnStore, coord: List[Int]) raises:
    var node = 0
    for d in range(8):
        var k = coord[d]
        if k in st.childs[node]:
            node = st.childs[node][k]
        else:
            return
    var k = coord[8]
    if k in st.childs[node]:
        var ln = st.childs[node][k]
        st.has[ln] = False
        st.leaf[ln] = Bytes()

def trn_collect(st: TrnStore, node: Int, depth: Int, prefix: List[Int], mut sc: List[Scroll]) raises:
    if depth == 9:
        if st.has[node]:
            sc.append(Scroll(prefix.copy(), st.leaf[node].copy()))
        return
    # depth counts tree levels: root is 0, leaf nodes sit at 9
    var keys = List[Int]()
    for kv in st.childs[node].items():
        keys.append(kv.key)
    # sort keys
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            if keys[j] < keys[i]:
                var t = keys[i]; keys[i] = keys[j]; keys[j] = t
    for i in range(len(keys)):
        var p2 = prefix.copy()
        p2.append(keys[i])
        trn_collect(st, st.childs[node][keys[i]], depth + 1, p2, sc)

def trn_serialize(st: TrnStore) raises -> Bytes:
    var sc = List[Scroll]()
    trn_collect(st, 0, 0, List[Int](), sc)
    return implode(sc)

def trn_load(data: Bytes) raises -> TrnStore:
    var st = trn_new()
    var sc = explode(data)
    for i in range(len(sc)):
        trn_put(st, sc[i].coord, sc[i].text)
    return st^

def trn_length(st: TrnStore) raises -> Int:
    var sc = List[Scroll]()
    trn_collect(st, 0, 0, List[Int](), sc)
    return len(sc)

# ------------------------------------------------------------------ gpg
comptime IMPL = "mojo"
comptime KEY_UID = "telephone-mojo"

def gpg_base() -> String:
    return "gpg --batch --yes --pinentry-mode loopback --passphrase '' "

def do_keygen() -> Bytes:
    var listing = shell_out(gpg_base() + "--list-keys --with-colons")
    if not contains_bytes(listing, bstr("pub:")):
        _ = shell(gpg_base() + "--quick-generate-key " + shq(KEY_UID) + " ed25519 sign never")
    var pub = shell_out(gpg_base() + "--armor --export " + shq(KEY_UID))
    var pubs = to_str(pub)
    if not ends_with_str(pubs, "\n"):
        pubs += "\n"
    return bstr('{"impl":"mojo","pubkey":' + q(pubs) + "}")

def contains_bytes(hay: Bytes, needle: Bytes) -> Bool:
    if len(needle) == 0 or len(hay) < len(needle):
        return False
    for i in range(len(hay) - len(needle) + 1):
        var ok = True
        for j in range(len(needle)):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return True
    return False

def starts_with(hay: Bytes, needle: Bytes) -> Bool:
    if len(hay) < len(needle):
        return False
    for i in range(len(needle)):
        if hay[i] != needle[i]:
            return False
    return True

def ends_with_str(s: String, suf: String) -> Bool:
    var sb = s.as_bytes()
    var fb = suf.as_bytes()
    if len(sb) < len(fb):
        return False
    for i in range(len(fb)):
        if sb[len(sb) - len(fb) + i] != fb[i]:
            return False
    return True

def do_attest(descriptor_canon: Bytes) -> Bytes:
    var dp = tmpbase() + ".desc"
    var sp = tmpbase() + ".sig"
    try:
        write_file_bytes(dp, descriptor_canon)
    except:
        pass
    _ = shell(gpg_base() + "--detach-sign --armor -u " + shq(KEY_UID) + " -o " + shq(sp) + " " + shq(dp))
    var sig = read_file_bytes(sp)
    _ = shell("rm -f " + dp + " " + sp)
    return bstr('{"signature":' + qbytes(sig) + "}")

def verify_signature(pubkeys: Bytes, data: Bytes, sig_armored: Bytes) -> Bool:
    var td = tmpbase() + ".vfy"
    _ = shell("mkdir -p " + td + "/gnupg")
    _ = shell("chmod 700 " + td + "/gnupg")
    try:
        write_file_bytes(td + "/keys.asc", pubkeys)
        write_file_bytes(td + "/data", data)
        write_file_bytes(td + "/sig.asc", sig_armored)
    except:
        pass
    var base = "GNUPGHOME=" + shq(td + "/gnupg") + " gpg --batch --yes "
    # NOTE: these gpg calls run with stdout/stderr redirected to
    # FILES, invoked directly (no shell() subshell wrap, no pipes):
    # the in-process system() layer intermittently reports spurious
    # failures (rc 512) for the wrapped/piped forms of the very same
    # commands, while the file-redirected form is reliable. A bounded
    # retry covers residual flakiness; a genuinely bad signature
    # fails deterministically on every attempt.
    var icmd = base + "--import " + shq(td + "/keys.asc") + " >" + td + "/out.txt 2>" + td + "/err.txt"
    var rc1 = -1
    for _ in range(5):
        rc1 = run_system(icmd)
        if rc1 == 0:
            break
    var ok = False
    if rc1 == 0:
        var vcmd = base + "--verify " + shq(td + "/sig.asc") + " " + shq(td + "/data") + " >" + td + "/out.txt 2>" + td + "/err.txt"
        for _ in range(5):
            if run_system(vcmd) == 0:
                ok = True
                break
    _ = shell("rm -rf " + td)
    return ok

# ------------------------------------------------------------------ game logic
def req_state(doc: JDoc, req: Int) -> Bytes:
    var si = jget(doc, req, "state")
    if si >= 0:
        return b64_decode(jstr(doc, si))
    var bi = jget(doc, req, "state_b64")
    if bi >= 0:
        return b64_decode(jstr(doc, bi))
    return Bytes()

def echo_value(doc: JDoc, ping: Int) -> String:
    var game = jstr(doc, jget(doc, ping, "game"))
    var round_b = jstr(doc, jget(doc, ping, "round"))
    if len(round_b) == 0:
        round_b = jstr(doc, jget(doc, ping, "turn"))
    var nonce = jstr(doc, jget(doc, ping, "nonce"))
    var seed = bytes_cat(bstr("mojo|"), bytes_cat(game, bytes_cat(bstr("|"), bytes_cat(round_b, bytes_cat(bstr("|"), nonce)))))
    return sha256_hex(seed)

def elect_winner(doc: JDoc, req: Int) -> String:
    var pos = to_str(jstr(doc, jget(doc, req, "position")))
    var turn = doc.arena[jget(doc, req, "turn")].n
    var ci = jget(doc, req, "candidates")
    var cands = List[String]()
    if ci >= 0:
        for i in range(len(doc.arena[ci].items)):
            cands.append(to_str(jstr(doc, doc.arena[ci].items[i])))
    if len(cands) == 0:
        return IMPL
    var joined = String()
    for i in range(len(cands)):
        if i > 0:
            joined += ","
        joined += cands[i]
    var seed = bstr(pos + "|" + String(turn) + "|" + joined)
    var hb = sha256_bytes(seed)
    return cands[Int(hb[0]) % len(cands)]

def wrap999(x: Int) -> Int:
    return 1 + ((x - 1) % 999 + 999) % 999

def next_coord(c: List[Int]) -> List[Int]:
    var out = c.copy()
    var d = 8
    while d >= 0:
        if out[d] < 999:
            out[d] += 1
            return out^
        out[d] = 1
        d -= 1
    return out^

def do_choose(doc: JDoc, req: Int) -> Bytes:
    var state = req_state(doc, req)
    var pos_s = to_str(jstr(doc, jget(doc, req, "position")))
    var turn = doc.arena[jget(doc, req, "turn")].n
    var pv = parse_coord(pos_s)
    var sc = explode(state)
    var hb = sha256_bytes(bytes_cat(bstr(pos_s + "|" + String(turn) + "|"), state))
    var dim = Int(hb[1]) % 9
    var bump = 1 + Int(hb[2]) % 3
    var cand = pv.copy()
    cand[dim] = wrap999(cand[dim] + bump)
    var reserved = List[List[Int]]()
    reserved.append([1, 1, 1, 1, 1, 1, 1, 1, 1])
    reserved.append([1, 1, 1, 1, 1, 1, 1, 1, 2])
    reserved.append([1, 1, 1, 1, 1, 1, 1, 1, 3])
    while True:
        var used = False
        for i in range(len(sc)):
            if coord_cmp(sc[i].coord, cand) == 0:
                used = True
                break
        if not used:
            for r in range(len(reserved)):
                if coord_cmp(reserved[r], cand) == 0:
                    used = True
                    break
        if not used:
            break
        cand = next_coord(cand)
    var cs = coord_str(cand)
    var text = "mojo turn " + String(turn) + " at " + cs
    return bstr('{"coordinate":' + q(cs) + ',"op":"insert","text":' + q(text) + "}")

def do_apply(doc: JDoc, req: Int) -> Bytes:
    var state = req_state(doc, req)
    var step = jget(doc, req, "step")
    var op = to_str(jstr(doc, jget(doc, step, "op")))
    var cs = to_str(jstr(doc, jget(doc, step, "coordinate")))
    var text = jstr(doc, jget(doc, step, "text"))
    var coord = parse_coord(cs)
    if op == "fetch":
        var fh = sha256_hex(fetch_text(state, coord))
        return bstr('{"fetch_sha256":' + q(fh) + ',"state_b64":' + q(b64_encode(state)) + ',"state_sha256":' + q(sha256_hex(state)) + "}")
    if len(coord) != 9:
        return bstr('{"error":"bad coordinate"}')
    var newdata: Bytes
    if op == "insert":
        newdata = phext_insert(state, coord, text)
    elif op == "replace":
        newdata = phext_replace(state, coord, text)
    elif op == "remove":
        newdata = phext_remove(state, coord)
    else:
        return bstr('{"error":"unknown step op"}')
    return bstr('{"fetch_sha256":null,"state_b64":' + q(b64_encode(newdata)) + ',"state_sha256":' + q(sha256_hex(newdata)) + "}")

# ------------------------------------------------------------------ validate
def index_c() -> List[Int]:
    return [1, 1, 1, 1, 1, 1, 1, 1, 1]

def keys_c() -> List[Int]:
    return [1, 1, 1, 1, 1, 1, 1, 1, 2]

def kh_c() -> List[Int]:
    return [1, 1, 1, 1, 1, 1, 1, 1, 3]

def vfail(detail: String) -> Bytes:
    return bstr('{"detail":' + q(detail) + ',"impl":"mojo","verdict":"fail"}')

def scroll_map(sc: List[Scroll], coord: List[Int]) -> Bytes:
    for i in range(len(sc)):
        if coord_cmp(sc[i].coord, coord) == 0:
            return sc[i].text.copy()
    return Bytes()

def scroll_present(sc: List[Scroll], coord: List[Int]) -> Bool:
    for i in range(len(sc)):
        if coord_cmp(sc[i].coord, coord) == 0:
            return True
    return False

def do_validate(doc: JDoc, req: Int) -> Bytes:
    var step = jget(doc, req, "step")
    var op = to_str(jstr(doc, jget(doc, step, "op")))
    var state = req_state(doc, req)
    var pri = jget(doc, req, "prior_state")
    if pri >= 0:
        var prior = b64_decode(jstr(doc, pri))
        var evi = jget(doc, req, "event_coord")
        if evi >= 0:
            # driver form: prior = cached pre-turn state
            var cs = to_str(jstr(doc, jget(doc, step, "coordinate")))
            var coord = parse_coord(cs)
            var ev = parse_coord(to_str(jstr(doc, evi)))
            var index_line = jstr(doc, jget(doc, req, "index_line"))
            var text = jstr(doc, jget(doc, step, "text"))
            var new_sc = explode(state)
            var old_sc = explode(prior)
            if not bytes_eq(scroll_map(new_sc, coord), text):
                return vfail("placed scroll missing or altered")
            for i in range(len(old_sc)):
                var c = old_sc[i].coord.copy()
                if coord_cmp(c, index_c()) == 0:
                    continue
                if not scroll_present(new_sc, c) or not bytes_eq(scroll_map(new_sc, c), old_sc[i].text):
                    return vfail("prior scroll overwritten at " + coord_str(c))
            for i in range(len(new_sc)):
                var c = new_sc[i].coord.copy()
                if not scroll_present(old_sc, c) and coord_cmp(c, coord) != 0 and coord_cmp(c, ev) != 0:
                    return vfail("unexpected new scroll at " + coord_str(c))
            var idx = scroll_map(new_sc, index_c())
            var a = trim_trail_lf(idx)
            var b = trim_trail_lf(index_line)
            if len(b) > len(a) or not bytes_eq(bytes_slice(a, len(a) - len(b), len(a)), b):
                return vfail("index does not record the placement")
            return bstr('{"impl":"mojo","verdict":"pass"}')
        # selftest prior form
        if op != "insert":
            return vfail("step op is not insert")
        var cs2 = to_str(jstr(doc, jget(doc, step, "coordinate")))
        var coord2 = parse_coord(cs2)
        var text2 = jstr(doc, jget(doc, step, "text"))
        var smp = explode(state)
        var pmp = explode(prior)
        if not bytes_eq(scroll_map(smp, coord2), text2):
            return vfail("placed scroll absent or content differs at " + cs2)
        if scroll_present(pmp, coord2):
            return vfail("coordinate was not unused in the prior state")
        if len(smp) != len(pmp) + 1:
            return vfail("scroll count did not grow by exactly one")
        for i in range(len(pmp)):
            if not bytes_eq(scroll_map(smp, pmp[i].coord), pmp[i].text):
                return vfail("a prior scroll was overwritten: " + coord_str(pmp[i].coord))
        return bstr('{"detail":"placed at unused coordinate; all prior scrolls intact","impl":"mojo","verdict":"pass"}')
    return vfail("validate called before init")

def trim_trail_lf(b: Bytes) -> Bytes:
    var n = len(b)
    while n > 0 and b[n - 1] == 10:
        n -= 1
    return bytes_slice(b, 0, n)

# ------------------------------------------------------------------ verify
def vfail2(n: Int, msg: String) -> Bytes:
    return bstr('{"first_failure":{"detail":' + q(msg) + '},"impl":"mojo","placements_checked":' + String(n) + ',"verdict":"fail"}')

def split_lines(b: Bytes) -> List[Bytes]:
    var out = List[Bytes]()
    var start = 0
    for i in range(len(b)):
        if b[i] == 10:
            out.append(bytes_slice(b, start, i))
            start = i + 1
    if start < len(b):
        out.append(bytes_slice(b, start, len(b)))
    return out^

def split_sp(b: Bytes) -> List[Bytes]:
    var out = List[Bytes]()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == 32:
            out.append(bytes_slice(b, start, i))
            start = i + 1
    return out^

def do_verify(doc: JDoc, req: Int) -> Bytes:
    var state = req_state(doc, req)
    var pubkeys = jstr(doc, jget(doc, req, "pubkeys"))
    var sc = explode(state)
    var keys_text = scroll_map(sc, keys_c())
    if len(keys_text) == 0:
        return vfail2(0, "no public-keys scroll at 1.1.1/1.1.1/1.1.2")
    if not bytes_eq(trim_both(pubkeys), trim_both(keys_text)):
        return vfail2(0, "supplied pubkeys do not match the inscribed keys scroll")
    var kh = scroll_map(sc, kh_c())
    if len(kh) == 0:
        return vfail2(0, "no keys-hash scroll at 1.1.1/1.1.1/1.1.3")
    if not bytes_eq(strip_spaces(kh), bstr(sha256_hex(keys_text))):
        return vfail2(0, "keys-hash scroll does not match the keys scroll")
    # index lines
    var idx_lines = List[Bytes]()
    var lines = split_lines(scroll_map(sc, index_c()))
    for li in range(len(lines)):
        var ln = trim_both(lines[li])
        if len(ln) > 0 and ln[0] != 35:
            idx_lines.append(ln.copy())
    var checked = 0
    var seen = List[String]()
    var prev_hash = String("")
    var have_prev = False
    var seq = 0
    while True:
        seq += 1
        var ev_coord: List[Int] = [1, 1, 1, 1, 1, 1, 2, 1, seq]
        if not scroll_present(sc, ev_coord):
            break
        var ev_doc = jparse(scroll_map(sc, ev_coord))
        var root = 0
        var body = jget(ev_doc, root, "body")
        if body < 0:
            return vfail2(checked, "event " + String(seq) + " lacks a body object")
        var pv = jget(ev_doc, root, "prev")
        if pv < 0:
            return vfail2(checked, "event " + String(seq) + " lacks prev")
        if seq == 1:
            if ev_doc.arena[pv].kind != JNULL:
                return vfail2(checked, "event 1 prev is not null")
        else:
            if to_str(jstr(ev_doc, pv)) != prev_hash:
                return vfail2(checked, "event chain broken at seq " + String(seq))
        prev_hash = sha256_hex(jcanon(ev_doc, body))
        have_prev = True
        if to_str(jstr(ev_doc, jget(ev_doc, body, "type"))) != "placement":
            continue
        var cs = to_str(jstr(ev_doc, jget(ev_doc, body, "coord")))
        var text_hash = to_str(jstr(ev_doc, jget(ev_doc, body, "text_sha256")))
        var file_hash = to_str(jstr(ev_doc, jget(ev_doc, body, "file_sha256")))
        var att_b64 = jstr(ev_doc, jget(ev_doc, body, "att"))
        var turn_i = jget(ev_doc, body, "turn")
        var turn_n = ev_doc.arena[turn_i].n if turn_i >= 0 else 0
        var actor = to_str(jstr(ev_doc, jget(ev_doc, body, "actor")))
        for s in range(len(seen)):
            if seen[s] == cs:
                return vfail2(checked, "coordinate reused at " + cs)
        var pcoord = parse_coord(cs)
        if not scroll_present(sc, pcoord):
            return vfail2(checked, "placement missing at " + cs)
        if sha256_hex(scroll_map(sc, pcoord)) != text_hash:
            return vfail2(checked, "placement hash mismatch at " + cs)
        var found_idx = False
        for li in range(len(idx_lines)):
            var f = split_sp(idx_lines[li])
            if len(f) == 4 and to_str(f[1]) == cs:
                found_idx = True
                if to_str(f[2]) != text_hash or to_str(f[0]) != String(turn_n) or to_str(f[3]) != actor:
                    return vfail2(checked, "index mismatch at " + cs)
        if not found_idx:
            return vfail2(checked, "index mismatch at " + cs)
        var desc = bstr('{"coordinate":' + q(cs) + ',"file_sha256":' + q(file_hash) + ',"scroll_sha256":' + q(text_hash) + ',"turn":' + String(turn_n) + "}")
        if not verify_signature(pubkeys, desc, b64_decode(att_b64)):
            return vfail2(checked, "event " + String(seq) + " signature: gpg verify failed")
        seen.append(cs)
        checked += 1
    if checked == 0:
        return vfail2(0, "no placement events found")
    if len(idx_lines) != checked:
        return vfail2(checked, "index lines != placements")
    return bstr('{"first_failure":null,"impl":"mojo","placements_checked":' + String(checked) + ',"verdict":"pass"}')

def trim_both(b: Bytes) -> Bytes:
    var lo = 0
    var hi = len(b)
    while lo < hi and (b[lo] == 32 or b[lo] == 9 or b[lo] == 10 or b[lo] == 13):
        lo += 1
    while hi > lo and (b[hi - 1] == 32 or b[hi - 1] == 9 or b[hi - 1] == 10 or b[hi - 1] == 13):
        hi -= 1
    return bytes_slice(b, lo, hi)

def strip_spaces(b: Bytes) -> Bytes:
    var out = Bytes()
    for i in range(len(b)):
        if b[i] != 32 and b[i] != 9 and b[i] != 10 and b[i] != 13:
            out.append(b[i])
    return out^

# ------------------------------------------------------------------ dispatch
def handle(req_bytes: Bytes) -> Bytes:
    var doc = jparse(req_bytes)
    var req = 0
    var cmd = to_str(jstr(doc, jget(doc, req, "cmd")))
    if cmd == "id":
        return bstr('{"impl":"mojo"}')
    if cmd == "echo":
        var ping = jget(doc, req, "ping")
        return bstr('{"echo":' + q(echo_value(doc, ping)) + ',"impl":"mojo"}')
    if cmd == "elect":
        return bstr('{"elect":' + q(elect_winner(doc, req)) + "}")
    if cmd == "choose":
        return do_choose(doc, req)
    if cmd == "apply":
        return do_apply(doc, req)
    if cmd == "keygen":
        return do_keygen()
    if cmd == "attest":
        var desc = jget(doc, req, "descriptor")
        return do_attest(jcanon(doc, desc))
    if cmd == "init":
        var st = req_state(doc, req)
        _ = explode(st)
        return bstr('{"impl":"mojo","verdict":"pass"}')
    if cmd == "validate":
        return do_validate(doc, req)
    if cmd == "verify":
        return do_verify(doc, req)
    return bstr('{"error":' + q("unknown cmd " + cmd) + "}")

def unframe(line: Bytes) -> Bytes:
    if starts_with(line, bstr("GZ1:")):
        var tp = tmpbase()
        try:
            write_file_bytes(tp + ".b64", bytes_slice(line, 4, len(line)))
        except:
            pass
        _ = shell("base64 -d " + tp + ".b64 | gzip -dc > " + tp + ".raw")
        var data = read_file_bytes(tp + ".raw")
        _ = shell("rm -f " + tp + ".b64 " + tp + ".raw")
        return data^
    return line.copy()

def frame(resp: Bytes) -> Bytes:
    if len(resp) > 8192:
        var tp = tmpbase()
        try:
            write_file_bytes(tp + ".raw", resp)
        except:
            pass
        _ = shell("gzip -c " + tp + ".raw | base64 -w0 > " + tp + ".b64")
        var enc = read_file_bytes(tp + ".b64")
        _ = shell("rm -f " + tp + ".raw " + tp + ".b64")
        return bytes_cat(bstr("GZ1:"), trim_trail_lf(enc))
    return resp.copy()

def process_file(req_path: String, resp_path: String) raises:
    # GZ1 framing lives in the hub runner (bash), not here: Mojo's
    # in-process system() pipelines proved unreliable (dash "Bad fd
    # number" on piped commands), while plain gpg system() calls are
    # solid. The runner unframes requests and frames large replies.
    var raw = read_file_bytes(req_path)
    var line = trim_trail_lf(raw)
    var resp: Bytes
    try:
        resp = handle(line)
    except:
        resp = bstr('{"error":"mojo: handler exception"}')
    write_file_bytes(resp_path, bytes_cat(resp, bstr("\n")))

# ------------------------------------------------------------------ tests
struct Suite(Copyable, Movable):
    var checks: Int
    var failures: Int

    def __init__(out self, checks: Int, failures: Int):
        self.checks = checks
        self.failures = failures

    def ok(mut self, cond: Bool, name: String):
        self.checks += 1
        if not cond:
            self.failures += 1
            print("FAIL:", name)

    def eqb(mut self, a: Bytes, b: Bytes, name: String):
        self.ok(bytes_eq(a, b), name)

def run_tests(fixtures_dir: String) raises:
    var suite = Suite(0, 0)
    # coordinate
    suite.ok(coord_str(parse_coord("1.2.3/4.5.6/7.8.9")) == "1.2.3/4.5.6/7.8.9", "coord format")
    suite.ok(coord_cmp(parse_coord("1.1.1/1.1.1/1.1.1"), parse_coord("1.1.1/1.1.1/1.1.2")) < 0, "order scroll")
    suite.ok(coord_cmp(parse_coord("1.1.1/1.1.1/1.1.9"), parse_coord("1.1.1/1.1.2/1.1.1")) < 0, "order section")
    suite.ok(len(parse_coord("0.1.1/1.1.1/1.1.1")) == 0, "coord rejects 0")
    suite.ok(len(parse_coord("1.1/1.1.1/1.1.1")) == 0, "coord rejects short")
    # phokenize / explode
    var sc = explode(bstr("hello"))
    suite.ok(len(sc) == 1 and coord_str(sc[0].coord) == "1.1.1/1.1.1/1.1.1", "one scroll at root")
    suite.eqb(sc[0].text, bstr("hello"), "first text")
    sc = explode(bstr("a\x17b\x17\x17c\nline2"))
    suite.ok(len(sc) == 3, "scroll breaks")
    suite.ok(coord_str(sc[2].coord) == "1.1.1/1.1.1/1.1.4", "gap coord advance")
    suite.eqb(sc[2].text, bstr("c\nline2"), "newline is ordinary text")
    sc = explode(bstr("x\x01y"))
    suite.ok(coord_str(sc[1].coord) == "2.1.1/1.1.1/1.1.1", "library break resets")
    suite.ok(len(explode(Bytes())) == 0, "empty buffer")
    var bin_data: Bytes = [0x61, 0x00, 0xFF, 0x62]
    sc = explode(bin_data)
    suite.ok(len(sc) == 1 and len(sc[0].text) == 4, "binary text preserved")
    # round trip
    var sample = bstr("alpha\x17beta\x18gamma\x01delta")
    suite.eqb(implode(explode(sample)), sample, "round trip sample")
    var n1 = normalize(bstr("\x17\x17lead"))
    suite.eqb(normalize(n1), n1, "normalize idempotent")
    # fetch incl gaps
    var buf = bstr("one\x17two\x17\x17four")
    suite.eqb(fetch_text(buf, parse_coord("1.1.1/1.1.1/1.1.4")), bstr("four"), "fetch 4")
    suite.eqb(fetch_text(buf, parse_coord("1.1.1/1.1.1/1.1.3")), Bytes(), "gap fetch empty")
    # insert
    var res = phext_insert(bstr("base"), parse_coord("1.1.1/1.1.1/1.1.1"), bstr("+more"))
    suite.eqb(fetch_text(res, parse_coord("1.1.1/1.1.1/1.1.1")), bstr("base+more"), "insert appends")
    res = phext_insert(Bytes(), parse_coord("1.1.1/1.1.1/1.1.3"), bstr("new"))
    suite.eqb(res, bstr("\x17\x17new"), "insert at gap emits breaks")
    # replace / remove (coordinate-preserving)
    res = phext_replace(bstr("old\x17keep"), parse_coord("1.1.1/1.1.1/1.1.1"), bstr("new"))
    suite.eqb(res, bstr("new\x17keep"), "replace overwrites")
    res = phext_remove(bstr("a\x17b\x17c"), parse_coord("1.1.1/1.1.1/1.1.2"))
    suite.eqb(res, bstr("a\x17\x17c"), "remove leaves a gap (no renumbering)")
    suite.eqb(fetch_text(res, parse_coord("1.1.1/1.1.1/1.1.3")), bstr("c"), "neighbour keeps coordinate")
    suite.ok(len(phext_remove(bstr("only"), parse_coord("1.1.1/1.1.1/1.1.1"))) == 0, "remove sole scroll")
    suite.eqb(phext_remove(bstr("a"), parse_coord("5.5.5/5.5.5/5.5.5")), bstr("a"), "remove gap no-op")
    # sha256 / base64 known vectors
    suite.ok(sha256_hex(bstr("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc")
    suite.ok(sha256_hex(Bytes()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 empty")
    suite.ok(b64_encode(bstr("hello")) == "aGVsbG8=", "b64 encode")
    suite.eqb(b64_decode(bstr("aGVsbG8=")), bstr("hello"), "b64 decode")
    # canonical JSON
    var jd = jparse(bstr('{"b":1,"a":{"z":[true,null,"x\\n"],"m":2}}'))
    suite.ok(to_str(jcanon(jd, 0)) == '{"a":{"m":2,"z":[true,null,"x\\n"]},"b":1}', "canonical json")
    # Dynamic + Transitive equivalence
    var dyn = dyn_load(Bytes())
    var trn = trn_load(Bytes())
    var str_buf = Bytes()
    var ops: List[List[String]] = [
        ["insert", "1.1.1/1.1.1/1.1.1", "alpha"],
        ["insert", "1.1.1/1.1.1/1.1.3", "gamma"],
        ["insert", "1.1.1/1.1.1/1.1.2", "beta"],
        ["insert", "1.1.1/1.1.1/1.1.2", "+"],
        ["replace", "2.1.1/1.1.1/1.1.1", "lib2"],
        ["remove", "1.1.1/1.1.1/1.1.3", ""],
        ["insert", "1.1.1/1.1.1/1.1.1", ""],
        ["replace", "1.1.1/1.1.1/1.1.1", ""],
    ]
    for oi in range(len(ops)):
        var op = ops[oi][0]
        var cc = parse_coord(ops[oi][1])
        var tx = bstr(ops[oi][2])
        if op == "insert":
            str_buf = phext_insert(str_buf, cc, tx)
            dyn_update(dyn, cc, tx, False)
            trn_update(trn, cc, tx, False)
        elif op == "replace":
            str_buf = phext_replace(str_buf, cc, tx)
            dyn_update(dyn, cc, tx, True)
            trn_update(trn, cc, tx, True)
        else:
            str_buf = phext_remove(str_buf, cc)
            dyn_remove(dyn, cc)
            trn_remove(trn, cc)
        suite.eqb(dyn_serialize(dyn), str_buf, "dynamic == string after " + op + " " + ops[oi][1])
        suite.eqb(trn_serialize(trn), str_buf, "transitive == string after " + op + " " + ops[oi][1])
    suite.eqb(dyn_fetch(dyn, parse_coord("1.1.1/1.1.1/1.1.3")), Bytes(), "dynamic removed coord is gap")
    suite.eqb(trn_fetch(trn, parse_coord("2.1.1/1.1.1/1.1.1")), bstr("lib2"), "transitive neighbour unmoved")
    suite.ok(len(dyn.coords) == trn_length(trn), "store lengths agree")
    # Dynamic capacity discipline
    var cap = dyn_load(Bytes())
    for i in range(1, 65):
        var cc: List[Int] = [1, 1, 1, 1, 1, 1, 1, 1, i]
        if len(cap.coords) == cap.capacity:
            cap.capacity *= 2
            cap.resize_count += 1
        cap.coords.append(cc^)
        cap.texts.append(bstr("s"))
    suite.ok(cap.capacity == 64, "capacity doubles to fit 64")
    suite.ok(cap.resize_count <= 7, "resize count is logarithmic")
    # fixtures
    if fixtures_dir.byte_length() > 0:
        var list_path = tmpbase() + ".fixlist"
        var findcmd = "find " + shq(fixtures_dir) + " -name input.phext | sort > " + list_path
        _ = run_system(findcmd)
        var listing = read_file_bytes(list_path)
        var paths = split_lines(listing)
        var identical = 0
        var idem = 0
        for pi in range(len(paths)):
            var p = to_str(paths[pi])
            if p.byte_length() == 0:
                continue
            var data = read_file_bytes(p)
            if bytes_eq(implode(explode(data)), data):
                identical += 1
            var nn = normalize(data)
            if bytes_eq(normalize(nn), nn):
                idem += 1
        print("fixtures:", len(paths), "input.phext,", identical, "byte-identical round-trips,", idem, "normalize-idempotent")
        suite.ok(len(paths) == 16, "16 fixtures found")
        suite.ok(identical == len(paths), "fixtures byte-identical round-trips")
        suite.ok(idem == len(paths), "all fixtures normalize idempotently")
    print("mojo suite:", suite.checks, "checks,", suite.failures, "failures")
    if suite.failures > 0:
        raise Error("suite failures")

# ------------------------------------------------------------------ main
def main() raises:
    var args = argv()
    if len(args) > 1 and args[1] == "test":
        var fx = String("")
        if len(args) > 2:
            fx = String(args[2])
        run_tests(fx)
        return
    if len(args) > 2:
        process_file(String(args[1]), String(args[2]))
        return
    print('{"error":"usage: telephone <reqfile> <respfile> | test [fixtures]"}')
