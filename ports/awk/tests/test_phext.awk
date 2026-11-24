# test_phext.awk -- unit + conformance tests for the gawk libphext port.
# Run on the hub:  LC_ALL=C gawk -f src/phext.awk -f tests/test_phext.awk
# Fixtures: set PHEXT_FIXTURES to harness/fixtures; the 16 input.phext
# paths are passed as arguments by the runner script (run_tests.sh).
BEGIN {
    FAILURES = 0
    C1 = "1,1,1,1,1,1,1,1,1"
    check(coord_str(coord_parse("2.3.4/5.6.7/8.9.10")) == "2.3.4/5.6.7/8.9.10", "coord round-trip")
    check(coord_cmp(coord_parse("1.1.1/1.1.1/1.1.2"), coord_parse("1.1.1/1.1.1/1.1.10")) < 0, "coord order")
    check(coord_parse("1.1.1/1.1.1/1.1.0") == "", "coord rejects 0")
    check(coord_parse("1.1.1/1.1.1") == "", "coord rejects short")

    sb = sprintf("%c", 23); sc = sprintf("%c", 24)
    buf = "alpha" sb "beta" sc "gamma"
    check(fetch(buf, coord_parse("1.1.1/1.1.1/1.1.1")) == "alpha", "fetch first")
    check(fetch(buf, coord_parse("1.1.1/1.1.1/1.1.2")) == "beta", "fetch scroll 2")
    check(fetch(buf, coord_parse("1.1.1/1.1.1/1.2.1")) == "gamma", "fetch section 2 scroll 1")
    check(fetch(buf, coord_parse("1.1.1/1.1.1/1.1.9")) == "", "fetch gap is empty")
    check(normalize(buf) == buf, "normalize idempotent on canonical")

    b2 = insert("", coord_parse("1.1.1/1.1.1/1.1.2"), "second")
    check(fetch(b2, coord_parse("1.1.1/1.1.1/1.1.2")) == "second", "insert creates")
    b2 = insert(b2, coord_parse("1.1.1/1.1.1/1.1.2"), "+more")
    check(fetch(b2, coord_parse("1.1.1/1.1.1/1.1.2")) == "second+more", "insert concatenates")
    b2 = replace(b2, coord_parse("1.1.1/1.1.1/1.1.2"), "replaced")
    check(fetch(b2, coord_parse("1.1.1/1.1.1/1.1.2")) == "replaced", "replace overwrites")

    b3 = "one" sb "two" sb "three"
    b3r = remove(b3, coord_parse("1.1.1/1.1.1/1.1.2"))
    check(fetch(b3r, coord_parse("1.1.1/1.1.1/1.1.1")) == "one", "remove keeps first")
    check(fetch(b3r, coord_parse("1.1.1/1.1.1/1.1.2")) == "", "remove empties target")
    check(fetch(b3r, coord_parse("1.1.1/1.1.1/1.1.3")) == "three", "remove does not shift later scrolls")

    gap = insert("", coord_parse("3.1.4/1.5.9/2.6.5"), "far")
    explode(gap)
    check(implode() == gap, "explode/implode gap round-trip")

    # Dynamic + Transitive equivalence over an edit sequence
    ncoords = split("1.1.1/1.1.1/1.1.1 1.1.1/1.1.1/1.1.2 1.1.1/1.1.1/1.2.1 2.1.1/1.1.1/1.1.1 1.1.1/1.1.1/1.1.3", coordstrs, " ")
    dyn_init(""); trn_init("")
    buf2 = ""
    for (i = 1; i <= ncoords; i++) {
        c = coord_parse(coordstrs[i])
        buf2 = insert(buf2, c, "text" i)
        dyn_insert(c, "text" i)
        trn_insert(c, "text" i)
        check(dyn_serialize() == buf2, "dynamic == buffer after insert " i)
        check(trn_serialize() == buf2, "transitive == buffer after insert " i)
    }
    mid = coord_parse("1.1.1/1.1.1/1.1.2")
    buf2 = remove(buf2, mid)
    dyn_remove(mid); trn_remove(mid)
    check(dyn_serialize() == buf2, "dynamic == buffer after remove")
    check(trn_serialize() == buf2, "transitive == buffer after remove")
    check(dyn_fetch(mid) == "" && trn_fetch(mid) == "", "stores fetch removed as empty")
    check(DYN_N == 4 && TRN_N == 4, "store lengths")
    dyn_replace(coord_parse("1.1.1/1.1.1/1.1.1"), "")
    buf2 = remove(buf2, coord_parse("1.1.1/1.1.1/1.1.1"))
    check(dyn_serialize() == buf2, "dynamic replace-empty removes")

    # fixtures: file paths come in ARGV (runner passes all 16)
    nfx = 0; okc = 0
    for (ai = 1; ai < ARGC; ai++) {
        path = ARGV[ai]
        if (path == "") continue
        nfx++
        data = read_whole_file(path)
        explode(data)
        if (implode() == data && normalize(normalize(data)) == normalize(data)) okc++
        else print "FAIL - fixture round-trip: " path
    }
    if (nfx > 0) {
        check(nfx == 16, "found 16 fixture inputs (got " nfx ")")
        check(okc == 16, "fixtures round-trip " okc "/16")
        if (okc != 16) FAILURES++
    } else {
        print "skip - no fixture files passed (fixtures check skipped)"
    }

    print (FAILURES ? "FAILURES: " FAILURES : "PASS")
    exit (FAILURES ? 1 : 0)
}
function check(cond, name) {
    if (cond) print "ok - " name
    else { print "FAIL - " name; FAILURES++ }
}
function read_whole_file(path,    oldrs, data) {
    # NUL never occurs in phext data, so RS=NUL reads the file whole.
    oldrs = RS
    RS = "\0"
    data = ""
    if ((getline data < path) < 0) data = ""
    close(path)
    RS = oldrs
    return data
}
