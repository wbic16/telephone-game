<cfscript>
include "/home/wbic16/telephone-cfml/port/src/phext.cfm";
function bufOfB64(required string b64) { return bufFromBinary(binaryDecode(arguments.b64, "base64")); }
function scrollSortMerge(required array stack) {
    var n = arrayLen(arguments.stack);
    if (n <= 1) return arguments.stack;
    var mid = int(n / 2);
    var left = []; var right = [];
    for (var i = 1; i <= mid; i++) arrayAppend(left, arguments.stack[i]);
    for (var i = mid + 1; i <= n; i++) arrayAppend(right, arguments.stack[i]);
    left = scrollSortMerge(left); right = scrollSortMerge(right);
    var out = []; var a = 1; var b = 1;
    while (a <= arrayLen(left) && b <= arrayLen(right)) {
        if (coordCompare(left[a].coord, right[b].coord) <= 0) { arrayAppend(out, left[a]); a++; }
        else { arrayAppend(out, right[b]); b++; }
    }
    while (a <= arrayLen(left)) { arrayAppend(out, left[a]); a++; }
    while (b <= arrayLen(right)) { arrayAppend(out, right[b]); b++; }
    return out;
}
function implodeMerge(required struct map) {
    var stack = [];
    for (var k in arguments.map) arrayAppend(stack, {coord: coordParse(k), text: arguments.map[k]});
    var sorted = scrollSortMerge(stack);
    var sb = newSB(); var loc = coordRoot();
    for (var ps in sorted) { if (len(ps.text) == 0) continue; loc = emitAdvance(sb, loc, ps.coord); sb.append(ps.text); }
    return "" & sb.toString();
}
prior = bufOfB64(fileRead("/home/wbic16/telephone-cfml/cache/prof-snap.b64", "utf-8"));
m = phextExplode(prior);
t0=getTickCount(); a = phextImplode(m); t1=getTickCount(); b = implodeMerge(m); t2=getTickCount(); b2 = implodeMerge(m); t3=getTickCount();
res = "implode_insertion=" & (t1-t0) & " implode_merge=" & (t2-t1) & " implode_merge2=" & (t3-t2) & " equal=" & (a == b) & " roundtrip=" & (b == prior);
fileWrite("/home/wbic16/telephone-cfml/cache/prof5-out.txt", res, "utf-8");
</cfscript>
