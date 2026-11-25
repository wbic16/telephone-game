<cfscript>
// libphext-cfml — a CFML (Lucee) port of libphext, 0.6.1 parity.
//
// Semantics are normative from libphext-py: a phext is a byte buffer;
// nine dimension-break bytes walk a 9-component coordinate; scroll
// text is a maximal run of non-break bytes (newline 0x0A is ordinary
// text). Buffers are Lucee strings decoded ISO-8859-1 from the raw
// bytes, so char position == byte position and char code == byte
// value (the Ada String-as-bytes convention). Coordinates are arrays
// of 9 numbers, ordered lexicographically; string form
// a.b.c/d.e.f/g.h.i.

DIM_BREAKS = [1, 31, 30, 29, 28, 26, 25, 24, 23];

function bufFromBinary(required binary b) {
    return "" & createObject("java", "java.lang.String").init(arguments.b, "ISO-8859-1");
}
function bufToBinary(required string s) {
    return arguments.s.getBytes("ISO-8859-1");
}
function breakDim(required numeric code) {
    for (var d = 1; d <= 9; d++) {
        if (DIM_BREAKS[d] == arguments.code) return d;
    }
    return 0;
}
function coordRoot() {
    return [1, 1, 1, 1, 1, 1, 1, 1, 1];
}
function coordParse(required string s) {
    var parts = [];
    var cur = "";
    for (var i = 1; i <= len(arguments.s); i++) {
        var ch = mid(arguments.s, i, 1);
        if (ch == "." || ch == "/") {
            arrayAppend(parts, val(cur));
            cur = "";
        } else {
            cur &= ch;
        }
    }
    arrayAppend(parts, val(cur));
    if (arrayLen(parts) != 9) throw("coordinate needs 9 parts: " & arguments.s);
    for (var n in parts) {
        if (n < 1) throw("components must be >= 1: " & arguments.s);
    }
    return parts;
}
function coordString(required array c) {
    return c[1] & "." & c[2] & "." & c[3] & "/" & c[4] & "." & c[5] & "." &
           c[6] & "/" & c[7] & "." & c[8] & "." & c[9];
}
function coordCompare(required array a, required array b) {
    for (var i = 1; i <= 9; i++) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}
function coordApplyBreak(required array c, required numeric d) {
    var out = duplicate(arguments.c);
    out[d] += 1;
    for (var k = d + 1; k <= 9; k++) out[k] = 1;
    return out;
}

// Bulk break-run collapse: applying a maximal run of break bytes
// one break at a time is equivalent to, for each dimension d,
//   coord'[d] = coord[d] + (count of d-breaks in the run),   or
//   coord'[d] = 1 + (count of d-breaks after the run's last
//                    break of any dimension < d)   when such a
//                    lower break exists (it resets dimension d),
// with dimension 1 never reset. Counts and last-positions come
// from Java String.lastIndexOf / a replace-all length difference
// (Lucee's member replace() defaults to scope "one" — the "all"
// scope argument is load-bearing), so a whole run costs a few
// native scans of the run instead of one CFML step per byte.
// Verified byte-identical to the per-byte walk on the game-scale
// snapshot and on randomized buffers (perf pass, EE ~570).
function coordApplyBreakRun(required array coord, required string run,
                            required array breakChars) {
    var out = duplicate(arguments.coord);
    if (len(arguments.run) == 0) return out;
    for (var d = 1; d <= 9; d++) {
        var lastLower = -1;
        for (var k = 1; k < d; k++) {
            var p = arguments.run.lastIndexOf(arguments.breakChars[k]);
            if (p > lastLower) lastLower = p;
        }
        var tail = lastLower >= 0 ?
            arguments.run.substring(lastLower + 1) : arguments.run;
        var cnt = len(tail) - len(tail.replace(arguments.breakChars[d], "", "all"));
        if (d == 1) out[d] = arguments.coord[d] + cnt;
        else if (lastLower >= 0) out[d] = 1 + cnt;
        else out[d] = arguments.coord[d] + cnt;
    }
    return out;
}

// phokenize -> array of structs {coord: array, text: string}
// Scans maximal text runs with a Java regex Matcher (one native
// pass over the buffer) and collapses the break run before each
// text run arithmetically (coordApplyBreakRun). Game-scale
// buffers are mostly break bytes (1.30 MB of 2.27 MB on the
// test-001 snapshot), so the per-byte CFML walk this replaces
// cost ~5.4 s per explode; this costs ~0.2 s, semantics equal.
function phokenize(required string buffer) {
    var out = [];
    var n = len(arguments.buffer);
    if (n == 0) return out;
    var breakChars = [];
    var cls = "";
    for (var d = 1; d <= 9; d++) {
        arrayAppend(breakChars, chr(DIM_BREAKS[d]));
        cls &= chr(DIM_BREAKS[d]);
    }
    var pat = createObject("java", "java.util.regex.Pattern")
        .compile("[^" & cls & "]+");
    var m = pat.matcher(arguments.buffer);
    var coord = coordRoot();
    var prevEnd = 0;
    while (m.find()) {
        var s = m.start();
        if (s > prevEnd) {
            coord = coordApplyBreakRun(coord,
                arguments.buffer.substring(prevEnd, s), breakChars);
        }
        arrayAppend(out, {coord: coord, text: m.group()});
        prevEnd = m.end();
    }
    return out;
}

function sbAppend(required any sb, required string s) {
    arguments.sb.append(arguments.s);
}
function newSB() {
    return createObject("java", "java.lang.StringBuilder").init();
}

// advance loc toward target, appending break bytes to sb; returns loc
function emitAdvance(required any sb, required array loc, required array target) {
    if (coordCompare(arguments.loc, arguments.target) < 0) {
        var dim = 1;
        while (arguments.loc[dim] == arguments.target[dim]) dim++;
        for (var j = 1; j <= arguments.target[dim] - arguments.loc[dim]; j++) {
            arguments.sb.append(chr(DIM_BREAKS[dim]));
        }
        for (var lower = dim + 1; lower <= 9; lower++) {
            for (var j = 1; j <= arguments.target[lower] - 1; j++) {
                arguments.sb.append(chr(DIM_BREAKS[lower]));
            }
        }
        return duplicate(arguments.target);
    }
    return arguments.loc;
}

function scrollSort(required array stack) {
    // merge sort by coordinate (stable; the insertion sort this
    // replaces was O(n^2) — ~3.2 s to implode the game-scale map,
    // vs ~0.7 s for the whole implode with this sort)
    var n = arrayLen(arguments.stack);
    if (n <= 1) return arguments.stack;
    var mid = int(n / 2);
    var left = [];
    var right = [];
    for (var i = 1; i <= mid; i++) arrayAppend(left, arguments.stack[i]);
    for (var i = mid + 1; i <= n; i++) arrayAppend(right, arguments.stack[i]);
    left = scrollSort(left);
    right = scrollSort(right);
    var out = [];
    var a = 1;
    var b = 1;
    while (a <= arrayLen(left) && b <= arrayLen(right)) {
        if (coordCompare(left[a].coord, right[b].coord) <= 0) {
            arrayAppend(out, left[a]);
            a++;
        } else {
            arrayAppend(out, right[b]);
            b++;
        }
    }
    while (a <= arrayLen(left)) { arrayAppend(out, left[a]); a++; }
    while (b <= arrayLen(right)) { arrayAppend(out, right[b]); b++; }
    return out;
}

function dephokenize(required array stack) {
    var sorted = scrollSort(duplicate(arguments.stack));
    var sb = newSB();
    var loc = coordRoot();
    for (var ps in sorted) {
        if (len(ps.text) == 0) continue;
        loc = emitAdvance(sb, loc, ps.coord);
        sb.append(ps.text);
    }
    return "" & sb.toString();
}

function dephokenizeInOrder(required array stack) {
    var sb = newSB();
    var loc = coordRoot();
    for (var ps in arguments.stack) {
        loc = emitAdvance(sb, loc, ps.coord);
        sb.append(ps.text);
    }
    return "" & sb.toString();
}

function phextNormalize(required string buffer) {
    return dephokenize(phokenize(arguments.buffer));
}
function phextFetch(required string buffer, required array coord) {
    for (var ps in phokenize(arguments.buffer)) {
        if (coordCompare(ps.coord, arguments.coord) == 0) return ps.text;
    }
    return "";
}
function phextUpdate(required string buffer, required array coord,
                     required string scroll, required boolean overwrite) {
    var items = phokenize(arguments.buffer);
    var result = [];
    var nextPs = {coord: arguments.coord, text: arguments.scroll};
    var appended = false;
    for (var ps in items) {
        var cmp = coordCompare(ps.coord, arguments.coord);
        if (cmp > 0 && !appended) {
            arrayAppend(result, nextPs);
            appended = true;
            arrayAppend(result, ps);
        } else if (cmp == 0 && !appended) {
            if (arguments.overwrite) {
                arrayAppend(result, nextPs);
            } else {
                arrayAppend(result, {coord: arguments.coord,
                                     text: ps.text & arguments.scroll});
            }
            appended = true;
        } else {
            arrayAppend(result, ps);
        }
    }
    if (!appended) arrayAppend(result, nextPs);
    return dephokenizeInOrder(result);
}
// insert: existing text is prepended to the inserted text.
function phextInsert(required string buffer, required array coord, required string scroll) {
    return phextUpdate(arguments.buffer, arguments.coord, arguments.scroll, false);
}
function phextReplace(required string buffer, required array coord, required string scroll) {
    return phextUpdate(arguments.buffer, arguments.coord, arguments.scroll, true);
}
// remove: replace with "" then normalize — coordinate-preserving.
function phextRemove(required string buffer, required array coord) {
    return phextNormalize(phextUpdate(arguments.buffer, arguments.coord, "", true));
}
// explode -> struct coordString -> text (ordered struct)
function phextExplode(required string buffer) {
    var out = {};
    for (var ps in phokenize(arguments.buffer)) {
        out[coordString(ps.coord)] = ps.text;
    }
    return out;
}
function phextImplode(required struct map) {
    var stack = [];
    for (var k in arguments.map) {
        arrayAppend(stack, {coord: coordParse(k), text: arguments.map[k]});
    }
    return dephokenize(stack);
}

// ------------------------------------------------------------------
// DynamicPhext: capacity-managed dynamic array scroll store.
function dynCreate(required string buffer) {
    var d = {items: [], cap: 1, n: 0, resizeCount: 0, copied: 0};
    if (len(arguments.buffer) > 0) dynLoad(d, arguments.buffer);
    return d;
}
function dynResize(required struct d, required numeric newCap) {
    var nd = [];
    for (var i = 1; i <= arguments.d.n; i++) nd[i] = arguments.d.items[i];
    arguments.d.items = nd;
    arguments.d.cap = arguments.newCap;
    arguments.d.resizeCount++;
    arguments.d.copied += arguments.d.n;
}
function dynGrow(required struct d) {
    if (arguments.d.n == arguments.d.cap) dynResize(arguments.d, 2 * arguments.d.cap);
}
function dynShrink(required struct d) {
    if (arguments.d.cap > 1 && arguments.d.n <= int(arguments.d.cap / 4)) {
        dynResize(arguments.d, max(1, int(arguments.d.cap / 2)));
    }
}
function dynPush(required struct d, required struct ps) {
    dynGrow(arguments.d);
    arguments.d.n++;
    arguments.d.items[arguments.d.n] = arguments.ps;
}
function dynLoad(required struct d, required string buffer) {
    arguments.d.items = []; arguments.d.cap = 1; arguments.d.n = 0;
    arguments.d.resizeCount = 0; arguments.d.copied = 0;
    arguments.d.items[1] = "";
    for (var ps in phokenize(arguments.buffer)) dynPush(arguments.d, ps);
}
function dynScrolls(required struct d) {
    var out = [];
    for (var i = 1; i <= arguments.d.n; i++) arrayAppend(out, arguments.d.items[i]);
    return out;
}
function dynSerialize(required struct d) {
    return dephokenize(dynScrolls(arguments.d));
}
function dynFind(required struct d, required array coord) {
    var lo = 1;
    var hi = arguments.d.n + 1;
    while (lo < hi) {
        var midIdx = int((lo + hi) / 2);
        var cmp = coordCompare(arguments.d.items[midIdx].coord, arguments.coord);
        if (cmp < 0) lo = midIdx + 1;
        else if (cmp > 0) hi = midIdx;
        else return {index: midIdx, found: true};
    }
    return {index: lo, found: false};
}
function dynFetch(required struct d, required array coord) {
    var f = dynFind(arguments.d, arguments.coord);
    return f.found ? arguments.d.items[f.index].text : "";
}
function dynContains(required struct d, required array coord) {
    return dynFind(arguments.d, arguments.coord).found;
}
function dynAppend(required struct d, required array coord, required string text) {
    if (arguments.d.n > 0 &&
        coordCompare(arguments.coord, arguments.d.items[arguments.d.n].coord) <= 0) {
        throw("append requires a coordinate past the current tail");
    }
    if (len(arguments.text) > 0) dynPush(arguments.d, {coord: arguments.coord, text: arguments.text});
}
function dynUpdate(required struct d, required array coord, required string text,
                   required boolean overwrite) {
    var f = dynFind(arguments.d, arguments.coord);
    if (f.found) {
        if (len(arguments.text) == 0) {
            if (arguments.overwrite) dynRemoveAt(arguments.d, f.index);
        } else if (arguments.overwrite) {
            arguments.d.items[f.index] = {coord: arguments.coord, text: arguments.text};
        } else {
            arguments.d.items[f.index] = {coord: arguments.coord,
                text: arguments.d.items[f.index].text & arguments.text};
        }
    } else if (len(arguments.text) > 0) {
        dynGrow(arguments.d);
        arguments.d.n++;
        for (var i = arguments.d.n; i > f.index; i--) {
            arguments.d.items[i] = arguments.d.items[i - 1];
        }
        arguments.d.items[f.index] = {coord: arguments.coord, text: arguments.text};
    }
}
function dynInsert(required struct d, required array coord, required string text) {
    dynUpdate(arguments.d, arguments.coord, arguments.text, false);
}
function dynReplace(required struct d, required array coord, required string text) {
    dynUpdate(arguments.d, arguments.coord, arguments.text, true);
}
function dynRemoveAt(required struct d, required numeric idx) {
    for (var i = arguments.idx; i < arguments.d.n; i++) {
        arguments.d.items[i] = arguments.d.items[i + 1];
    }
    arguments.d.n--;
    dynShrink(arguments.d);
}
function dynRemove(required struct d, required array coord) {
    var f = dynFind(arguments.d, arguments.coord);
    if (f.found) dynRemoveAt(arguments.d, f.index);
}

// ------------------------------------------------------------------
// TransitivePhext: scroll store over a struct keyed by coordinate
// string; enumeration is always in coordinate order.
function transCreate(required string buffer) {
    var t = {map: {}};
    if (len(arguments.buffer) > 0) transLoad(t, arguments.buffer);
    return t;
}
function transLoad(required struct t, required string buffer) {
    arguments.t.map = {};
    for (var ps in phokenize(arguments.buffer)) {
        arguments.t.map[coordString(ps.coord)] = ps.text;
    }
}
function transCount(required struct t) {
    return structCount(arguments.t.map);
}
function transScrolls(required struct t) {
    var out = [];
    for (var k in arguments.t.map) {
        arrayAppend(out, {coord: coordParse(k), text: arguments.t.map[k]});
    }
    return out;
}
function transSerialize(required struct t) {
    return dephokenize(transScrolls(arguments.t));
}
function transFetch(required struct t, required array coord) {
    var k = coordString(arguments.coord);
    return structKeyExists(arguments.t.map, k) ? arguments.t.map[k] : "";
}
function transContains(required struct t, required array coord) {
    return structKeyExists(arguments.t.map, coordString(arguments.coord));
}
function transUpdate(required struct t, required array coord, required string text,
                     required boolean overwrite) {
    var k = coordString(arguments.coord);
    if (len(arguments.text) == 0) {
        if (arguments.overwrite) structDelete(arguments.t.map, k);
    } else if (arguments.overwrite) {
        arguments.t.map[k] = arguments.text;
    } else if (structKeyExists(arguments.t.map, k)) {
        arguments.t.map[k] &= arguments.text;
    } else {
        arguments.t.map[k] = arguments.text;
    }
}
function transInsert(required struct t, required array coord, required string text) {
    transUpdate(arguments.t, arguments.coord, arguments.text, false);
}
function transReplace(required struct t, required array coord, required string text) {
    transUpdate(arguments.t, arguments.coord, arguments.text, true);
}
function transRemove(required struct t, required array coord) {
    structDelete(arguments.t.map, coordString(arguments.coord));
}
function transAppend(required struct t, required array coord, required string text) {
    transInsert(arguments.t, arguments.coord, arguments.text);
}
</cfscript>
