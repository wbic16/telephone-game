<cfscript>
include "/home/wbic16/telephone-cfml/port/src/phext.cfm";
function bufOfB64(required string b64) { return bufFromBinary(binaryDecode(arguments.b64, "base64")); }
function phokenizeFast(required string buffer) {
    var out = [];
    var coord = coordRoot();
    var n = len(arguments.buffer);
    if (n == 0) return out;
    var breakChars = [];
    for (var d = 1; d <= 9; d++) arrayAppend(breakChars, chr(DIM_BREAKS[d]));
    var pos = 1;
    while (pos <= n) {
        var nextPos = 0; var nextDim = 0;
        for (var d = 1; d <= 9; d++) {
            var p = find(breakChars[d], arguments.buffer, pos);
            if (p > 0 && (nextPos == 0 || p < nextPos)) { nextPos = p; nextDim = d; if (p == pos) break; }
        }
        if (nextDim == 0) break;
        if (nextPos > pos) arrayAppend(out, {coord: coord, text: mid(arguments.buffer, pos, nextPos - pos)});
        coord = coordApplyBreak(coord, nextDim);
        pos = nextPos + 1;
    }
    if (pos <= n) arrayAppend(out, {coord: coord, text: mid(arguments.buffer, pos, n - pos + 1)});
    return out;
}
function explodeFast(required string buffer) {
    var out = {};
    for (var ps in phokenizeFast(arguments.buffer)) out[coordString(ps.coord)] = ps.text;
    return out;
}
prior = bufOfB64(fileRead("/home/wbic16/telephone-cfml/cache/prof-snap.b64", "utf-8"));
t0=getTickCount(); oldSlow = phextExplode(prior); t1=getTickCount();
oldFast = explodeFast(prior); t2=getTickCount();
eq = structCount(oldSlow) == structCount(oldFast);
if (eq) { for (var k in oldSlow) { if (!structKeyExists(oldFast,k) || oldFast[k] != oldSlow[k]) { eq=false; break; } } }
t3=getTickCount(); oldFast2 = explodeFast(prior); t4=getTickCount();
// implode timing (uses scrollSort insertion sort)
imp = phextImplode(oldFast); t5=getTickCount();
res = "explode_slow=" & (t1-t0) & " explode_fast=" & (t2-t1) & " explode_fast2=" & (t4-t3) & " equal=" & eq & " counts=" & structCount(oldSlow) & "/" & structCount(oldFast) & " implode_from_fastmap=" & (t5-t4) & " implode_eq=" & (imp == prior) & " impLen=" & len(imp);
fileWrite("/home/wbic16/telephone-cfml/cache/prof2-out.txt", res, "utf-8");
</cfscript>
