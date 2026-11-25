// Test suite for libphext-scala — plain assertions, no framework.
// Run: scala run / java -cp <classes> phext.TestPhext [fixtures_dir]
package phext

import java.nio.file.{Files, Paths}
import scala.jdk.CollectionConverters.*

object TestPhext:
  var failures = 0
  var checks = 0

  def ok(cond: Boolean, name: String): Unit =
    checks += 1
    if !cond then
      failures += 1
      System.err.println(s"FAIL: $name")

  def eq[A](a: A, b: A, name: String): Unit = ok(a == b, name)
  def eqb(a: Array[Byte], b: Array[Byte], name: String): Unit =
    ok(a.sameElements(b), name)

  def B(s: String): Array[Byte] = s.getBytes("ISO-8859-1")
  def C(s: String): Phext.Coord = Phext.coordParse(s)

  def main(args: Array[String]): Unit =
    // coordinate
    eq(Phext.coordString(C("1.2.3/4.5.6/7.8.9")), "1.2.3/4.5.6/7.8.9", "coord format")
    ok(Phext.coordCompare(C("1.1.1/1.1.1/1.1.1"), C("1.1.1/1.1.1/1.1.2")) < 0, "order scroll")
    ok(Phext.coordCompare(C("1.1.1/1.1.1/1.1.9"), C("1.1.1/1.1.2/1.1.1")) < 0, "order section")
    ok(Phext.coordCompare(C("2.1.1/1.1.1/1.1.1"), C("1.9.9/9.9.9/9.9.9")) > 0, "order library")
    eq(C("1.1.1/1.1.1/1.1.1"), Phext.coordRoot, "root")
    ok(try { C("0.1.1/1.1.1/1.1.1"); false } catch { case _: Exception => true }, "coord rejects 0")
    ok(try { C("1.1/1.1.1/1.1.1"); false } catch { case _: Exception => true }, "coord rejects short")

    // phokenize
    var sc = Phext.phokenize(B("hello"))
    eq(sc.length, 1, "one scroll")
    eq(Phext.coordString(sc(0).coord), "1.1.1/1.1.1/1.1.1", "first coord")
    eqb(sc(0).text, B("hello"), "first text")
    sc = Phext.phokenize(B("a\u0017b\u0017\u0017c\nline2"))
    eq(sc.length, 3, "scroll breaks")
    eq(Phext.coordString(sc(1).coord), "1.1.1/1.1.1/1.1.2", "second coord")
    eq(Phext.coordString(sc(2).coord), "1.1.1/1.1.1/1.1.4", "gap coord advance")
    eqb(sc(2).text, B("c\nline2"), "newline is ordinary text")
    sc = Phext.phokenize(B("x\u0001y"))
    eq(Phext.coordString(sc(1).coord), "2.1.1/1.1.1/1.1.1", "library break resets")
    sc = Phext.phokenize(B("x\u0018y"))
    eq(Phext.coordString(sc(1).coord), "1.1.1/1.1.1/1.2.1", "section break")
    eq(Phext.phokenize(B("")).length, 0, "empty buffer")
    sc = Phext.phokenize(Array(0x61, 0x00, 0xff, 0x62).map(_.toByte))
    eq(sc.length, 1, "binary text is one scroll")
    eq(sc(0).text.length, 4, "binary text preserved")

    // round trip
    val sample = B("alpha\u0017beta\u0018gamma\u0001delta")
    eqb(Phext.dephokenize(Phext.phokenize(sample)), sample, "round trip sample")
    val built = Phext.dephokenize(List(
      Phext.PositionedScroll(C("1.1.1/1.1.1/1.1.2"), B("two")),
      Phext.PositionedScroll(C("1.1.1/1.1.1/1.1.1"), B("one"))))
    eqb(built, B("one\u0017two"), "dephokenize sorts canonically")
    eqb(Phext.normalize(Phext.normalize(B("\u0017\u0017lead"))),
        Phext.normalize(B("\u0017\u0017lead")), "normalize idempotent")

    // fetch incl. gaps
    val buf = B("one\u0017two\u0017\u0017four")
    eqb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.1")), B("one"), "fetch 1")
    eqb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.4")), B("four"), "fetch 4")
    eqb(Phext.fetch(buf, C("1.1.1/1.1.1/1.1.3")), B(""), "gap fetch is empty")
    eqb(Phext.fetch(buf, C("9.9.9/9.9.9/9.9.9")), B(""), "far gap fetch is empty")
    eqb(Phext.fetch(B(""), C("1.1.1/1.1.1/1.1.1")), B(""), "fetch empty buffer")

    // insert
    var out = Phext.insert(B("base"), C("1.1.1/1.1.1/1.1.1"), B("+more"))
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
    val map = Phext.explode(B("x\u0017y"))
    eq(map.size, 2, "explode count")
    eqb(Phext.implode(map), B("x\u0017y"), "implode round trip")

    // Dynamic + Transitive equivalence with the string path
    val dyn = new DynamicPhext()
    val trn = new TransitivePhext()
    var strBuf = B("")
    def step(op: String, coord: String, text: String): Unit =
      val c = C(coord)
      val t = B(text)
      op match
        case "insert" =>
          strBuf = Phext.insert(strBuf, c, t); dyn.insert(c, t); trn.insert(c, t)
        case "replace" =>
          strBuf = Phext.replace(strBuf, c, t); dyn.replace(c, t); trn.replace(c, t)
        case "remove" =>
          strBuf = Phext.remove(strBuf, c); dyn.remove(c); trn.remove(c)
      eqb(dyn.serialize(), strBuf, s"dynamic == string after $op $coord")
      eqb(trn.serialize(), strBuf, s"transitive == string after $op $coord")
      eqb(dyn.fetch(c), Phext.fetch(strBuf, c), "dynamic fetch after op")
      eqb(trn.fetch(c), Phext.fetch(strBuf, c), "transitive fetch after op")
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
    eq(dyn.length, trn.length, "store lengths agree")

    // DynamicPhext capacity discipline
    val cap = new DynamicPhext()
    for i <- 1 to 64 do cap.append(Vector(1, 1, 1, 1, 1, 1, 1, 1, i), B("s"))
    eq(cap.capacity, 64, "capacity doubles to fit 64")
    ok(cap.resizeCount <= 7, "resize count is logarithmic")

    // fixtures
    if args.nonEmpty then
      var files = 0
      var identical = 0
      var idem = 0
      val stream = Files.walk(Paths.get(args(0)))
      try
        for p <- stream.iterator().asScala do
          if p.getFileName.toString == "input.phext" then
            files += 1
            val data = Files.readAllBytes(p)
            if Phext.dephokenize(Phext.phokenize(data)).sameElements(data) then
              identical += 1
            val n1 = Phext.normalize(data)
            if Phext.normalize(n1).sameElements(n1) then idem += 1
      finally stream.close()
      println(s"fixtures: $files input.phext, $identical byte-identical round-trips, $idem normalize-idempotent")
      eq(files, 16, "16 fixtures found")
      eq(identical, files, "fixtures byte-identical round-trips")
      eq(idem, files, "all fixtures normalize idempotently")
    else
      println("fixtures: skipped (no fixtures dir)")

    println(s"scala suite: $checks checks, $failures failures")
    System.exit(if failures == 0 then 0 else 1)
