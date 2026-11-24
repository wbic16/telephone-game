# phext.awk -- libphext port for GNU Awk (0.6.1 parity semantics;
# normative reference: libphext-py). Phext is a 9-dimensional
# plain-text format: scrolls of text addressed by a Coordinate,
# separated in the byte stream by dimension-break bytes.
#
# Dimension breaks (dimension index -> byte):
#   0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
#   4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
#   8 scroll 0x17.
# A break at dimension d increments component d and resets all lower
# components to 1. Scroll text is a maximal run of non-break bytes;
# the newline byte 0x0A is ordinary text, NOT a break. Run under
# LC_ALL=C so strings are bytes.
#
# Remove is COORDINATE-PRESERVING: the scroll's text is deleted and
# every other scroll keeps its coordinate (the delimiters needed to
# reach it stay); later scrolls do NOT shift.
#
# Coordinates are handled internally as comma-joined strings
# "a,b,c,d,e,f,g,h,i"; the string form is "a.b.c/d.e.f/g.h.i".
#
# API:
#   coord_parse(s) / coord_str(c) / coord_cmp(a, b)
#   phokenize(data)  -> count; fills PH_COORD[i], PH_TEXT[i]
#   dephokenize(n)   -> canonical bytes from PH_COORD/PH_TEXT
#   normalize(data) / fetch(data, coord) / insert / replace / remove
#   explode(data)    -> count; fills EXPL[coordstr] (string coords)
#   implode()        -> bytes from EXPL
#   DynamicPhext: dyn_* functions over a capacity-managed array
#     (doubles when full, halves at quarter-full), mirroring
#     phext/dynamic.py; TransitivePhext: trn_* functions over a
#     branching hash map keyed by coordinate prefixes (one level per
#     dimension, depth 9), mirroring phext/transitive.py. Both stores
#     serialize byte-identically to the buffer API and never hold an
#     empty scroll (replace "" removes, insert "" is a no-op).

BEGIN {
    split("1 31 30 29 28 26 25 24 23", __codes, " ")
    for (__d = 0; __d < 9; __d++) {
        BREAKBYTE[__d] = sprintf("%c", __codes[__d + 1])
        BREAKDIM[BREAKBYTE[__d]] = __d
    }
    BREAKCLASS = "[\001\037\036\035\034\032\031\030\027]"
}

function coord_parse(s,    g, p, i, out, k) {
    out = ""
    split(s, g, "/")
    for (i = 1; i <= 3; i++) {
        split(g[i], p, ".")
        for (k = 1; k <= 3; k++) {
            if (p[k] !~ /^[0-9]+$/ || p[k] + 0 < 1) {
                return ""
            }
            out = out (out == "" ? "" : ",") (p[k] + 0)
        }
    }
    if (split(out, p, ",") != 9) return ""
    return out
}

function coord_str(c,    a) {
    split(c, a, ",")
    return a[1] "." a[2] "." a[3] "/" a[4] "." a[5] "." a[6] "/" a[7] "." a[8] "." a[9]
}

function coord_cmp(a, b,    x, y, i) {
    split(a, x, ","); split(b, y, ",")
    for (i = 1; i <= 9; i++) {
        if (x[i] + 0 < y[i] + 0) return -1
        if (x[i] + 0 > y[i] + 0) return 1
    }
    return 0
}

function _apply_break(w, d,    k) {
    w[d + 1]++
    for (k = d + 2; k <= 9; k++) w[k] = 1
}

function _walker_str(w,    s, i) {
    s = ""
    for (i = 1; i <= 9; i++) s = s (i > 1 ? "," : "") w[i]
    return s
}

function phokenize(data,    n, i, w, ch, rest, cnt, end) {
    n = length(data)
    i = 1
    cnt = 0
    for (k = 1; k <= 9; k++) w[k] = 1
    while (i <= n) {
        ch = substr(data, i, 1)
        if (ch in BREAKDIM) {
            _apply_break(w, BREAKDIM[ch])
            i++
            continue
        }
        rest = substr(data, i)
        if (match(rest, BREAKCLASS)) {
            end = i + RSTART - 2
        } else {
            end = n
        }
        cnt++
        PH_COORD[cnt] = _walker_str(w)
        PH_TEXT[cnt] = substr(data, i, end - i + 1)
        i = end + 1
    }
    PH_N = cnt
    return cnt
}

function _advance(loc, target,    la, ta, d, out, k, lower) {
    # loc and target are comma strings; updates LOCARR (global array
    # form of loc) and returns the break bytes to emit.
    split(loc, la, ","); split(target, ta, ",")
    if (coord_cmp(loc, target) >= 0) {
        for (k = 1; k <= 9; k++) LOCARR[k] = la[k]
        return ""
    }
    d = 1
    while (la[d] == ta[d]) d++
    out = ""
    for (k = la[d]; k < ta[d]; k++) out = out BREAKBYTE[d - 1]
    LOCARR[d] = ta[d]
    for (k = d + 1; k <= 9; k++) LOCARR[k] = 1
    for (k = 1; k < d; k++) LOCARR[k] = la[k]
    for (lower = d + 1; lower <= 9; lower++) {
        for (k = 1; k < ta[lower]; k++) out = out BREAKBYTE[lower - 1]
        LOCARR[lower] = ta[lower]
    }
    return out
}

function dephokenize(cnt,    out, loc, i, la) {
    out = ""
    loc = "1,1,1,1,1,1,1,1,1"
    for (i = 1; i <= cnt; i++) {
        out = out _advance(loc, PH_COORD[i])
        loc = _walker_str(LOCARR)
        out = out PH_TEXT[i]
    }
    return out
}

function normalize(data,    cnt) {
    cnt = phokenize(data)
    return dephokenize(cnt)
}

function fetch(data, coord,    cnt, i) {
    cnt = phokenize(data)
    for (i = 1; i <= cnt; i++) {
        if (PH_COORD[i] == coord) return PH_TEXT[i]
    }
    return ""
}

function _update(data, coord, text, overwrite,    cnt, i, oc, ot, appended, cs) {
    cnt = phokenize(data)
    oc = 0
    appended = 0
    for (i = 1; i <= cnt; i++) {
        cs = PH_COORD[i]
        if (!appended && coord_cmp(cs, coord) > 0) {
            oc++; OC_COORD[oc] = coord; OC_TEXT[oc] = text; appended = 1
        }
        if (!appended && cs == coord) {
            oc++; OC_COORD[oc] = coord
            OC_TEXT[oc] = overwrite ? text : (PH_TEXT[i] text)
            appended = 1
            continue
        }
        oc++; OC_COORD[oc] = cs; OC_TEXT[oc] = PH_TEXT[i]
    }
    if (!appended) {
        oc++; OC_COORD[oc] = coord; OC_TEXT[oc] = text
    }
    # serialize OC_* through the PH_* slots
    for (i = 1; i <= oc; i++) {
        PH_COORD[i] = OC_COORD[i]; PH_TEXT[i] = OC_TEXT[i]
    }
    return dephokenize(oc)
}

function insert(data, coord, text) { return _update(data, coord, text, 0) }
function replace(data, coord, text) { return _update(data, coord, text, 1) }

function remove(data, coord) {
    # Coordinate-preserving: empty the scroll, then normalize; later
    # scrolls keep their coordinates.
    return normalize(_update(data, coord, "", 1))
}

function explode(data,    cnt, i) {
    delete EXPL
    cnt = phokenize(data)
    for (i = 1; i <= cnt; i++) {
        EXPL[coord_str(PH_COORD[i])] = PH_TEXT[i]
    }
    return cnt
}

function implode(    keys, nk, i, j, tmp, out, loc) {
    nk = 0
    for (k in EXPL) {
        nk++; keys[nk] = coord_parse(k)
    }
    # insertion sort by coord_cmp (scroll counts are modest)
    for (i = 2; i <= nk; i++) {
        tmp = keys[i]
        j = i - 1
        while (j >= 1 && coord_cmp(keys[j], tmp) > 0) {
            keys[j + 1] = keys[j]; j--
        }
        keys[j + 1] = tmp
    }
    for (i = 1; i <= nk; i++) {
        PH_COORD[i] = keys[i]
        PH_TEXT[i] = EXPL[coord_str(keys[i])]
    }
    return dephokenize(nk)
}

# ---------------------------------------------------------------------
# DynamicPhext -- dynamic-array store over globals DYN_*.
# Capacity starts at 1, doubles when full, halves at quarter-full.
function dyn_init(buffer,    cnt, i) {
    DYN_N = 0; DYN_CAP = 1; DYN_RESIZES = 0; DYN_COPIED = 0
    delete DYN_COORD; delete DYN_TEXT
    if (buffer != "") {
        cnt = phokenize(buffer)
        for (i = 1; i <= cnt; i++) dyn_push(PH_COORD[i], PH_TEXT[i])
    }
}
function dyn_resize(newcap) {
    DYN_CAP = newcap; DYN_RESIZES++; DYN_COPIED += DYN_N
}
function dyn_grow_if_full() {
    if (DYN_N == DYN_CAP) dyn_resize(2 * DYN_CAP)
}
function dyn_shrink_if_sparse() {
    if (DYN_CAP > 1 && DYN_N <= int(DYN_CAP / 4)) {
        dyn_resize(DYN_CAP / 2 < 1 ? 1 : int(DYN_CAP / 2))
    }
}
function dyn_push(c, t) {
    dyn_grow_if_full()
    DYN_N++
    DYN_COORD[DYN_N] = c; DYN_TEXT[DYN_N] = t
}
function dyn_find(c,    lo, hi, mid, cmp) {
    lo = 1; hi = DYN_N
    while (lo <= hi) {
        mid = int((lo + hi) / 2)
        cmp = coord_cmp(DYN_COORD[mid], c)
        if (cmp < 0) lo = mid + 1
        else if (cmp > 0) hi = mid - 1
        else { DYN_FIND_IDX = mid; return 1 }
    }
    DYN_FIND_IDX = lo
    return 0
}
function dyn_fetch(c) {
    return dyn_find(c) ? DYN_TEXT[DYN_FIND_IDX] : ""
}
function dyn_serialize(    i) {
    for (i = 1; i <= DYN_N; i++) {
        PH_COORD[i] = DYN_COORD[i]; PH_TEXT[i] = DYN_TEXT[i]
    }
    return dephokenize(DYN_N)
}
function dyn_remove_at(idx,    i) {
    for (i = idx; i < DYN_N; i++) {
        DYN_COORD[i] = DYN_COORD[i + 1]; DYN_TEXT[i] = DYN_TEXT[i + 1]
    }
    delete DYN_COORD[DYN_N]; delete DYN_TEXT[DYN_N]
    DYN_N--
    dyn_shrink_if_sparse()
}
function dyn_update(c, t, overwrite,    idx, i) {
    if (dyn_find(c)) {
        idx = DYN_FIND_IDX
        if (t == "") {
            if (overwrite) dyn_remove_at(idx)
            return
        }
        DYN_TEXT[idx] = overwrite ? t : (DYN_TEXT[idx] t)
        return
    }
    if (t == "") return
    idx = DYN_FIND_IDX
    dyn_grow_if_full()
    for (i = DYN_N; i >= idx; i--) {
        DYN_COORD[i + 1] = DYN_COORD[i]; DYN_TEXT[i + 1] = DYN_TEXT[i]
    }
    DYN_COORD[idx] = c; DYN_TEXT[idx] = t
    DYN_N++
}
function dyn_insert(c, t) { dyn_update(c, t, 0) }
function dyn_replace(c, t) { dyn_update(c, t, 1) }
function dyn_remove(c) { if (dyn_find(c)) dyn_remove_at(DYN_FIND_IDX) }

# ---------------------------------------------------------------------
# TransitivePhext -- branching hash-map store over globals TRN_*.
# TRN_LEAF[full comma coord] = text and TRN_NODE[prefix] tracks the
# branch structure (one key-space per dimension, depth 9); fetch /
# put / remove walk one prefix level per dimension. Serialization
# enumerates leaves in coordinate order.
function trn_init(buffer,    cnt, i) {
    delete TRN_LEAF; delete TRN_NODE
    TRN_N = 0
    if (buffer != "") {
        cnt = phokenize(buffer)
        for (i = 1; i <= cnt; i++) trn_put(PH_COORD[i], PH_TEXT[i])
    }
}
function trn_put(c, t,    a, i, prefix) {
    split(c, a, ",")
    prefix = ""
    for (i = 1; i <= 9; i++) {
        prefix = prefix (i > 1 ? "," : "") a[i]
        TRN_NODE[prefix] = 1
    }
    if (!(c in TRN_LEAF)) TRN_N++
    TRN_LEAF[c] = t
}
function trn_fetch(c) {
    return (c in TRN_LEAF) ? TRN_LEAF[c] : ""
}
function trn_remove(c,    a, i, prefix, p) {
    if (!(c in TRN_LEAF)) return 0
    delete TRN_LEAF[c]
    TRN_N--
    # prune branch nodes left without any leaf beneath them
    split(c, a, ",")
    for (i = 9; i >= 1; i--) {
        prefix = ""
        for (p = 1; p <= i; p++) prefix = prefix (p > 1 ? "," : "") a[p]
        if (!_trn_prefix_has_leaf(prefix)) delete TRN_NODE[prefix]
        else break
    }
    return 1
}
function _trn_prefix_has_leaf(prefix,    k, lp) {
    lp = length(prefix)
    for (k in TRN_LEAF) {
        if (substr(k, 1, lp) == prefix) return 1
    }
    return 0
}
function trn_update(c, t, overwrite) {
    if (t == "") {
        if (overwrite) trn_remove(c)
        return
    }
    if (!overwrite && (c in TRN_LEAF)) t = TRN_LEAF[c] t
    trn_put(c, t)
}
function trn_insert(c, t) { trn_update(c, t, 0) }
function trn_replace(c, t) { trn_update(c, t, 1) }
function trn_serialize(    keys, nk, i, j, tmp) {
    nk = 0
    for (k in TRN_LEAF) { nk++; keys[nk] = k }
    for (i = 2; i <= nk; i++) {
        tmp = keys[i]; j = i - 1
        while (j >= 1 && coord_cmp(keys[j], tmp) > 0) {
            keys[j + 1] = keys[j]; j--
        }
        keys[j + 1] = tmp
    }
    for (i = 1; i <= nk; i++) {
        PH_COORD[i] = keys[i]; PH_TEXT[i] = TRN_LEAF[keys[i]]
    }
    return dephokenize(nk)
}
