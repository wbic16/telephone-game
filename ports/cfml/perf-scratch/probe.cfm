<cfscript>
include "/home/wbic16/telephone-cfml/port/src/phext.cfm";
BC = []; for (var d = 1; d <= 9; d++) arrayAppend(BC, chr(DIM_BREAKS[d]));
s = "ab" & chr(23) & "cd" & chr(23) & chr(23) & "e";
lines = [];
arrayAppend(lines, "len=" & len(s));
arrayAppend(lines, "lastIndexOf23=" & s.lastIndexOf(BC[9]));
arrayAppend(lines, "substring2=" & "[" & s.substring(2) & "]");
arrayAppend(lines, "replace23_len=" & len(s.replace(BC[9], "")));
arrayAppend(lines, "ascBC9=" & asc(BC[9]));
t = chr(23) & chr(23);
arrayAppend(lines, "run_lastIndexOf23=" & t.lastIndexOf(BC[9]) & " cnt=" & (len(t) - len(t.replace(BC[9], ""))));
// brute force small buffers: alphabet a, dim9 break (23), dim8 break (24), dim1 break (1)
function applyBreakRun(required array coord, required string run) {
    var out = duplicate(arguments.coord);
    if (len(arguments.run) == 0) return out;
    for (var d = 1; d <= 9; d++) {
        var lastLower = -1;
        for (var k = 1; k < d; k++) {
            var p = arguments.run.lastIndexOf(BC[k]);
            if (p > lastLower) lastLower = p;
        }
        var tail = lastLower >= 0 ? arguments.run.substring(lastLower + 1) : arguments.run;
        var cnt = len(tail) - len(tail.replace(BC[d], ""));
        if (d == 1) out[d] = arguments.coord[d] + cnt;
        else if (lastLower >= 0) out[d] = 1 + cnt;
        else out[d] = arguments.coord[d] + cnt;
    }
    return out;
}
function phokenizeBulk(required string buffer) {
    var out = [];
    var n = len(arguments.buffer);
    if (n == 0) return out;
    var cls = "";
    for (var d = 1; d <= 9; d++) cls &= chr(DIM_BREAKS[d]);
    var pat = createObject("java", "java.util.regex.Pattern").compile("[^" & cls & "]+");
    var m = pat.matcher(arguments.buffer);
    var coord = coordRoot();
    var prevEnd = 0;
    while (m.find()) {
        var s2 = m.start();
        if (s2 > prevEnd) coord = applyBreakRun(coord, arguments.buffer.substring(prevEnd, s2));
        arrayAppend(out, {coord: coord, text: m.group()});
        prevEnd = m.end();
    }
    return out;
}
alpha = ["a", chr(23), chr(24), chr(1), chr(30)];
found = "";
// enumerate all strings up to length 5 over alphabet indices via base-5 counting
for (var total = 1; total <= 5 && found == ""; total++) {
    var combos = 1; for (var i = 1; i <= total; i++) combos *= 5;
    for (var idx = 0; idx < combos && found == ""; idx++) {
        var buf = ""; var v = idx;
        for (var i = 1; i <= total; i++) { buf &= alpha[(v % 5) + 1]; v = int(v / 5); }
        var a = phokenize(buf); var b = phokenizeBulk(buf);
        var ok = arrayLen(a) == arrayLen(b);
        if (ok) { for (var i = 1; i <= arrayLen(a); i++) { if (coordCompare(a[i].coord, b[i].coord) != 0 || a[i].text != b[i].text) { ok = false; break; } } }
        if (!ok) {
            var codes = ""; for (var i = 1; i <= len(buf); i++) codes &= asc(mid(buf, i, 1)) & ",";
            found = "bufCodes=" & codes & " slowN=" & arrayLen(a) & " bulkN=" & arrayLen(b);
            if (arrayLen(a) > 0 && arrayLen(b) > 0) found &= " slow0=" & coordString(a[1].coord) & " bulk0=" & coordString(b[1].coord);
            if (arrayLen(a) > 1 && arrayLen(b) > 1) found &= " slow1=" & coordString(a[2].coord) & " bulk1=" & coordString(b[2].coord);
        }
    }
}
arrayAppend(lines, "brute=" & (found == "" ? "ALL-OK" : found));
fileWrite("/home/wbic16/telephone-cfml/cache/probe-out.txt", arrayToList(lines, chr(10)), "utf-8");
</cfscript>
