// Test suite for libphext-d — plain assertions, no test framework.
// Run: ./test_phext [fixtures_dir]
module test_phext;

import std.file : dirEntries, SpanMode, read;
import std.stdio : writeln, stderr;
import phext;

int failures = 0;
int checks = 0;

void ok(bool cond, string name) {
    checks += 1;
    if (!cond) { failures += 1; stderr.writeln("FAIL: ", name); }
}

void eq(T)(T a, T b, string name) {
    ok(a == b, name);
}

ubyte[] B(string s) { return cast(ubyte[]) s.dup; }
Coordinate C(string s) { return Coordinate.parse(s); }

int main(string[] args) {
    // coordinate
    eq(C("1.2.3/4.5.6/7.8.9").toString(), "1.2.3/4.5.6/7.8.9", "coord format");
    ok(C("1.1.1/1.1.1/1.1.1") < C("1.1.1/1.1.1/1.1.2"), "order scroll");
    ok(C("1.1.1/1.1.1/1.1.9") < C("1.1.1/1.1.2/1.1.1"), "order section");
    ok(C("2.1.1/1.1.1/1.1.1") > C("1.9.9/9.9.9/9.9.9"), "order library");
    eq(C("1.1.1/1.1.1/1.1.1"), Coordinate.root(), "root");
    try { C("0.1.1/1.1.1/1.1.1"); ok(false, "coord rejects 0"); }
    catch (Exception) { ok(true, "coord rejects 0"); }
    try { C("1.1/1.1.1/1.1.1"); ok(false, "coord rejects short"); }
    catch (Exception) { ok(true, "coord rejects short"); }

    // phokenize
    auto sc = phokenize(B("hello"));
    eq(sc.length, 1, "one scroll");
    eq(sc[0].coord.toString(), "1.1.1/1.1.1/1.1.1", "first coord");
    eq(sc[0].text, B("hello"), "first text");
    sc = phokenize(B("a\x17b\x17\x17c\nline2"));
    eq(sc.length, 3, "scroll breaks");
    eq(sc[1].coord.toString(), "1.1.1/1.1.1/1.1.2", "second coord");
    eq(sc[2].coord.toString(), "1.1.1/1.1.1/1.1.4", "gap coord advance");
    eq(sc[2].text, B("c\nline2"), "newline is ordinary text");
    sc = phokenize(B("x\x01y"));
    eq(sc[1].coord.toString(), "2.1.1/1.1.1/1.1.1", "library break resets");
    sc = phokenize(B("x\x18y"));
    eq(sc[1].coord.toString(), "1.1.1/1.1.1/1.2.1", "section break");
    eq(phokenize(B("")).length, 0, "empty buffer");
    sc = phokenize(cast(ubyte[]) [0x61, 0x00, 0xFF, 0x62]);
    eq(sc.length, 1, "binary text is one scroll");
    eq(sc[0].text.length, 4, "binary text preserved");

    // round trip
    auto sample = B("alpha\x17beta\x18gamma\x01delta");
    eq(dephokenize(phokenize(sample)), sample, "round trip sample");
    auto built = dephokenize([PositionedScroll(C("1.1.1/1.1.1/1.1.2"), B("two")),
                              PositionedScroll(C("1.1.1/1.1.1/1.1.1"), B("one"))]);
    eq(built, B("one\x17two"), "dephokenize sorts canonically");
    eq(normalize(normalize(B("\x17\x17lead"))), normalize(B("\x17\x17lead")),
       "normalize idempotent");

    // fetch incl. gaps
    auto buf = B("one\x17two\x17\x17four");
    eq(fetch(buf, C("1.1.1/1.1.1/1.1.1")), B("one"), "fetch 1");
    eq(fetch(buf, C("1.1.1/1.1.1/1.1.4")), B("four"), "fetch 4");
    eq(fetch(buf, C("1.1.1/1.1.1/1.1.3")), B(""), "gap fetch is empty");
    eq(fetch(buf, C("9.9.9/9.9.9/9.9.9")), B(""), "far gap fetch is empty");
    eq(fetch(B(""), C("1.1.1/1.1.1/1.1.1")), B(""), "fetch empty buffer");

    // insert
    auto out_ = insert(B("base"), C("1.1.1/1.1.1/1.1.1"), B("+more"));
    eq(fetch(out_, C("1.1.1/1.1.1/1.1.1")), B("base+more"), "insert appends after existing");
    out_ = insert(B(""), C("1.1.1/1.1.1/1.1.3"), B("new"));
    eq(fetch(out_, C("1.1.1/1.1.1/1.1.3")), B("new"), "insert creates at gap");
    eq(out_, B("\x17\x17new"), "insert at gap emits breaks");
    out_ = insert(B("a\x17c"), C("1.1.1/1.1.1/1.1.2"), B("b"));
    eq(fetch(out_, C("1.1.1/1.1.1/1.1.2")), B("cb"), "insert merges existing + inserted");

    // replace / remove — remove is coordinate-preserving
    out_ = replace(B("old\x17keep"), C("1.1.1/1.1.1/1.1.1"), B("new"));
    eq(out_, B("new\x17keep"), "replace overwrites");
    out_ = replace(B("a"), C("1.1.1/1.1.1/1.1.5"), B("deep"));
    eq(fetch(out_, C("1.1.1/1.1.1/1.1.5")), B("deep"), "replace creates");
    out_ = remove(B("a\x17b\x17c"), C("1.1.1/1.1.1/1.1.2"));
    eq(out_, B("a\x17\x17c"), "remove leaves a gap (no renumbering)");
    eq(fetch(out_, C("1.1.1/1.1.1/1.1.2")), B(""), "removed coordinate reads empty");
    eq(fetch(out_, C("1.1.1/1.1.1/1.1.3")), B("c"), "neighbour keeps its coordinate");
    eq(remove(B("only"), C("1.1.1/1.1.1/1.1.1")).length, 0, "remove sole scroll");
    eq(remove(B("a"), C("5.5.5/5.5.5/5.5.5")), B("a"), "remove gap is a no-op");

    // explode / implode
    auto map = explode(B("x\x17y"));
    eq(map.length, 2, "explode count");
    eq(implode(map), B("x\x17y"), "implode round trip");

    // DynamicPhext equivalence with the string path over an edit script
    auto dyn = new DynamicPhext();
    auto trn = new TransitivePhext();
    ubyte[] strBuf = B("");
    void step(string op, string coord, string text) {
        auto c = C(coord);
        auto t = B(text);
        if (op == "insert") { strBuf = insert(strBuf, c, t); dyn.insert(c, t); trn.insert(c, t); }
        if (op == "replace") { strBuf = replace(strBuf, c, t); dyn.replace(c, t); trn.replace(c, t); }
        if (op == "remove") { strBuf = remove(strBuf, c); dyn.remove(c); trn.remove(c); }
        eq(dyn.serialize(), strBuf, "dynamic == string after " ~ op ~ " " ~ coord);
        eq(trn.serialize(), strBuf, "transitive == string after " ~ op ~ " " ~ coord);
        eq(dyn.fetch(c), fetch(strBuf, c), "dynamic fetch after " ~ op);
        eq(trn.fetch(c), fetch(strBuf, c), "transitive fetch after " ~ op);
    }
    step("insert", "1.1.1/1.1.1/1.1.1", "alpha");
    step("insert", "1.1.1/1.1.1/1.1.3", "gamma");
    step("insert", "1.1.1/1.1.1/1.1.2", "beta");
    step("insert", "1.1.1/1.1.1/1.1.2", "+");
    step("replace", "2.1.1/1.1.1/1.1.1", "lib2");
    step("remove", "1.1.1/1.1.1/1.1.3", "");
    // removed coordinate is a gap in the stores too; neighbours unmoved
    eq(dyn.fetch(C("1.1.1/1.1.1/1.1.3")), B(""), "dynamic removed coord is gap");
    eq(trn.fetch(C("1.1.1/1.1.1/1.1.3")), B(""), "transitive removed coord is gap");
    eq(dyn.fetch(C("2.1.1/1.1.1/1.1.1")), B("lib2"), "dynamic neighbour unmoved");
    eq(trn.fetch(C("2.1.1/1.1.1/1.1.1")), B("lib2"), "transitive neighbour unmoved");
    step("insert", "1.1.1/1.1.1/1.1.1", "");   // empty insert is a no-op
    step("replace", "1.1.1/1.1.1/1.1.1", "");  // replace "" removes
    eq(dyn.length, trn.length, "store lengths agree");

    // DynamicPhext capacity discipline: grows by doubling, and a
    // grow/shrink boundary does not thrash resizes.
    auto cap = new DynamicPhext();
    foreach (i; 1 .. 65) {
        int[9] v = 1; v[8] = i;
        cap.append(Coordinate(v), B("s"));
    }
    eq(cap.capacity, 64, "capacity doubles to fit 64");
    ok(cap.resizeCount <= 7, "resize count is logarithmic");

    // fixtures
    if (args.length > 1) {
        import std.path : buildPath;
        int files = 0, identical = 0, idem = 0;
        foreach (entry; dirEntries(args[1], SpanMode.depth)) {
            if (!entry.isFile || entry.name.length < 11 ||
                entry.name[$ - 11 .. $] != "input.phext") continue;
            files += 1;
            auto data = cast(ubyte[]) read(entry.name);
            if (dephokenize(phokenize(data)) == data) identical += 1;
            auto n1 = normalize(data);
            if (normalize(n1) == n1) idem += 1;
        }
        writeln("fixtures: ", files, " input.phext, ", identical,
                " byte-identical round-trips, ", idem, " normalize-idempotent");
        eq(files, 16, "16 fixtures found");
        eq(identical, files, "fixtures byte-identical round-trips");
        eq(idem, files, "all fixtures normalize idempotently");
    } else {
        writeln("fixtures: skipped (no fixtures dir)");
    }

    writeln("d suite: ", checks, " checks, ", failures, " failures");
    return failures == 0 ? 0 : 1;
}
