// Test suite for libphext-vala — plain assertions, no framework.
// Run: test_phext [fixtures_dir]

const string BR7 = "\x17";
const string BR8 = "\x18";
const string BR0 = "\x01";
int checks = 0;
int failures = 0;

void ok(bool cond, string name) {
    checks++;
    if (!cond) { failures++; stderr.printf("FAIL: %s\n", name); }
}
bool eqb(uint8[] a, uint8[] b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
}
void okb(uint8[] a, uint8[] b, string name) { ok(eqb(a, b), name); }
uint8[] B(string s) { return s.data; }
PhextCoord C(string s) {
    try { return PhextCoord.parse(s); } catch (Error e) { assert_not_reached(); }
}

string[] collect_fixtures(string dir) {
    string[] found = {};
    try {
        var d = Dir.open(dir);
        string name;
        while ((name = d.read_name()) != null) {
            var p = Path.build_filename(dir, name);
            if (FileUtils.test(p, FileTest.IS_DIR)) {
                foreach (var sub in collect_fixtures(p)) found += sub;
            }
            else if (name == "input.phext") found += p;
        }
    } catch (Error e) {}
    return found;
}

int main(string[] args) {
    ok(C("1.2.3/4.5.6/7.8.9").to_string() == "1.2.3/4.5.6/7.8.9", "coord format");
    ok(PhextCoord.compare(C("1.1.1/1.1.1/1.1.1"), C("1.1.1/1.1.1/1.1.2")) < 0, "order scroll");
    ok(PhextCoord.compare(C("1.1.1/1.1.1/1.1.9"), C("1.1.1/1.1.2/1.1.1")) < 0, "order section");
    ok(PhextCoord.compare(C("2.1.1/1.1.1/1.1.1"), C("1.9.9/9.9.9/9.9.9")) > 0, "order library");
    bool threw = false;
    try { PhextCoord.parse("0.1.1/1.1.1/1.1.1"); } catch (Error e) { threw = true; }
    ok(threw, "coord rejects 0");
    threw = false;
    try { PhextCoord.parse("1.1/1.1.1/1.1.1"); } catch (Error e) { threw = true; }
    ok(threw, "coord rejects short");

    var sc = Phext.phokenize(B("hello"));
    ok(sc.length == 1, "one scroll");
    ok(sc[0].coord.to_string() == "1.1.1/1.1.1/1.1.1", "first coord");
    okb(sc[0].text, B("hello"), "first text");
    sc = Phext.phokenize(B("a"+BR7+"b"+BR7+""+BR7+"c\nline2"));
    ok(sc.length == 3, "scroll breaks");
    ok(sc[1].coord.to_string() == "1.1.1/1.1.1/1.1.2", "second coord");
    ok(sc[2].coord.to_string() == "1.1.1/1.1.1/1.1.4", "gap coord advance");
    okb(sc[2].text, B("c\nline2"), "newline is ordinary text");
    sc = Phext.phokenize(B("x"+BR0+"y"));
    ok(sc[1].coord.to_string() == "2.1.1/1.1.1/1.1.1", "library break resets");
    sc = Phext.phokenize(B("x"+BR8+"y"));
    ok(sc[1].coord.to_string() == "1.1.1/1.1.1/1.2.1", "section break");
    ok(Phext.phokenize(B("")).length == 0, "empty buffer");
    sc = Phext.phokenize({0x61, 0x00, 0xFF, 0x62});
    ok(sc.length == 1 && sc[0].text.length == 4, "binary text preserved");

    var sample = B("alpha"+BR7+"beta"+BR8+"gamma"+BR0+"delta");
    okb(Phext.dephokenize(Phext.phokenize(sample)), sample, "round trip sample");
    PositionedScroll[] pair = {
        new PositionedScroll(C("1.1.1/1.1.1/1.1.2"), B("two")),
        new PositionedScroll(C("1.1.1/1.1.1/1.1.1"), B("one"))
    };
    okb(Phext.dephokenize(pair), B("one"+BR7+"two"), "dephokenize sorts canonically");
    okb(Phext.normalize(Phext.normalize(B(""+BR7+""+BR7+"lead"))),
        Phext.normalize(B(""+BR7+""+BR7+"lead")), "normalize idempotent");

    var buf = B("one"+BR7+"two"+BR7+""+BR7+"four");
    okb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.1")), B("one"), "fetch 1");
    okb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.4")), B("four"), "fetch 4");
    okb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.3")), B(""), "gap fetch is empty");
    okb(Phext.fetch(buf, C("9.9.9/9.9.9/9.9.9")), B(""), "far gap fetch is empty");
    okb(Phext.fetch(B(""), C("1.1.1/1.1.1/1.1.1")), B(""), "fetch empty buffer");

    var res = Phext.insert(B("base"), C("1.1.1/1.1.1/1.1.1"), B("+more"));
    okb(Phext.fetch(res, C("1.1.1/1.1.1/1.1.1")), B("base+more"), "insert appends after existing");
    res = Phext.insert(B(""), C("1.1.1/1.1.1/1.1.3"), B("new"));
    okb(Phext.fetch(res, C("1.1.1/1.1.1/1.1.3")), B("new"), "insert creates at gap");
    okb(res, B(""+BR7+""+BR7+"new"), "insert at gap emits breaks");
    res = Phext.insert(B("a"+BR7+"c"), C("1.1.1/1.1.1/1.1.2"), B("b"));
    okb(Phext.fetch(res, C("1.1.1/1.1.1/1.1.2")), B("cb"), "insert merges existing + inserted");

    res = Phext.replace(B("old"+BR7+"keep"), C("1.1.1/1.1.1/1.1.1"), B("new"));
    okb(res, B("new"+BR7+"keep"), "replace overwrites");
    res = Phext.replace(B("a"), C("1.1.1/1.1.1/1.1.5"), B("deep"));
    okb(Phext.fetch(res, C("1.1.1/1.1.1/1.1.5")), B("deep"), "replace creates");
    res = Phext.remove(B("a"+BR7+"b"+BR7+"c"), C("1.1.1/1.1.1/1.1.2"));
    okb(res, B("a"+BR7+""+BR7+"c"), "remove leaves a gap (no renumbering)");
    okb(Phext.fetch(res, C("1.1.1/1.1.1/1.1.2")), B(""), "removed coordinate reads empty");
    okb(Phext.fetch(res, C("1.1.1/1.1.1/1.1.3")), B("c"), "neighbour keeps its coordinate");
    ok(Phext.remove(B("only"), C("1.1.1/1.1.1/1.1.1")).length == 0, "remove sole scroll");
    okb(Phext.remove(B("a"), C("5.5.5/5.5.5/5.5.5")), B("a"), "remove gap is a no-op");

    var map = Phext.explode(B("x"+BR7+"y"));
    ok(map.size() == 2, "explode count");
    okb(Phext.implode(map), B("x"+BR7+"y"), "implode round trip");

    var dyn = new DynamicPhext();
    var trn = new TransitivePhext();
    uint8[] str_buf = {};
    string[,] steps = {
        {"insert", "1.1.1/1.1.1/1.1.1", "alpha"},
        {"insert", "1.1.1/1.1.1/1.1.3", "gamma"},
        {"insert", "1.1.1/1.1.1/1.1.2", "beta"},
        {"insert", "1.1.1/1.1.1/1.1.2", "+"},
        {"replace", "2.1.1/1.1.1/1.1.1", "lib2"},
        {"remove", "1.1.1/1.1.1/1.1.3", ""},
        {"insert", "1.1.1/1.1.1/1.1.1", ""},
        {"replace", "1.1.1/1.1.1/1.1.1", ""}
    };
    for (int i = 0; i < steps.length[0]; i++) {
        var op = steps[i, 0]; var cs = steps[i, 1]; var tx = steps[i, 2];
        var cc = C(cs); var t = B(tx);
        if (op == "insert") { str_buf = Phext.insert(str_buf, cc, t); dyn.insert(cc, t); trn.insert(cc, t); }
        else if (op == "replace") { str_buf = Phext.replace(str_buf, cc, t); dyn.replace(cc, t); trn.replace(cc, t); }
        else { str_buf = Phext.remove(str_buf, cc); dyn.remove(cc); trn.remove(cc); }
        okb(dyn.serialize(), str_buf, "dynamic == string after op");
        okb(trn.serialize(), str_buf, "transitive == string after op");
        okb(dyn.fetch(cc), Phext.fetch(str_buf, cc), "dynamic fetch after op");
        okb(trn.fetch(cc), Phext.fetch(str_buf, cc), "transitive fetch after op");
    }
    okb(dyn.fetch(C("1.1.1/1.1.1/1.1.3")), B(""), "dynamic removed coord is gap");
    okb(trn.fetch(C("1.1.1/1.1.1/1.1.3")), B(""), "transitive removed coord is gap");
    okb(dyn.fetch(C("2.1.1/1.1.1/1.1.1")), B("lib2"), "dynamic neighbour unmoved");
    okb(trn.fetch(C("2.1.1/1.1.1/1.1.1")), B("lib2"), "transitive neighbour unmoved");
    ok(dyn.length == trn.length, "store lengths agree");

    var cap = new DynamicPhext();
    for (int i = 1; i <= 64; i++) {
        var cc = new PhextCoord(); cc.v[8] = i;
        cap.append(cc, B("s"));
    }
    ok(cap.capacity == 64, "capacity doubles to fit 64");
    ok(cap.resize_count <= 7, "resize count is logarithmic");

    if (args.length > 1) {
        string[] files = collect_fixtures(args[1]);
        int identical = 0, idem = 0;
        foreach (var path in files) {
            uint8[] data;
            try { FileUtils.get_data(path, out data); } catch (Error e) { continue; }
            if (eqb(Phext.dephokenize(Phext.phokenize(data)), data)) identical++;
            var n1 = Phext.normalize(data);
            if (eqb(Phext.normalize(n1), n1)) idem++;
        }
        stdout.printf("fixtures: %d input.phext, %d byte-identical round-trips, %d normalize-idempotent\n",
                      files.length, identical, idem);
        ok(files.length == 16, "16 fixtures found");
        ok(identical == files.length, "fixtures byte-identical round-trips");
        ok(idem == files.length, "all fixtures normalize idempotently");
    } else {
        stdout.printf("fixtures: skipped (no fixtures dir)\n");
    }

    stdout.printf("vala suite: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
