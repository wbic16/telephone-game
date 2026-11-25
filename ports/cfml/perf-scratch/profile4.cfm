<cfscript>
include "/home/wbic16/telephone-cfml/port/src/phext.cfm";
function bufOfB64(required string b64) { return bufFromBinary(binaryDecode(arguments.b64, "base64")); }
BC = []; for (var d = 1; d <= 9; d++) arrayAppend(BC, chr(DIM_BREAKS[d]));
function applyBreakRun(required array coord, required string run) {
    var out = duplicate(arguments.coord);
    var n = len(arguments.run);
    if (n == 0) return out;
    for (var d = 1; d <= 9; d++) {
        var lastLower = -1;
        for (var k = 1; k < d; k++) {
            var p = arguments.run.lastIndexOf(BC[k]);
            if (p > lastLower) lastLower = p;
        }
        var tail = lastLower >= 0 ? arguments.run.substring(lastLower + 1) : arguments.run;
        var cnt = len(tail) - len(tail.replace(BC[d], "", "all"));
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
        var s = m.start();
        if (s > prevEnd) coord = applyBreakRun(coord, arguments.buffer.substring(prevEnd, s));
        arrayAppend(out, {coord: coord, text: m.group()});
        prevEnd = m.end();
    }
    return out;
}
function explodeBulk(required string buffer) {
    var out = {};
    for (var ps in phokenizeBulk(arguments.buffer)) out[coordString(ps.coord)] = ps.text;
    return out;
}
prior = bufOfB64(fileRead("/home/wbic16/telephone-cfml/cache/prof-snap.b64", "utf-8"));
t0=getTickCount(); slow = phextExplode(prior); t1=getTickCount();
fast = explodeBulk(prior); t2=getTickCount(); fast2 = explodeBulk(prior); t3=getTickCount();
eq = structCount(slow) == structCount(fast);
bad = "";
if (eq) { for (var k in slow) { if (!structKeyExists(fast,k) || fast[k] != slow[k]) { eq=false; bad=k; break; } } }
// randomized equivalence vs old phokenize on synthetic buffers
randEq = true;
try {
  var rnd = createObject("java", "java.util.Random").init(42);
  for (var trial = 1; trial <= 60 && randEq; trial++) {
      var sb = newSB();
      for (var i = 1; i <= 400; i++) {
          var r = rnd.nextInt(10);
          if (r < 4) sb.append(chr(DIM_BREAKS[rnd.nextInt(9) + 1]));
          else sb.append(chr(97 + rnd.nextInt(26)));
      }
      var buf = sb.toString();
      var a = phokenize(buf); var b = phokenizeBulk(buf);
      if (arrayLen(a) != arrayLen(b)) { randEq = false; break; }
      for (var i = 1; i <= arrayLen(a); i++) {
          if (coordCompare(a[i].coord, b[i].coord) != 0 || a[i].text != b[i].text) { randEq = false; break; }
      }
  }
} catch (any e) { randEq = "ERR:" & e.message; }
t4=getTickCount();
res = "explode_slow=" & (t1-t0) & " explode_bulk=" & (t2-t1) & " explode_bulk2=" & (t3-t2) & " equal=" & eq & " bad=" & bad & " counts=" & structCount(slow) & "/" & structCount(fast) & " randEq=" & randEq & " randMs=" & (t4-t3);
fileWrite("/home/wbic16/telephone-cfml/cache/prof4-out.txt", res, "utf-8");
</cfscript>
