## Test suite for the Nim libphext port. Run via tests/run_tests.sh:
## compiles and runs this file; fixtures via PHEXT_FIXTURES env.
import std/[os, strutils, tables]
import phext

var failures = 0
proc check(cond: bool, name: string) =
  if cond: echo "ok - " & name
  else:
    failures += 1
    echo "FAIL - " & name

proc coord(s: string): Coord =
  let (ok, c) = parseCoordinate(s)
  doAssert ok, "bad coord " & s
  return c

check(formatCoordinate(coord("1.2.3/4.5.6/7.8.9")) == "1.2.3/4.5.6/7.8.9", "coordinate round trip")
check(not parseCoordinate("0.1.1/1.1.1/1.1.1").ok, "coordinate rejects 0")
check(not parseCoordinate("1.1.1/1.1.1").ok, "coordinate rejects short")
check(cmpCoord(coord("1.1.1/1.1.1/1.1.9"), coord("1.1.1/1.1.2/1.1.1")) == -1, "order: section beats scroll")
check(cmpCoord(coord("2.1.1/1.1.1/1.1.1"), coord("10.1.1/1.1.1/1.1.1")) == -1, "order: numeric not string")

var buf = "a\x17b\x18c\x01d"
let scrolls = phokenize(buf)
var got: seq[string]
for ps in scrolls: got.add(formatCoordinate(ps.coord) & ":" & ps.text)
check(got.join(",") == "1.1.1/1.1.1/1.1.1:a,1.1.1/1.1.1/1.1.2:b,1.1.1/1.1.1/1.2.1:c,2.1.1/1.1.1/1.1.1:d", "phokenize breaks")
check(dephokenize(scrolls) == buf, "dephokenize round trip")
let s1 = phokenize("line1\nline2")
check(s1.len == 1 and s1[0].text == "line1\nline2", "newline is text")
check(fetch("hello", coord("1.1.1/1.1.1/1.1.2")) == "", "gap fetch is empty")
check(fetch("hello", coord("9.9.9/9.9.9/9.9.9")) == "", "far gap fetch is empty")
check(fetch("hello", coord("1.1.1/1.1.1/1.1.1")) == "hello", "fetch hit")
buf = insert("base", coord("1.1.1/1.1.1/1.1.1"), "+more")
check(fetch(buf, coord("1.1.1/1.1.1/1.1.1")) == "base+more", "insert merges existing+inserted")
buf = insert(buf, coord("1.1.1/1.1.1/1.1.3"), "third")
check(buf == "base+more\x17\x17third", "insert creates in canonical position")
buf = replace("a\x17b\x17c", coord("1.1.1/1.1.1/1.1.2"), "B")
check(buf == "a\x17B\x17c", "replace overwrites")
buf = remove(buf, coord("1.1.1/1.1.1/1.1.2"))
check(buf == "a\x17\x17c", "remove coordinate-preserving: c stays at scroll 3")
check(fetch(buf, coord("1.1.1/1.1.1/1.1.2")) == "", "fetch after remove is empty")
check(fetch(buf, coord("1.1.1/1.1.1/1.1.3")) == "c", "later scroll did NOT shift after remove")
check(remove(buf, coord("5.5.5/5.5.5/5.5.5")) == buf, "remove gap is no-op")
let m = explode("x\x17y\x01z")
check(m.len == 3 and implode(m) == "x\x17y\x01z", "explode/implode round trip")

type Op = tuple[kind, at, text: string]
let ops: seq[Op] = @[
  ("insert", "1.1.1/1.1.1/1.1.1", "+X"), ("insert", "1.1.1/1.1.1/1.1.3", "third"),
  ("replace", "1.1.1/1.1.1/1.1.2", "B"), ("remove", "1.1.1/1.1.1/1.1.1", ""),
  ("insert", "2.1.1/1.1.1/1.1.1", "lib2"), ("remove", "1.1.1/1.1.1/1.1.3", ""),
  ("replace", "9.9.9/9.9.9/9.9.9", "far"), ("insert", "1.1.1/1.1.1/1.1.2", "-tail")]

proc seqDynamic() =
  var store = newDynamicPhext("a\x17b")
  var refr = "a\x17b"
  for op in ops:
    let c = coord(op.at)
    case op.kind
    of "insert": store.insert(c, op.text); refr = insert(refr, c, op.text)
    of "replace": store.replace(c, op.text); refr = replace(refr, c, op.text)
    else: store.remove(c); refr = remove(refr, c)
    check(store.serialize() == phext.normalize(refr), "DynamicPhext serialize matches after " & op.kind & " " & op.at)
    check(store.fetch(c) == fetch(phext.normalize(refr), c), "DynamicPhext fetch matches after " & op.kind & " " & op.at)

proc seqTransitive() =
  var store = newTransitivePhext("a\x17b")
  var refr = "a\x17b"
  for op in ops:
    let c = coord(op.at)
    case op.kind
    of "insert": store.insert(c, op.text); refr = insert(refr, c, op.text)
    of "replace": store.replace(c, op.text); refr = replace(refr, c, op.text)
    else: store.remove(c); refr = remove(refr, c)
    check(store.serialize() == phext.normalize(refr), "TransitivePhext serialize matches after " & op.kind & " " & op.at)
    check(store.fetch(c) == fetch(phext.normalize(refr), c), "TransitivePhext fetch matches after " & op.kind & " " & op.at)

seqDynamic()
seqTransitive()
var d = newDynamicPhext()
for i in 1..20: d.append(coord("1.1.1/1.1.1/1.1." & $i), "s" & $i)
check(d.len == 20 and d.capacity >= 20 and d.capacity < 40, "DynamicPhext capacity doubling (cap=" & $d.capacity & ")")
for i in countdown(20, 6): d.remove(coord("1.1.1/1.1.1/1.1." & $i))
check(d.len == 5, "DynamicPhext removals")
check(newTransitivePhext().depth == 9, "TransitivePhext depth 9")

let dir = getEnv("PHEXT_FIXTURES")
if dir.len > 0:
  var count = 0
  var identical = 0
  for path in walkDirRec(dir):
    if path.extractFilename != "input.phext": continue
    let data = readFile(path)
    count += 1
    if dephokenize(phokenize(data)) == data: identical += 1
    let n1 = phext.normalize(data)
    check(phext.normalize(n1) == n1, "fixture normalize idempotent: " & path)
  check(count > 0, "fixtures found (" & $count & ")")
  check(identical >= count - 2, "fixtures byte-identical round-trips (" & $identical & "/" & $count & ")")
else:
  echo "skip - fixtures (PHEXT_FIXTURES not set)"

echo if failures == 0: "PASS" else: "FAILURES: " & $failures
quit(if failures == 0: 0 else: 1)
