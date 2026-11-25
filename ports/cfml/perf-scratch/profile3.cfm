<cfscript>
include "/home/wbic16/telephone-cfml/port/src/phext.cfm";
function bufOfB64(required string b64) { return bufFromBinary(binaryDecode(arguments.b64, "base64")); }
function phokenizeRx(required string buffer) {
    var out = [];
    var coord = coordRoot();
    var n = len(arguments.buffer);
    if (n == 0) return out;
    var cls = "";
    for (var d = 1; d <= 9; d++) cls &= chr(DIM_BREAKS[d]);
    var pat = createObject("java", "java.util.regex.Pattern").compile("[" & cls & "]");
    var m = pat.matcher(arguments.buffer);
    var last = 0;
    while (m.find()) {
        var s = m.start();
        if (s > last) arrayAppend(out, {coord: coord, text: arguments.buffer.substring(last, s)});
        coord = coordApplyBreak(coord, breakDim(asc(m.group())));
        last = m.end();
    }
    if (last < n) arrayAppend(out, {coord: coord, text: arguments.buffer.substring(last, n)});
    return out;
}
function explodeRx(required string buffer) {
    var out = {};
    for (var ps in phokenizeRx(arguments.buffer)) out[coordString(ps.coord)] = ps.text;
    return out;
}
prior = bufOfB64(fileRead("/home/wbic16/telephone-cfml/cache/prof-snap.b64", "utf-8"));
t0=getTickCount(); slow = phextExplode(prior); t1=getTickCount();
fast = explodeRx(prior); t2=getTickCount(); fast2 = explodeRx(prior); t3=getTickCount();
eq = structCount(slow) == structCount(fast);
if (eq) { for (var k in slow) { if (!structKeyExists(fast,k) || fast[k] != slow[k]) { eq=false; break; } } }
res = "explode_slow=" & (t1-t0) & " explode_rx=" & (t2-t1) & " explode_rx2=" & (t3-t2) & " equal=" & eq & " counts=" & structCount(slow) & "/" & structCount(fast);
fileWrite("/home/wbic16/telephone-cfml/cache/prof3-out.txt", res, "utf-8");
</cfscript>
