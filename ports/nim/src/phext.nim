## phext.nim - libphext port for Nim (0.6.1 parity semantics; normative
## reference: libphext-py). 9-dimensional plain-text format: scrolls
## addressed by a coordinate, separated by dimension-break bytes.
## Breaks (dim -> byte): 0 library 0x01, 1 shelf 0x1F, 2 series 0x1E,
## 3 collection 0x1D, 4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19,
## 7 section 0x18, 8 scroll 0x17. Newline is ordinary text.
## Coordinates are array[9, int], each >= 1. All ops on byte strings.

import std/[algorithm, tables, strutils]

const Breaks*: array[9, int] = [0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17]

proc breakDim(b: int): int =
  for d in 0..8:
    if Breaks[d] == b: return d
  return -1

type Coord* = array[9, int]

proc parseCoordinate*(s: string): tuple[ok: bool, coord: Coord] =
  let t = s.strip()
  let groups = t.split('/')
  if groups.len != 3: return (false, result.coord)
  var i = 0
  for g in groups:
    for p in g.split('.'):
      if p.len == 0: return (false, result.coord)
      for ch in p:
        if ch notin '0'..'9': return (false, result.coord)
      let n = parseInt(p)
      if n < 1: return (false, result.coord)
      if i >= 9: return (false, result.coord)
      result.coord[i] = n
      inc i
  if i != 9: return (false, result.coord)
  return (true, result.coord)

proc formatCoordinate*(c: Coord): string =
  "$1.$2.$3/$4.$5.$6/$7.$8.$9" % [$c[0], $c[1], $c[2], $c[3], $c[4], $c[5], $c[6], $c[7], $c[8]]

proc cmpCoord*(a, b: Coord): int =
  for i in 0..8:
    if a[i] != b[i]: return (if a[i] < b[i]: -1 else: 1)
  return 0

type PositionedScroll* = object
  coord*: Coord
  text*: string

proc applyBreak(coord: var Coord, d: int) =
  coord[d] += 1
  for k in d+1..8: coord[k] = 1

proc phokenize*(buffer: string): seq[PositionedScroll] =
  var walker: Coord = [1,1,1,1,1,1,1,1,1]
  var i = 0
  while i < buffer.len:
    let d = breakDim(ord(buffer[i]))
    if d >= 0:
      applyBreak(walker, d)
      inc i
    else:
      let start = i
      while i < buffer.len and breakDim(ord(buffer[i])) < 0: inc i
      result.add(PositionedScroll(coord: walker, text: buffer[start..<i]))

proc advance(loc: var Coord, target: Coord): string =
  if cmpCoord(loc, target) >= 0: return ""
  var d = 0
  while loc[d] == target[d]: inc d
  result = repeat(chr(Breaks[d]), target[d] - loc[d])
  var reached = loc
  reached[d] = target[d]
  for k in d+1..8: reached[k] = 1
  for lower in d+1..8:
    result &= repeat(chr(Breaks[lower]), target[lower] - 1)
    reached[lower] = target[lower]
  loc = reached

proc dephokenize*(scrolls: seq[PositionedScroll]): string =
  var loc: Coord = [1,1,1,1,1,1,1,1,1]
  for ps in scrolls:
    result &= advance(loc, ps.coord)
    result &= ps.text

proc normalize*(buffer: string): string = dephokenize(phokenize(buffer))

proc fetch*(buffer: string, coord: Coord): string =
  for ps in phokenize(buffer):
    if cmpCoord(ps.coord, coord) == 0: return ps.text
  return ""

proc update(buffer: string, coord: Coord, text: string, overwrite: bool): string =
  let items = phokenize(buffer)
  var nxt = PositionedScroll(coord: coord, text: text)
  var res: seq[PositionedScroll]
  var appended = false
  for ps in items:
    if not appended and cmpCoord(ps.coord, coord) > 0:
      res.add(nxt); appended = true
    if not appended and cmpCoord(ps.coord, coord) == 0:
      if not overwrite: nxt.text = ps.text & nxt.text
      res.add(nxt); appended = true
      continue
    res.add(ps)
  if not appended: res.add(nxt)
  return dephokenize(res)

proc insert*(buffer: string, coord: Coord, text: string): string =
  update(buffer, coord, text, false)

proc replace*(buffer: string, coord: Coord, text: string): string =
  update(buffer, coord, text, true)

## remove is COORDINATE-PRESERVING: the scroll becomes empty, delimiters
## stay, later scrolls do NOT shift.
proc remove*(buffer: string, coord: Coord): string =
  normalize(update(buffer, coord, "", true))

proc explode*(buffer: string): Table[string, string] =
  for ps in phokenize(buffer):
    result[formatCoordinate(ps.coord)] = ps.text

proc implode*(map: Table[string, string]): string =
  var scrolls: seq[PositionedScroll]
  for k, v in map:
    let (ok, c) = parseCoordinate(k)
    if ok: scrolls.add(PositionedScroll(coord: c, text: v))
  scrolls.sort(proc (a, b: PositionedScroll): int = cmpCoord(a.coord, b.coord))
  return dephokenize(scrolls)

# ---------- DynamicPhext: capacity-managed dynamic array ----------
type DynamicPhext* = ref object
  data: seq[PositionedScroll]
  n*: int
  capacity*: int
  shrinkDivisor: int
  resizeCount*: int
  elementsCopied*: int

proc push(d: DynamicPhext, ps: PositionedScroll)
proc load*(d: DynamicPhext, buffer: string)

proc newDynamicPhext*(buffer: string = "", shrinkDivisor: int = 4): DynamicPhext =
  if shrinkDivisor < 2: raise newException(ValueError, "shrink_divisor must be >= 2")
  result = DynamicPhext(data: newSeq[PositionedScroll](1), n: 0, capacity: 1,
                        shrinkDivisor: shrinkDivisor)
  if buffer.len > 0: result.load(buffer)

proc resize(d: DynamicPhext, newCap: int) =
  var nd = newSeq[PositionedScroll](newCap)
  for i in 0..<d.n: nd[i] = d.data[i]
  d.data = nd
  d.capacity = newCap
  d.resizeCount += 1
  d.elementsCopied += d.n

proc growIfFull(d: DynamicPhext) =
  if d.n == d.capacity: d.resize(2 * d.capacity)

proc shrinkIfSparse(d: DynamicPhext) =
  if d.capacity > 1 and d.n <= d.capacity div d.shrinkDivisor:
    d.resize(max(1, d.capacity div 2))

proc push(d: DynamicPhext, ps: PositionedScroll) =
  d.growIfFull()
  d.data[d.n] = ps
  d.n += 1

proc load*(d: DynamicPhext, buffer: string) =
  d.capacity = 1
  d.data = newSeq[PositionedScroll](1)
  d.n = 0
  d.resizeCount = 0
  d.elementsCopied = 0
  for ps in phokenize(buffer): d.push(ps)

proc scrolls*(d: DynamicPhext): seq[PositionedScroll] =
  for i in 0..<d.n: result.add(d.data[i])

proc serialize*(d: DynamicPhext): string = dephokenize(d.scrolls())

proc find(d: DynamicPhext, coord: Coord): tuple[idx: int, found: bool] =
  var lo = 0
  var hi = d.n
  while lo < hi:
    let mid = (lo + hi) div 2
    let c = cmpCoord(d.data[mid].coord, coord)
    if c < 0: lo = mid + 1
    elif c > 0: hi = mid
    else: return (mid, true)
  return (lo, false)

proc fetch*(d: DynamicPhext, coord: Coord): string =
  let (idx, found) = d.find(coord)
  return if found: d.data[idx].text else: ""

proc contains*(d: DynamicPhext, coord: Coord): bool = d.find(coord).found
proc len*(d: DynamicPhext): int = d.n

proc append*(d: DynamicPhext, coord: Coord, text: string) =
  if d.n > 0 and cmpCoord(coord, d.data[d.n-1].coord) <= 0:
    raise newException(ValueError, "append requires a coordinate past the current tail")
  if text.len == 0: return
  d.push(PositionedScroll(coord: coord, text: text))

proc removeAt(d: DynamicPhext, idx: int) =
  for i in idx..<d.n-1: d.data[i] = d.data[i+1]
  d.n -= 1
  d.shrinkIfSparse()

proc update*(d: DynamicPhext, coord: Coord, text: string, overwrite: bool) =
  let (idx, found) = d.find(coord)
  if found:
    if text.len == 0:
      if overwrite: d.removeAt(idx)
      return
    var t = text
    if not overwrite: t = d.data[idx].text & t
    d.data[idx] = PositionedScroll(coord: coord, text: t)
    return
  if text.len == 0: return
  d.growIfFull()
  for i in countdown(d.n, idx+1): d.data[i] = d.data[i-1]
  d.data[idx] = PositionedScroll(coord: coord, text: text)
  d.n += 1

proc insert*(d: DynamicPhext, coord: Coord, text: string) = d.update(coord, text, false)
proc replace*(d: DynamicPhext, coord: Coord, text: string) = d.update(coord, text, true)
proc remove*(d: DynamicPhext, coord: Coord) =
  let (idx, found) = d.find(coord)
  if found: d.removeAt(idx)

# ---------- TransitivePhext: branching hash map, depth 9 ----------
type
  BranchNode = ref object
    children: Table[int, BranchNode]
    leaf: string
    hasLeaf: bool
  BranchingMap* = ref object
    depth*: int
    root: BranchNode
    count*: int

proc newNode(): BranchNode = BranchNode(children: initTable[int, BranchNode]())

proc newBranchingMap*(depth: int): BranchingMap =
  if depth < 1: raise newException(ValueError, "depth must be >= 1")
  BranchingMap(depth: depth, root: newNode(), count: 0)

proc fetch*(m: BranchingMap, key: Coord): tuple[ok: bool, val: string] =
  var node = m.root
  for level in 0..<m.depth:
    if not node.children.hasKey(key[level]): return (false, "")
    let child = node.children[key[level]]
    if level == m.depth - 1:
      return (child.hasLeaf, child.leaf)
    node = child

proc put*(m: BranchingMap, key: Coord, value: string): bool =
  var node = m.root
  for level in 0..<m.depth:
    if not node.children.hasKey(key[level]):
      node.children[key[level]] = newNode()
    let child = node.children[key[level]]
    if level == m.depth - 1:
      let created = not child.hasLeaf
      child.leaf = value
      child.hasLeaf = true
      if created: m.count += 1
      return created
    node = child

proc removeRec(node: BranchNode, key: Coord, depth: int, level: int): bool =
  if not node.children.hasKey(key[level]): return false
  let child = node.children[key[level]]
  if level == depth - 1:
    if child.hasLeaf:
      child.hasLeaf = false
      child.leaf = ""
      return true
    return false
  let removed = removeRec(child, key, depth, level + 1)
  if removed and child.children.len == 0 and not child.hasLeaf:
    node.children.del(key[level])
  return removed

proc remove*(m: BranchingMap, key: Coord): bool =
  let removed = removeRec(m.root, key, m.depth, 0)
  if removed: m.count -= 1
  return removed

proc itemsRec(node: BranchNode, depth: int, level: int, prefix: var Coord,
              res: var seq[PositionedScroll]) =
  var keys: seq[int]
  for k in node.children.keys: keys.add(k)
  keys.sort()
  for k in keys:
    let child = node.children[k]
    prefix[level] = k
    if level == depth - 1:
      if child.hasLeaf:
        res.add(PositionedScroll(coord: prefix, text: child.leaf))
    else:
      itemsRec(child, depth, level + 1, prefix, res)

proc items*(m: BranchingMap): seq[PositionedScroll] =
  var prefix: Coord
  itemsRec(m.root, m.depth, 0, prefix, result)

type TransitivePhext* = ref object
  map: BranchingMap

proc load*(t: TransitivePhext, buffer: string)

proc newTransitivePhext*(buffer: string = ""): TransitivePhext =
  result = TransitivePhext(map: newBranchingMap(9))
  if buffer.len > 0: result.load(buffer)

proc depth*(t: TransitivePhext): int = t.map.depth

proc load*(t: TransitivePhext, buffer: string) =
  t.map = newBranchingMap(9)
  for ps in phokenize(buffer): discard t.map.put(ps.coord, ps.text)

proc scrolls*(t: TransitivePhext): seq[PositionedScroll] = t.map.items()
proc serialize*(t: TransitivePhext): string = dephokenize(t.scrolls())

proc fetch*(t: TransitivePhext, coord: Coord): string =
  let (ok, v) = t.map.fetch(coord)
  return if ok: v else: ""

proc contains*(t: TransitivePhext, coord: Coord): bool = t.map.fetch(coord).ok
proc len*(t: TransitivePhext): int = t.map.count

proc update*(t: TransitivePhext, coord: Coord, text: string, overwrite: bool) =
  if text.len == 0:
    if overwrite: discard t.map.remove(coord)
    return
  var txt = text
  if not overwrite:
    let (ok, ex) = t.map.fetch(coord)
    if ok: txt = ex & txt
  discard t.map.put(coord, txt)

proc insert*(t: TransitivePhext, coord: Coord, text: string) = t.update(coord, text, false)
proc replace*(t: TransitivePhext, coord: Coord, text: string) = t.update(coord, text, true)
proc remove*(t: TransitivePhext, coord: Coord) = discard t.map.remove(coord)
proc append*(t: TransitivePhext, coord: Coord, text: string) = t.insert(coord, text)
