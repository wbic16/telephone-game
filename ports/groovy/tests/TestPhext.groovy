// Test suite for libphext-groovy — plain assertions, no framework.
// Run: phext.TestPhext [fixtures_dir]
package phext

import java.nio.file.*
import java.util.stream.Collectors

class TestPhext {
    static int checks = 0
    static int failures = 0

    static void ok(boolean cond, String name) {
        checks++
        if (!cond) {
            failures++
            System.err.println("FAIL: " + name)
        }
    }

    static void eq(Object a, Object b, String name) { ok(a == b, name) }
    static void eqb(byte[] a, byte[] b, String name) { ok(Arrays.equals(a, b), name) }
    static byte[] B(String s) { s.getBytes("ISO-8859-1") }
    static boolean throws_(Closure c) {
        try { c.call(); return false } catch (Exception e) { return true }
    }
    static Coord C(String s) { Phext.coordParse(s) }

    static void main(String[] args) {
        // coordinate
        eq(Phext.coordString(C("1.2.3/4.5.6/7.8.9")), "1.2.3/4.5.6/7.8.9", "coord format")
        ok(C("1.1.1/1.1.1/1.1.1").compareTo(C("1.1.1/1.1.1/1.1.2")) < 0, "order scroll")
        ok(C("1.1.1/1.1.1/1.1.9").compareTo(C("1.1.1/1.1.2/1.1.1")) < 0, "order section")
        ok(C("2.1.1/1.1.1/1.1.1").compareTo(C("1.9.9/9.9.9/9.9.9")) > 0, "order library")
        eq(C("1.1.1/1.1.1/1.1.1"), Phext.coordRoot(), "root")
        ok(throws_ { C("0.1.1/1.1.1/1.1.1") }, "coord rejects 0")
        ok(throws_ { C("1.1/1.1.1/1.1.1") }, "coord rejects short")

        // phokenize
        List<PositionedScroll> sc = Phext.phokenize(B("hello"))
        eq(sc.size(), 1, "one scroll")
        eq(Phext.coordString(sc[0].coord), "1.1.1/1.1.1/1.1.1", "first coord")
        eqb(sc[0].text, B("hello"), "first text")
        sc = Phext.phokenize(B("a\u0017b\u0017\u0017c\nline2"))
        eq(sc.size(), 3, "scroll breaks")
        eq(Phext.coordString(sc[1].coord), "1.1.1/1.1.1/1.1.2", "second coord")
        eq(Phext.coordString(sc[2].coord), "1.1.1/1.1.1/1.1.4", "gap coord advance")
        eqb(sc[2].text, B("c\nline2"), "newline is ordinary text")
        sc = Phext.phokenize(B("x\u0001y"))
        eq(Phext.coordString(sc[1].coord), "2.1.1/1.1.1/1.1.1", "library break resets")
        sc = Phext.phokenize(B("x\u0018y"))
        eq(Phext.coordString(sc[1].coord), "1.1.1/1.1.1/1.2.1", "section break")
        eq(Phext.phokenize(B("")).size(), 0, "empty buffer")
        sc = Phext.phokenize([0x61, 0x00, 0xFF, 0x62] as byte[])
        eq(sc.size(), 1, "binary text is one scroll")
        eq(sc[0].text.length, 4, "binary text preserved")

        // round trip
        byte[] sample = B("alpha\u0017beta\u0018gamma\u0001delta")
        eqb(Phext.dephokenize(Phext.phokenize(sample)), sample, "round trip sample")
        byte[] built = Phext.dephokenize([
            new PositionedScroll(C("1.1.1/1.1.1/1.1.2"), B("two")),
            new PositionedScroll(C("1.1.1/1.1.1/1.1.1"), B("one"))])
        eqb(built, B("one\u0017two"), "dephokenize sorts canonically")
        eqb(Phext.normalize(Phext.normalize(B("\u0017\u0017lead"))),
            Phext.normalize(B("\u0017\u0017lead")), "normalize idempotent")

        // fetch incl. gaps
        byte[] buf = B("one\u0017two\u0017\u0017four")
        eqb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.1")), B("one"), "fetch 1")
        eqb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.4")), B("four"), "fetch 4")
        eqb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.3")), B(""), "gap fetch is empty")
        eqb(Phext.fetch(buf, C("9.9.9/9.9.9/9.9.9")), B(""), "far gap fetch is empty")
        eqb(Phext.fetch(B(""), C("1.1.1/1.1.1/1.1.1")), B(""), "fetch empty buffer")

        // insert
        byte[] out = Phext.insert(B("base"), C("1.1.1/1.1.1/1.1.1"), B("+more"))
        eqb(Phext.fetch(out, C("1.1.1/1.1.1/1.1.1")), B("base+more"), "insert appends after existing")
        out = Phext.insert(B(""), C("1.1.1/1.1.1/1.1.3"), B("new"))
        eqb(Phext.fetch(out, C("1.1.1/1.1.1/1.1.3")), B("new"), "insert creates at gap")
        eqb(out, B("\u0017\u0017new"), "insert at gap emits breaks")
        out = Phext.insert(B("a\u0017c"), C("1.1.1/1.1.1/1.1.2"), B("b"))
        eqb(Phext.fetch(out, C("1.1.1/1.1.1/1.1.2")), B("cb"), "insert merges existing + inserted")

        // replace / remove — remove is coordinate-preserving
        out = Phext.replace(B("old\u0017keep"), C("1.1.1/1.1.1/1.1.1"), B("new"))
        eqb(out, B("new\u0017keep"), "replace overwrites")
        out = Phext.replace(B("a"), C("1.1.1/1.1.1/1.1.5"), B("deep"))
        eqb(Phext.fetch(out, C("1.1.1/1.1.1/1.1.5")), B("deep"), "replace creates")
        out = Phext.remove(B("a\u0017b\u0017c"), C("1.1.1/1.1.1/1.1.2"))
        eqb(out, B("a\u0017\u0017c"), "remove leaves a gap (no renumbering)")
        eqb(Phext.fetch(out, C("1.1.1/1.1.1/1.1.2")), B(""), "removed coordinate reads empty")
        eqb(Phext.fetch(out, C("1.1.1/1.1.1/1.1.3")), B("c"), "neighbour keeps its coordinate")
        eq(Phext.remove(B("only"), C("1.1.1/1.1.1/1.1.1")).length, 0, "remove sole scroll")
        eqb(Phext.remove(B("a"), C("5.5.5/5.5.5/5.5.5")), B("a"), "remove gap is a no-op")

        // explode / implode
        Map<Coord, byte[]> map = Phext.explode(B("x\u0017y"))
        eq(map.size(), 2, "explode count")
        eqb(Phext.implode(map), B("x\u0017y"), "implode round trip")

        // Dynamic + Transitive equivalence with the string path
        DynamicPhext dyn = new DynamicPhext()
        TransitivePhext trn = new TransitivePhext()
        byte[] strBuf = B("")
        Closure step = { String op, String coord, String text ->
            Coord c = C(coord)
            byte[] t = B(text)
            switch (op) {
                case "insert":
                    strBuf = Phext.insert(strBuf, c, t); dyn.insert(c, t); trn.insert(c, t); break
                case "replace":
                    strBuf = Phext.replace(strBuf, c, t); dyn.replace(c, t); trn.replace(c, t); break
                case "remove":
                    strBuf = Phext.remove(strBuf, c); dyn.remove(c); trn.remove(c); break
            }
            eqb(dyn.serialize(), strBuf, "dynamic == string after " + op + " " + coord)
            eqb(trn.serialize(), strBuf, "transitive == string after " + op + " " + coord)
            eqb(dyn.fetch(c), Phext.fetch(strBuf, c), "dynamic fetch after op")
            eqb(trn.fetch(c), Phext.fetch(strBuf, c), "transitive fetch after op")
        }
        step("insert", "1.1.1/1.1.1/1.1.1", "alpha")
        step("insert", "1.1.1/1.1.1/1.1.3", "gamma")
        step("insert", "1.1.1/1.1.1/1.1.2", "beta")
        step("insert", "1.1.1/1.1.1/1.1.2", "+")
        step("replace", "2.1.1/1.1.1/1.1.1", "lib2")
        step("remove", "1.1.1/1.1.1/1.1.3", "")
        eqb(dyn.fetch(C("1.1.1/1.1.1/1.1.3")), B(""), "dynamic removed coord is gap")
        eqb(trn.fetch(C("1.1.1/1.1.1/1.1.3")), B(""), "transitive removed coord is gap")
        eqb(dyn.fetch(C("2.1.1/1.1.1/1.1.1")), B("lib2"), "dynamic neighbour unmoved")
        eqb(trn.fetch(C("2.1.1/1.1.1/1.1.1")), B("lib2"), "transitive neighbour unmoved")
        step("insert", "1.1.1/1.1.1/1.1.1", "")
        step("replace", "1.1.1/1.1.1/1.1.1", "")
        eq(dyn.length(), trn.length(), "store lengths agree")

        // DynamicPhext capacity discipline
        DynamicPhext cap = new DynamicPhext()
        for (int i = 1; i <= 64; i++) cap.append(new Coord([1, 1, 1, 1, 1, 1, 1, 1, i] as long[]), B("s"))
        eq(cap.capacity, 64, "capacity doubles to fit 64")
        ok(cap.resizeCount <= 7, "resize count is logarithmic")

        // fixtures
        if (args.length > 0) {
            int files = 0, identical = 0, idem = 0
            List<Path> paths
            try (def stream = Files.walk(Paths.get(args[0]))) {
                paths = stream.filter { p -> p.getFileName().toString() == "input.phext" }
                              .collect(Collectors.toList())
            }
            for (Path p : paths) {
                files++
                byte[] data = Files.readAllBytes(p)
                if (Arrays.equals(Phext.dephokenize(Phext.phokenize(data)), data)) identical++
                byte[] n1 = Phext.normalize(data)
                if (Arrays.equals(Phext.normalize(n1), n1)) idem++
            }
            System.out.println("fixtures: " + files + " input.phext, " + identical +
                " byte-identical round-trips, " + idem + " normalize-idempotent")
            eq(files, 16, "16 fixtures found")
            eq(identical, files, "fixtures byte-identical round-trips")
            eq(idem, files, "all fixtures normalize idempotently")
        } else {
            System.out.println("fixtures: skipped (no fixtures dir)")
        }

        System.out.println("groovy suite: " + checks + " checks, " + failures + " failures")
        System.exit(failures == 0 ? 0 : 1)
    }
}
