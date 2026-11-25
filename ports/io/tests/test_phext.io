// Native test suite for the Io libphext port. Run via
// tests/run_tests.sh on the hub (needs the io binary + fixtures).
// Args: argv 1 = fixtures dir (contains chains/ and ranges/).

doFile(Path with("src/phext.io"))

checks := 0
failures := 0
ok := method(cond, name,
    checks = checks + 1
    if(cond not,
        failures = failures + 1
        writeln("FAIL: ", name)
    )
)
eqs := method(a, b, name, ok(a == b, name))
eqi := method(a, b, name, ok(a == b, name))

c9 := method(s, PhextLib parseCoord(s))
SB := Sequence clone append(23)
SEC := Sequence clone append(24)
LIB := Sequence clone append(1)
ex1 := "a" .. SB .. "b" .. SB .. SB .. "c\nline2"

// phokenize / dephokenize
entries := PhextLib phokenize(ex1)
eqi(entries size, 3, "phokenize scroll count")
eqs(PhextLib coordString(entries at(0) at(0)), "1.1.1/1.1.1/1.1.1", "first coord")
eqs(entries at(0) at(1), "a", "first text")
eqs(PhextLib coordString(entries at(1) at(0)), "1.1.1/1.1.1/1.1.2", "second coord")
eqs(PhextLib coordString(entries at(2) at(0)), "1.1.1/1.1.1/1.1.4", "third coord jumps the gap")
eqs(entries at(2) at(1), "c\nline2", "newline is ordinary text")
eqs(PhextLib dephokenize(PhextLib phokenize(ex1)), ex1, "round trip ex1")
eqs(PhextLib normalize(ex1), ex1, "normalize ex1")
eqi((PhextLib phokenize("hello")) size, 1, "phokenize plain")
eqs(PhextLib fetch("hello", c9("1.1.1/1.1.1/1.1.1")), "hello", "fetch root")
eqi((PhextLib phokenize("")) size, 0, "phokenize empty")
eqs(PhextLib dephokenize(list()), "", "dephokenize empty")
entries2 := PhextLib phokenize("a" .. SEC .. "b")
eqs(PhextLib coordString(entries2 at(1) at(0)), "1.1.1/1.1.1/1.2.1", "section advance")
eqs(PhextLib dephokenize(entries2), "a" .. SEC .. "b", "round trip section")
entries3 := PhextLib phokenize("x" .. LIB .. "y")
eqs(PhextLib coordString(entries3 at(1) at(0)), "2.1.1/1.1.1/1.1.1", "library advance")

// fetch: the gap reads as "", neighbours unaffected
eqs(PhextLib fetch(ex1, c9("1.1.1/1.1.1/1.1.3")), "", "fetch gap is empty")
eqs(PhextLib fetch(ex1, c9("1.1.1/1.1.1/1.1.4")), "c\nline2", "fetch after gap")
eqs(PhextLib fetch(ex1, c9("9.9.9/9.9.9/9.9.9")), "", "fetch missing")

// insert: existing text is prepended
s := PhextLib insert("base", c9("1.1.1/1.1.1/1.1.1"), "-plus")
eqs(PhextLib fetch(s, c9("1.1.1/1.1.1/1.1.1")), "base-plus", "insert prepends existing")
s2 := PhextLib insert("base", c9("1.1.1/1.1.1/1.1.2"), "new")
eqs(PhextLib fetch(s2, c9("1.1.1/1.1.1/1.1.2")), "new", "insert new coordinate")
eqs(PhextLib fetch(s2, c9("1.1.1/1.1.1/1.1.1")), "base", "insert leaves neighbour")

// replace
s3 := PhextLib replace("base", c9("1.1.1/1.1.1/1.1.1"), "repl")
eqs(PhextLib fetch(s3, c9("1.1.1/1.1.1/1.1.1")), "repl", "replace overwrites")

// remove is coordinate-preserving (explicit)
s4 := PhextLib remove(ex1, c9("1.1.1/1.1.1/1.1.2"))
eqs(PhextLib fetch(s4, c9("1.1.1/1.1.1/1.1.2")), "", "removed coordinate reads empty")
eqs(PhextLib fetch(s4, c9("1.1.1/1.1.1/1.1.4")), "c\nline2", "remove does not renumber neighbours")
eqs(PhextLib fetch(s4, c9("1.1.1/1.1.1/1.1.1")), "a", "remove leaves earlier scroll")
eqs(PhextLib remove("hello", c9("1.1.1/1.1.1/1.1.1")), "", "remove sole scroll")

// explode / implode
eqs(PhextLib explode("a" .. LIB .. "b") join("|"), "a|b", "explode")
eqs(PhextLib implode(list("a", "b")), "a" .. LIB .. "b" .. LIB, "implode")

// dynamic + transitive equivalence over the same op sequence
root := c9("1.1.1/1.1.1/1.1.1")
step := method(d, t, op, coord, text,
    if(op == "insert", d insert(coord, text); t insert(coord, text))
    if(op == "replace", d replace(coord, text); t replace(coord, text))
    if(op == "remove", d remove(coord); t remove(coord))
    eqs(d serialize, t serialize, "stores agree after " .. op)
    eqs(d fetch(coord), t fetch(coord), "fetch agrees after " .. op)
)
d := DynamicPhext clone initWith("", 4)
t := TransitivePhext clone initWith("")
step(d, t, "insert", root, "alpha")
step(d, t, "insert", c9("1.2.3/1.1.1/1.1.1"), "beta")
step(d, t, "insert", root, "-more")
eqs(d fetch(root), "alpha-more", "dynamic insert prepends")
step(d, t, "replace", root, "final")
step(d, t, "remove", c9("1.2.3/1.1.1/1.1.1"), nil)
eqs(d serialize, "final", "dynamic final state")
eqi(d len, t len, "store lengths agree")

// transitive snapshot isolation (persistence)
t2 := TransitivePhext clone initWith("")
t2 insert(root, "v1")
snap := t2 snapshot
t2 replace(root, "v2")
eqs(snap fetch(root), "v1", "snapshot keeps old version")
eqs(t2 fetch(root), "v2", "updated store moves on")

// dynamic capacity: start 1, double on append, shrink at quarter
d2 := DynamicPhext clone initWith("", 4)
for(i, 1, 64, d2 append(c9("1.1." .. i asString .. "/1.1.1/1.1.1"), "x"))
eqi(d2 capacity, 64, "capacity doubles to fit 64")
ok(d2 resizeCount <= 7, "resize count is logarithmic")

// fixtures: 16 input.phext byte-identical round-trips; the
// driver (tests/run_tests.sh) writes the fixture paths, one per
// line, to /tmp/io-fixtures.txt
paths := List clone
listData := File with("/tmp/io-fixtures.txt") openForReading readToEnd
File with("/tmp/io-fixtures.txt") close
listData split("\n") foreach(line,
    trimmed := line strip
    if(trimmed size > 0, paths append(trimmed))
)
total := 0; identical := 0; idem := 0
paths sort foreach(p,
    data := File with(p) openForReading readToEnd
    File with(p) close
    total = total + 1
    if(PhextLib normalize(data) == data, identical = identical + 1)
    n1 := PhextLib normalize(data)
    if(PhextLib normalize(n1) == n1, idem = idem + 1)
)
writeln("fixtures: ", total, " input.phext, ", identical, " byte-identical round-trips, ", idem, " normalize-idempotent")
eqi(total, 16, "16 fixtures found")
eqi(identical, total, "fixtures byte-identical round-trips")
eqi(idem, total, "all fixtures normalize idempotently")

writeln("io suite: ", checks, " checks, ", failures, " failures")
if(failures > 0, System exit(1))
