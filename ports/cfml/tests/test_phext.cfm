<cfscript>
// Test suite for libphext-cfml — plain assertions, no framework.
// Run via hub: box test_phext.cfm [fixtures_dir]  (arg via env
// TELCFML_FIXTURES, since CommandBox .cfm args are not portable).

include "../src/phext.cfm";

checks = 0;
failures = 0;
function ok(required boolean cond, required string name) {
    checks++;
    if (!arguments.cond) {
        failures++;
        writeOutput("FAIL: " & arguments.name & chr(10));
    }
}
function okb(required string a, required string b, required string name) {
    ok(arguments.a == arguments.b, arguments.name);
}
function C(required string s) { return coordParse(arguments.s); }
function S(required array c) { return coordString(arguments.c); }

ok(S(C("1.2.3/4.5.6/7.8.9")) == "1.2.3/4.5.6/7.8.9", "coord format");
ok(coordCompare(C("1.1.1/1.1.1/1.1.1"), C("1.1.1/1.1.1/1.1.2")) < 0, "order scroll");
ok(coordCompare(C("1.1.1/1.1.1/1.1.9"), C("1.1.1/1.1.2/1.1.1")) < 0, "order section");
ok(coordCompare(C("2.1.1/1.1.1/1.1.1"), C("1.9.9/9.9.9/9.9.9")) > 0, "order library");
try { C("0.1.1/1.1.1/1.1.1"); ok(false, "coord rejects 0"); } catch (any e) { ok(true, "coord rejects 0"); }
try { C("1.1/1.1.1/1.1.1"); ok(false, "coord rejects short"); } catch (any e) { ok(true, "coord rejects short"); }

BR7 = chr(23); BR8 = chr(24); BR0 = chr(1);
sc = phokenize("hello");
ok(arrayLen(sc) == 1, "one scroll");
ok(S(sc[1].coord) == "1.1.1/1.1.1/1.1.1", "first coord");
okb(sc[1].text, "hello", "first text");
sc = phokenize("a" & BR7 & "b" & BR7 & BR7 & "c" & chr(10) & "line2");
ok(arrayLen(sc) == 3, "scroll breaks");
ok(S(sc[2].coord) == "1.1.1/1.1.1/1.1.2", "second coord");
ok(S(sc[3].coord) == "1.1.1/1.1.1/1.1.4", "gap coord advance");
okb(sc[3].text, "c" & chr(10) & "line2", "newline is ordinary text");
sc = phokenize("x" & BR0 & "y");
ok(S(sc[2].coord) == "2.1.1/1.1.1/1.1.1", "library break resets");
sc = phokenize("x" & BR8 & "y");
ok(S(sc[2].coord) == "1.1.1/1.1.1/1.2.1", "section break");
ok(arrayLen(phokenize("")) == 0, "empty buffer");
binText = bufFromBinary(binaryDecode("6100FF62", "hex"));
sc = phokenize(binText);
ok(arrayLen(sc) == 1 && len(sc[1].text) == 4, "binary text preserved");

sample = "alpha" & BR7 & "beta" & BR8 & "gamma" & BR0 & "delta";
okb(dephokenize(phokenize(sample)), sample, "round trip sample");
pair = [{coord: C("1.1.1/1.1.1/1.1.2"), text: "two"},
        {coord: C("1.1.1/1.1.1/1.1.1"), text: "one"}];
okb(dephokenize(pair), "one" & BR7 & "two", "dephokenize sorts canonically");
okb(phextNormalize(phextNormalize(BR7 & BR7 & "lead")),
    phextNormalize(BR7 & BR7 & "lead"), "normalize idempotent");

buf = "one" & BR7 & "two" & BR7 & BR7 & "four";
okb(phextFetch(buf, C("1.1.1/1.1.1/1.1.1")), "one", "fetch 1");
okb(phextFetch(buf, C("1.1.1/1.1.1/1.1.4")), "four", "fetch 4");
okb(phextFetch(buf, C("1.1.1/1.1.1/1.1.3")), "", "gap fetch is empty");
okb(phextFetch(buf, C("9.9.9/9.9.9/9.9.9")), "", "far gap fetch is empty");
okb(phextFetch("", C("1.1.1/1.1.1/1.1.1")), "", "fetch empty buffer");

res = phextInsert("base", C("1.1.1/1.1.1/1.1.1"), "+more");
okb(phextFetch(res, C("1.1.1/1.1.1/1.1.1")), "base+more", "insert appends after existing");
res = phextInsert("", C("1.1.1/1.1.1/1.1.3"), "new");
okb(phextFetch(res, C("1.1.1/1.1.1/1.1.3")), "new", "insert creates at gap");
okb(res, BR7 & BR7 & "new", "insert at gap emits breaks");
res = phextInsert("a" & BR7 & "c", C("1.1.1/1.1.1/1.1.2"), "b");
okb(phextFetch(res, C("1.1.1/1.1.1/1.1.2")), "cb", "insert merges existing + inserted");

res = phextReplace("old" & BR7 & "keep", C("1.1.1/1.1.1/1.1.1"), "new");
okb(res, "new" & BR7 & "keep", "replace overwrites");
res = phextReplace("a", C("1.1.1/1.1.1/1.1.5"), "deep");
okb(phextFetch(res, C("1.1.1/1.1.1/1.1.5")), "deep", "replace creates");
res = phextRemove("a" & BR7 & "b" & BR7 & "c", C("1.1.1/1.1.1/1.1.2"));
okb(res, "a" & BR7 & BR7 & "c", "remove leaves a gap (no renumbering)");
okb(phextFetch(res, C("1.1.1/1.1.1/1.1.2")), "", "removed coordinate reads empty");
okb(phextFetch(res, C("1.1.1/1.1.1/1.1.3")), "c", "neighbour keeps its coordinate");
ok(len(phextRemove("only", C("1.1.1/1.1.1/1.1.1"))) == 0, "remove sole scroll");
okb(phextRemove("a", C("5.5.5/5.5.5/5.5.5")), "a", "remove gap is a no-op");

map = phextExplode("x" & BR7 & "y");
ok(structCount(map) == 2, "explode count");
okb(phextImplode(map), "x" & BR7 & "y", "implode round trip");

// Dynamic + Transitive equivalence with the string path
dyn = dynCreate("");
trn = transCreate("");
strBuf = "";
steps = [
    ["insert", "1.1.1/1.1.1/1.1.1", "alpha"],
    ["insert", "1.1.1/1.1.1/1.1.3", "gamma"],
    ["insert", "1.1.1/1.1.1/1.1.2", "beta"],
    ["insert", "1.1.1/1.1.1/1.1.2", "+"],
    ["replace", "2.1.1/1.1.1/1.1.1", "lib2"],
    ["remove", "1.1.1/1.1.1/1.1.3", ""],
    ["insert", "1.1.1/1.1.1/1.1.1", ""],
    ["replace", "1.1.1/1.1.1/1.1.1", ""]
];
for (st in steps) {
    op = st[1]; cs = st[2]; tx = st[3];
    cc = C(cs);
    if (op == "insert") {
        strBuf = phextInsert(strBuf, cc, tx); dynInsert(dyn, cc, tx); transInsert(trn, cc, tx);
    } else if (op == "replace") {
        strBuf = phextReplace(strBuf, cc, tx); dynReplace(dyn, cc, tx); transReplace(trn, cc, tx);
    } else {
        strBuf = phextRemove(strBuf, cc); dynRemove(dyn, cc); transRemove(trn, cc);
    }
    okb(dynSerialize(dyn), strBuf, "dynamic == string after op");
    okb(transSerialize(trn), strBuf, "transitive == string after op");
    okb(dynFetch(dyn, cc), phextFetch(strBuf, cc), "dynamic fetch after op");
    okb(transFetch(trn, cc), phextFetch(strBuf, cc), "transitive fetch after op");
}
okb(dynFetch(dyn, C("1.1.1/1.1.1/1.1.3")), "", "dynamic removed coord is gap");
okb(transFetch(trn, C("1.1.1/1.1.1/1.1.3")), "", "transitive removed coord is gap");
okb(dynFetch(dyn, C("2.1.1/1.1.1/1.1.1")), "lib2", "dynamic neighbour unmoved");
okb(transFetch(trn, C("2.1.1/1.1.1/1.1.1")), "lib2", "transitive neighbour unmoved");
ok(dyn.n == transCount(trn), "store lengths agree");

capD = dynCreate("");
for (i = 1; i <= 64; i++) {
    cc = coordRoot(); cc[9] = i;
    dynAppend(capD, cc, "s");
}
ok(capD.cap == 64, "capacity doubles to fit 64");
ok(capD.resizeCount <= 7, "resize count is logarithmic");

// fixtures
fixturesDir = createObject("java", "java.lang.System").getenv("TELCFML_FIXTURES");
if (!isNull(fixturesDir) && len(fixturesDir) > 0) {
    files = directoryList(fixturesDir, true, "path");
    nFiles = 0; identical = 0; idem = 0;
    for (p in files) {
        if (right(p, 11) != "input.phext") continue;
        nFiles++;
        data = bufFromBinary(fileReadBinary(p));
        if (dephokenize(phokenize(data)) == data) identical++;
        n1 = phextNormalize(data);
        if (phextNormalize(n1) == n1) idem++;
    }
    writeOutput("fixtures: " & nFiles & " input.phext, " & identical &
                " byte-identical round-trips, " & idem & " normalize-idempotent" & chr(10));
    ok(nFiles == 16, "16 fixtures found");
    ok(identical == nFiles, "fixtures byte-identical round-trips");
    ok(idem == nFiles, "all fixtures normalize idempotently");
} else {
    writeOutput("fixtures: skipped (no fixtures dir)" & chr(10));
}

writeOutput("cfml suite: " & checks & " checks, " & failures & " failures" & chr(10));
if (failures > 0) {
    // signal failure via a marker file the runner checks
    fileWrite(createObject("java", "java.lang.System").getenv("TELCFML_FAILMARK"), "fail", "utf-8");
}
</cfscript>
