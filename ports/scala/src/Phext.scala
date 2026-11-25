// libphext-scala — a Scala 3 port of libphext (0.6.1 parity).
//
// Semantics are normative from libphext-py: a phext is a byte buffer;
// nine dimension-break bytes walk a 9-component coordinate; scroll text
// is a maximal run of non-break bytes (newline 0x0A is ordinary text).
// All buffers are Array[Byte] so control bytes and arbitrary byte
// sequences are never reinterpreted. Coordinates are Vector[Int] of
// length 9, ordered lexicographically; string form a.b.c/d.e.f/g.h.i.
package phext

object Phext:
  // Dimension breaks in dimension order (library .. scroll).
  val DimensionBreaks: Array[Byte] =
    Array(0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17)

  def breakDim(b: Byte): Int = DimensionBreaks.indexOf(b)

  type Coord = Vector[Int]

  def coordRoot: Coord = Vector.fill(9)(1)

  def coordParse(s: String): Coord =
    val groups = s.trim.split("/")
    require(groups.length == 3, s"coordinate must be a.b.c/d.e.f/g.h.i: $s")
    val nums = groups.flatMap(_.split("\\.").map(_.toInt)).toVector
    require(nums.length == 9, s"coordinate needs 9 parts: $s")
    require(nums.forall(_ >= 1), s"components must be >= 1: $s")
    nums

  def coordString(c: Coord): String =
    s"${c(0)}.${c(1)}.${c(2)}/${c(3)}.${c(4)}.${c(5)}/${c(6)}.${c(7)}.${c(8)}"

  def coordCompare(a: Coord, b: Coord): Int =
    var i = 0
    while i < 9 do
      if a(i) != b(i) then return Integer.compare(a(i), b(i))
      i += 1
    0

  given Ordering[Coord] with
    def compare(a: Coord, b: Coord): Int = coordCompare(a, b)

  def coordApplyBreak(c: Coord, d: Int): Coord =
    val out = c.toArray
    out(d) += 1
    var lower = d + 1
    while lower < 9 do { out(lower) = 1; lower += 1 }
    out.toVector

  case class PositionedScroll(coord: Coord, text: Array[Byte])

  // phokenize: ordered list of PositionedScroll in buffer.
  def phokenize(buffer: Array[Byte]): List[PositionedScroll] =
    val out = scala.collection.mutable.ListBuffer.empty[PositionedScroll]
    var coord = coordRoot
    var runStart = 0
    var i = 0
    while i < buffer.length do
      val d = breakDim(buffer(i))
      if d >= 0 then
        if i > runStart then
          out += PositionedScroll(coord, buffer.slice(runStart, i))
        coord = coordApplyBreak(coord, d)
        runStart = i + 1
      i += 1
    if buffer.length > runStart then
      out += PositionedScroll(coord, buffer.slice(runStart, buffer.length))
    out.toList

  // advance: break bytes that move loc up to target (loc is an array
  // mutated in place).
  private def advance(loc: Array[Int], target: Coord): Array[Byte] =
    val out = scala.collection.mutable.ArrayBuffer.empty[Byte]
    if coordCompare(loc.toVector, target) < 0 then
      var dim = 0
      while loc(dim) == target(dim) do dim += 1
      var k = 0
      while k < target(dim) - loc(dim) do { out += DimensionBreaks(dim); k += 1 }
      loc(dim) = target(dim)
      var lower = dim + 1
      while lower < 9 do { loc(lower) = 1; lower += 1 }
      lower = dim + 1
      while lower < 9 do
        var j = 0
        while j < target(lower) - 1 do { out += DimensionBreaks(lower); j += 1 }
        loc(lower) = target(lower)
        lower += 1
    out.toArray

  // dephokenize: canonical bytes — sorted coordinate order, advancing
  // from 1.1.1/1.1.1/1.1.1; empty scrolls contribute nothing.
  def dephokenize(stack: List[PositionedScroll]): Array[Byte] =
    val sorted = stack.sortBy(_.coord)
    val loc = Array.fill(9)(1)
    val out = scala.collection.mutable.ArrayBuffer.empty[Byte]
    for ps <- sorted do
      if ps.text.nonEmpty then
        out ++= advance(loc, ps.coord)
        out ++= ps.text
    out.toArray

  def normalize(buffer: Array[Byte]): Array[Byte] =
    dephokenize(phokenize(buffer))

  // fetch: text at coord, or "" for a gap coordinate.
  def fetch(buffer: Array[Byte], coord: Coord): Array[Byte] =
    phokenize(buffer).find(_.coord == coord)
      .map(_.text).getOrElse(Array.emptyByteArray)

  def update(buffer: Array[Byte], coord: Coord, scroll: Array[Byte],
             overwrite: Boolean): Array[Byte] =
    val items = phokenize(buffer)
    val result = scala.collection.mutable.ListBuffer.empty[PositionedScroll]
    var next = PositionedScroll(coord, scroll)
    var appended = false
    for ps <- items do
      var skip = false
      if coordCompare(ps.coord, coord) > 0 && !appended then
        result += next
        appended = true
      if ps.coord == coord && !appended then
        if !overwrite then next = PositionedScroll(coord, ps.text ++ next.text)
        result += next
        appended = true
        skip = true
      if !skip then result += ps
    if !appended then result += next
    // dephokenize in placed order (no sort), as py's update does.
    val loc = Array.fill(9)(1)
    val out = scala.collection.mutable.ArrayBuffer.empty[Byte]
    for ps <- result do
      out ++= advance(loc, ps.coord)
      out ++= ps.text
    out.toArray

  // insert: existing text is prepended to the inserted text.
  def insert(buffer: Array[Byte], coord: Coord, scroll: Array[Byte]): Array[Byte] =
    update(buffer, coord, scroll, false)

  // replace: overwrite the scroll at coord.
  def replace(buffer: Array[Byte], coord: Coord, scroll: Array[Byte]): Array[Byte] =
    update(buffer, coord, scroll, true)

  // remove: replace with "" then normalize — coordinate-preserving:
  // the removed coordinate reads "" and neighbours do not shift.
  def remove(buffer: Array[Byte], coord: Coord): Array[Byte] =
    normalize(update(buffer, coord, Array.emptyByteArray, true))

  // explode: map form (Coord -> text).
  def explode(buffer: Array[Byte]): Map[Coord, Array[Byte]] =
    phokenize(buffer).map(ps => ps.coord -> ps.text).toMap

  // implode: canonical bytes from a Coord -> text map.
  def implode(map: Map[Coord, Array[Byte]]): Array[Byte] =
    dephokenize(map.map { case (c, t) => PositionedScroll(c, t) }.toList)

// ------------------------------------------------------------------
// DynamicPhext: capacity-managed dynamic array scroll store.
// Start at capacity 1, double when full on append, shrink only at
// quarter load (never half — that thrashes). Edit semantics are
// Phext.update's own; the array stays in coordinate order so
// serialize() is byte-identical to the string path.
class DynamicPhext(buffer: Array[Byte] = Array.emptyByteArray,
                   val shrinkDivisor: Int = 4):
  require(shrinkDivisor >= 2, "shrink_divisor must be >= 2")
  private var data: Array[Phext.PositionedScroll] =
    new Array[Phext.PositionedScroll](1)
  var capacity: Int = 1
  private var n: Int = 0
  var resizeCount: Int = 0
  var elementsCopied: Long = 0

  def length: Int = n

  private def resize(newCapacity: Int): Unit =
    val nd = new Array[Phext.PositionedScroll](newCapacity)
    System.arraycopy(data, 0, nd, 0, n)
    data = nd
    capacity = newCapacity
    resizeCount += 1
    elementsCopied += n

  private def growIfFull(): Unit =
    if n == capacity then resize(2 * capacity)

  private def shrinkIfSparse(): Unit =
    if capacity > 1 && n <= capacity / shrinkDivisor then
      resize(math.max(1, capacity / 2))

  private def push(ps: Phext.PositionedScroll): Unit =
    growIfFull()
    data(n) = ps
    n += 1

  def load(buffer: Array[Byte]): Unit =
    capacity = 1
    data = new Array[Phext.PositionedScroll](1)
    n = 0
    resizeCount = 0
    elementsCopied = 0
    for ps <- Phext.phokenize(buffer) do push(ps)

  if buffer.nonEmpty then load(buffer)

  def scrolls: List[Phext.PositionedScroll] = data.slice(0, n).toList
  def serialize(): Array[Byte] = Phext.dephokenize(scrolls)

  // Binary search: (index, found); index is the insertion point.
  private def find(coord: Phext.Coord): (Int, Boolean) =
    var lo = 0
    var hi = n
    while lo < hi do
      val mid = (lo + hi) / 2
      val cmp = Phext.coordCompare(data(mid).coord, coord)
      if cmp < 0 then lo = mid + 1
      else if cmp > 0 then hi = mid
      else return (mid, true)
    (lo, false)

  def fetch(coord: Phext.Coord): Array[Byte] =
    val (index, found) = find(coord)
    if found then data(index).text else Array.emptyByteArray

  def contains(coord: Phext.Coord): Boolean = find(coord)._2

  def append(coord: Phext.Coord, text: Array[Byte]): Unit =
    require(n == 0 || Phext.coordCompare(coord, data(n - 1).coord) > 0,
            "append requires a coordinate past the current tail")
    if text.nonEmpty then push(Phext.PositionedScroll(coord, text))

  def update(coord: Phext.Coord, text: Array[Byte], overwrite: Boolean): Unit =
    val (index, found) = find(coord)
    if found then
      if text.isEmpty then
        if overwrite then removeAt(index)
      else
        val t = if overwrite then text else data(index).text ++ text
        data(index) = Phext.PositionedScroll(coord, t)
    else if text.nonEmpty then
      growIfFull()
      var i = n
      while i > index do { data(i) = data(i - 1); i -= 1 }
      data(index) = Phext.PositionedScroll(coord, text)
      n += 1

  def insert(coord: Phext.Coord, text: Array[Byte]): Unit =
    update(coord, text, false)
  def replace(coord: Phext.Coord, text: Array[Byte]): Unit =
    update(coord, text, true)

  private def removeAt(index: Int): Unit =
    var i = index
    while i < n - 1 do { data(i) = data(i + 1); i += 1 }
    n -= 1
    data(n) = null
    shrinkIfSparse()

  def remove(coord: Phext.Coord): Unit =
    val (index, found) = find(coord)
    if found then removeAt(index)

// ------------------------------------------------------------------
// BranchingMap: a hash map of dimension `depth` branching into hash
// maps of one fewer dimension, recursively, down to leaves holding
// scroll text. One map lookup per dimension.
class BranchingMap(val depth: Int):
  require(depth >= 1, "depth must be >= 1")

  private class Node:
    val children = scala.collection.mutable.HashMap.empty[Int, Node]
    var leaf: Array[Byte] = null

  private val root = new Node
  private var count: Int = 0

  def length: Int = count

  def fetch(key: Phext.Coord): Array[Byte] = fetchRec(root, key, 0)

  private def fetchRec(node: Node, key: Phext.Coord, level: Int): Array[Byte] =
    node.children.get(key(level)) match
      case None => null
      case Some(child) =>
        if level == depth - 1 then child.leaf
        else fetchRec(child, key, level + 1)

  def contains(key: Phext.Coord): Boolean = fetch(key) != null

  // Returns true when a new leaf was created.
  def put(key: Phext.Coord, value: Array[Byte]): Boolean =
    val created = putRec(root, key, 0, value)
    if created then count += 1
    created

  private def putRec(node: Node, key: Phext.Coord, level: Int,
                     value: Array[Byte]): Boolean =
    val comp = key(level)
    if level == depth - 1 then
      val child = node.children.getOrElseUpdate(comp, new Node)
      val created = child.leaf == null
      child.leaf = value
      created
    else
      val child = node.children.getOrElseUpdate(comp, new Node)
      putRec(child, key, level + 1, value)

  def remove(key: Phext.Coord): Boolean =
    val removed = removeRec(root, key, 0)
    if removed then count -= 1
    removed

  private def removeRec(node: Node, key: Phext.Coord, level: Int): Boolean =
    val comp = key(level)
    node.children.get(comp) match
      case None => false
      case Some(child) =>
        if level == depth - 1 then
          if child.leaf == null then false
          else { node.children.remove(comp); true }
        else
          val removed = removeRec(child, key, level + 1)
          if removed && child.children.isEmpty && child.leaf == null then
            node.children.remove(comp)
          removed

  // Items in lexicographic (coordinate) order.
  def items: List[(Phext.Coord, Array[Byte])] =
    val out = scala.collection.mutable.ListBuffer.empty[(Phext.Coord, Array[Byte])]
    itemsRec(root, Vector.empty, 0, out)
    out.toList

  private def itemsRec(node: Node, prefix: Vector[Int], level: Int,
                       out: scala.collection.mutable.ListBuffer[(Phext.Coord, Array[Byte])]): Unit =
    for comp <- node.children.keys.toList.sorted do
      val child = node.children(comp)
      if level == depth - 1 then out += ((prefix :+ comp, child.leaf))
      else itemsRec(child, prefix :+ comp, level + 1, out)

// ------------------------------------------------------------------
// TransitivePhext: scroll store over a BranchingMap at depth 9 — one
// hash-map layer per coordinate dimension, leaves holding scroll
// text. Serialization walks sorted keys at every level, which is
// coordinate order, so serialize() is byte-identical to the string
// path over any edit sequence.
class TransitivePhext(buffer: Array[Byte] = Array.emptyByteArray):
  private var map = new BranchingMap(9)

  def depth: Int = map.depth
  def length: Int = map.length

  if buffer.nonEmpty then load(buffer)

  def load(buffer: Array[Byte]): Unit =
    map = new BranchingMap(9)
    for ps <- Phext.phokenize(buffer) do map.put(ps.coord, ps.text)

  def scrolls: List[Phext.PositionedScroll] =
    map.items.map { case (k, t) => Phext.PositionedScroll(k, t) }

  def serialize(): Array[Byte] = Phext.dephokenize(scrolls)

  def fetch(coord: Phext.Coord): Array[Byte] =
    val v = map.fetch(coord)
    if v == null then Array.emptyByteArray else v

  def contains(coord: Phext.Coord): Boolean = map.contains(coord)

  def update(coord: Phext.Coord, text: Array[Byte], overwrite: Boolean): Unit =
    if text.isEmpty then
      if overwrite then map.remove(coord)
    else if overwrite then map.put(coord, text)
    else
      val existing = map.fetch(coord)
      map.put(coord, if existing != null then existing ++ text else text)

  def insert(coord: Phext.Coord, text: Array[Byte]): Unit =
    update(coord, text, false)
  def replace(coord: Phext.Coord, text: Array[Byte]): Unit =
    update(coord, text, true)
  def remove(coord: Phext.Coord): Unit = map.remove(coord)
  def append(coord: Phext.Coord, text: Array[Byte]): Unit =
    insert(coord, text)
