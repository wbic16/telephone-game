// libphext-groovy — a Groovy port of libphext (0.6.1 parity).
//
// Semantics are normative from libphext-py: a phext is a byte buffer;
// nine dimension-break bytes walk a 9-component coordinate; scroll text
// is a maximal run of non-break bytes (newline 0x0A is ordinary text).
// All buffers are byte[] so control bytes are never reinterpreted.
// Coordinates are Coord (9 longs, lexicographic order); string form
// a.b.c/d.e.f/g.h.i.
package phext

import java.io.ByteArrayOutputStream

class Coord implements Comparable<Coord> {
    final long[] v
    Coord(long[] v) { this.v = v }
    boolean equals(Object o) { o instanceof Coord && Arrays.equals(v, ((Coord) o).v) }
    int hashCode() { Arrays.hashCode(v) }
    int compareTo(Coord other) {
        for (int i = 0; i < 9; i++) {
            if (v[i] != other.v[i]) return Long.compare(v[i], other.v[i])
        }
        return 0
    }
    String toString() { Phext.coordString(this) }
}

class PositionedScroll {
    Coord coord
    byte[] text
    PositionedScroll(Coord c, byte[] t) { coord = c; text = t }
}

class Phext {
    static final byte[] DIMENSION_BREAKS =
        [0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17] as byte[]
    static final Map<Byte, Integer> BREAK_DIM = new HashMap<>()
    static {
        for (int d = 0; d < 9; d++) BREAK_DIM.put(DIMENSION_BREAKS[d], d)
    }

    static Coord coordRoot() { new Coord(new long[9].with { Arrays.fill(it, 1L); it }) }

    static Coord coordParse(String s) {
        String[] groups = s.trim().split("/")
        if (groups.length != 3)
            throw new IllegalArgumentException("coordinate must be a.b.c/d.e.f/g.h.i: " + s)
        long[] nums = new long[9]
        int k = 0
        for (String g : groups) {
            for (String p : g.split("\\.")) {
                if (k >= 9) throw new IllegalArgumentException("coordinate needs 9 parts: " + s)
                nums[k++] = Long.parseLong(p)
            }
        }
        if (k != 9) throw new IllegalArgumentException("coordinate needs 9 parts: " + s)
        for (long n : nums)
            if (n < 1) throw new IllegalArgumentException("components must be >= 1: " + s)
        return new Coord(nums)
    }

    static String coordString(Coord c) {
        return String.format("%d.%d.%d/%d.%d.%d/%d.%d.%d",
            c.v[0], c.v[1], c.v[2], c.v[3], c.v[4], c.v[5], c.v[6], c.v[7], c.v[8])
    }

    static Coord coordApplyBreak(Coord c, int d) {
        long[] out = c.v.clone()
        out[d] += 1
        for (int lower = d + 1; lower < 9; lower++) out[lower] = 1
        return new Coord(out)
    }

    static List<PositionedScroll> phokenize(byte[] buffer) {
        List<PositionedScroll> out = new ArrayList<>()
        Coord coord = coordRoot()
        int runStart = 0
        for (int i = 0; i < buffer.length; i++) {
            Integer d = BREAK_DIM.get(buffer[i])
            if (d != null) {
                if (i > runStart)
                    out.add(new PositionedScroll(coord, Arrays.copyOfRange(buffer, runStart, i)))
                coord = coordApplyBreak(coord, d)
                runStart = i + 1
            }
        }
        if (buffer.length > runStart)
            out.add(new PositionedScroll(coord, Arrays.copyOfRange(buffer, runStart, buffer.length)))
        return out
    }

    private static Coord emitAdvance(ByteArrayOutputStream out, Coord loc, Coord target) {
        if (loc.compareTo(target) < 0) {
            int dim = 0
            while (loc.v[dim] == target.v[dim]) dim++
            for (long k = 0; k < target.v[dim] - loc.v[dim]; k++) out.write(DIMENSION_BREAKS[dim])
            for (int lower = dim + 1; lower < 9; lower++)
                for (long k = 0; k < target.v[lower] - 1; k++) out.write(DIMENSION_BREAKS[lower])
        }
        return target
    }

    static byte[] dephokenize(List<PositionedScroll> stack) {
        List<PositionedScroll> sorted = new ArrayList<>(stack)
        sorted.sort { a, b -> a.coord.compareTo(b.coord) }
        ByteArrayOutputStream out = new ByteArrayOutputStream()
        Coord loc = coordRoot()
        for (PositionedScroll ps : sorted) {
            if (ps.text.length == 0) continue
            loc = emitAdvance(out, loc, ps.coord)
            out.write(ps.text)
        }
        return out.toByteArray()
    }

    private static byte[] dephokenizeInOrder(List<PositionedScroll> stack) {
        ByteArrayOutputStream out = new ByteArrayOutputStream()
        Coord loc = coordRoot()
        for (PositionedScroll ps : stack) {
            loc = emitAdvance(out, loc, ps.coord)
            out.write(ps.text)
        }
        return out.toByteArray()
    }

    static byte[] normalize(byte[] buffer) { dephokenize(phokenize(buffer)) }

    static byte[] fetch(byte[] buffer, Coord coord) {
        for (PositionedScroll ps : phokenize(buffer))
            if (ps.coord == coord) return ps.text
        return new byte[0]
    }

    private static byte[] update(byte[] buffer, Coord coord, byte[] scroll, boolean overwrite) {
        List<PositionedScroll> items = phokenize(buffer)
        List<PositionedScroll> result = new ArrayList<>()
        PositionedScroll next = new PositionedScroll(coord, scroll)
        boolean appended = false
        for (PositionedScroll ps : items) {
            int cmp = ps.coord.compareTo(coord)
            if (cmp > 0 && !appended) {
                result.add(next); appended = true; result.add(ps)
            } else if (cmp == 0 && !appended) {
                if (overwrite) {
                    result.add(next)
                } else {
                    ByteArrayOutputStream baos = new ByteArrayOutputStream()
                    baos.write(ps.text); baos.write(next.text)
                    result.add(new PositionedScroll(coord, baos.toByteArray()))
                }
                appended = true
            } else {
                result.add(ps)
            }
        }
        if (!appended) result.add(next)
        return dephokenizeInOrder(result)
    }

    // insert: existing text is prepended to the inserted text.
    static byte[] insert(byte[] buffer, Coord coord, byte[] scroll) {
        update(buffer, coord, scroll, false)
    }

    static byte[] replace(byte[] buffer, Coord coord, byte[] scroll) {
        update(buffer, coord, scroll, true)
    }

    // remove: replace with "" then normalize — coordinate-preserving:
    // the removed coordinate reads "" and neighbours do not shift.
    static byte[] remove(byte[] buffer, Coord coord) {
        normalize(update(buffer, coord, new byte[0], true))
    }

    static Map<Coord, byte[]> explode(byte[] buffer) {
        Map<Coord, byte[]> out = new LinkedHashMap<>()
        for (PositionedScroll ps : phokenize(buffer)) out.put(ps.coord, ps.text)
        return out
    }

    static byte[] implode(Map<Coord, byte[]> map) {
        List<PositionedScroll> stack = new ArrayList<>()
        map.each { c, t -> stack.add(new PositionedScroll(c, t)) }
        return dephokenize(stack)
    }
}

// ------------------------------------------------------------------
// DynamicPhext: capacity-managed dynamic array scroll store.
// Start at capacity 1, double when full on append, shrink only at
// quarter load (never half — that thrashes).
class DynamicPhext {
    private PositionedScroll[] data
    int capacity
    private int n
    int resizeCount
    long elementsCopied
    final int shrinkDivisor

    DynamicPhext() { this(new byte[0], 4) }
    DynamicPhext(byte[] buffer) { this(buffer, 4) }
    DynamicPhext(byte[] buffer, int shrinkDivisor) {
        if (shrinkDivisor < 2) throw new IllegalArgumentException("shrink_divisor must be >= 2")
        this.shrinkDivisor = shrinkDivisor
        data = new PositionedScroll[1]
        capacity = 1
        n = 0
        resizeCount = 0
        elementsCopied = 0
        if (buffer.length > 0) load(buffer)
    }

    int length() { n }

    private void resize(int newCapacity) {
        PositionedScroll[] nd = new PositionedScroll[newCapacity]
        System.arraycopy(data, 0, nd, 0, n)
        data = nd
        capacity = newCapacity
        resizeCount++
        elementsCopied += n
    }

    private void growIfFull() { if (n == capacity) resize(2 * capacity) }

    private void shrinkIfSparse() {
        if (capacity > 1 && n <= capacity.intdiv(shrinkDivisor))
            resize(Math.max(1, capacity.intdiv(2)))
    }

    private void push(PositionedScroll ps) {
        growIfFull()
        data[n] = ps
        n++
    }

    void load(byte[] buffer) {
        capacity = 1
        data = new PositionedScroll[1]
        n = 0
        resizeCount = 0
        elementsCopied = 0
        for (PositionedScroll ps : Phext.phokenize(buffer)) push(ps)
    }

    List<PositionedScroll> scrolls() {
        List<PositionedScroll> out = new ArrayList<>()
        for (int i = 0; i < n; i++) out.add(data[i])
        return out
    }

    byte[] serialize() { Phext.dephokenize(scrolls()) }

    // Binary search: [index, found]; index is the insertion point.
    private List find(Coord coord) {
        int lo = 0, hi = n
        while (lo < hi) {
            int mid = (lo + hi).intdiv(2)
            int cmp = data[mid].coord.compareTo(coord)
            if (cmp < 0) lo = mid + 1
            else if (cmp > 0) hi = mid
            else return [mid, true]
        }
        return [lo, false]
    }

    byte[] fetch(Coord coord) {
        def (index, found) = find(coord)
        return found ? data[index].text : new byte[0]
    }

    boolean contains(Coord coord) { find(coord)[1] }

    void append(Coord coord, byte[] text) {
        if (n > 0 && coord.compareTo(data[n - 1].coord) <= 0)
            throw new IllegalArgumentException("append requires a coordinate past the current tail")
        if (text.length > 0) push(new PositionedScroll(coord, text))
    }

    void update(Coord coord, byte[] text, boolean overwrite) {
        def (index, found) = find(coord)
        if (found) {
            if (text.length == 0) {
                if (overwrite) removeAt(index)
            } else {
                byte[] t
                if (overwrite) {
                    t = text
                } else {
                    ByteArrayOutputStream baos = new ByteArrayOutputStream()
                    baos.write(data[index].text); baos.write(text)
                    t = baos.toByteArray()
                }
                data[index] = new PositionedScroll(coord, t)
            }
        } else if (text.length > 0) {
            growIfFull()
            for (int i = n; i > index; i--) data[i] = data[i - 1]
            data[index] = new PositionedScroll(coord, text)
            n++
        }
    }

    void insert(Coord coord, byte[] text) { update(coord, text, false) }
    void replace(Coord coord, byte[] text) { update(coord, text, true) }

    private void removeAt(int index) {
        for (int i = index; i < n - 1; i++) data[i] = data[i + 1]
        n--
        data[n] = null
        shrinkIfSparse()
    }

    void remove(Coord coord) {
        def (index, found) = find(coord)
        if (found) removeAt(index)
    }
}

// ------------------------------------------------------------------
// BranchingMap: a hash map of dimension `depth` branching into hash
// maps of one fewer dimension, recursively, down to leaves holding
// scroll text. One map lookup per dimension.
class BranchingMap {
    final int depth
    private static class Node {
        Map<Long, Node> children = new HashMap<>()
        byte[] leaf = null
    }
    private final Node root = new Node()
    private int count = 0

    BranchingMap(int depth) {
        if (depth < 1) throw new IllegalArgumentException("depth must be >= 1")
        this.depth = depth
    }

    int length() { count }

    byte[] fetch(Coord key) {
        Node node = root
        for (int level = 0; level < depth; level++) {
            Node child = node.children.get(key.v[level])
            if (child == null) return null
            if (level == depth - 1) return child.leaf
            node = child
        }
        return null
    }

    boolean contains(Coord key) { fetch(key) != null }

    // Returns true when a new leaf was created.
    boolean put(Coord key, byte[] value) {
        Node node = root
        for (int level = 0; level < depth; level++) {
            Node child = node.children.computeIfAbsent(key.v[level]) { new Node() }
            if (level == depth - 1) {
                boolean created = child.leaf == null
                child.leaf = value
                if (created) count++
                return created
            }
            node = child
        }
        return false
    }

    boolean remove(Coord key) {
        boolean removed = removeRec(root, key, 0)
        if (removed) count--
        return removed
    }

    private boolean removeRec(Node node, Coord key, int level) {
        Node child = node.children.get(key.v[level])
        if (child == null) return false
        if (level == depth - 1) {
            if (child.leaf == null) return false
            node.children.remove(key.v[level])
            return true
        }
        boolean removed = removeRec(child, key, level + 1)
        if (removed && child.children.isEmpty() && child.leaf == null)
            node.children.remove(key.v[level])
        return removed
    }

    // Items in lexicographic (coordinate) order.
    List<List> items() {
        List<List> out = new ArrayList<>()
        itemsRec(root, new ArrayList<Long>(), 0, out)
        return out
    }

    private void itemsRec(Node node, List<Long> prefix, int level, List<List> out) {
        List<Long> keys = new ArrayList<>(node.children.keySet())
        keys.sort()
        for (Long comp : keys) {
            Node child = node.children.get(comp)
            List<Long> k = new ArrayList<>(prefix)
            k.add(comp)
            if (level == depth - 1) {
                out.add([new Coord(k as long[]), child.leaf])
            } else {
                itemsRec(child, k, level + 1, out)
            }
        }
    }
}

// ------------------------------------------------------------------
// TransitivePhext: scroll store over a BranchingMap at depth 9.
class TransitivePhext {
    private BranchingMap map = new BranchingMap(9)

    TransitivePhext() {}
    TransitivePhext(byte[] buffer) { if (buffer.length > 0) load(buffer) }

    int getDepth() { map.depth }
    int length() { map.length() }

    void load(byte[] buffer) {
        map = new BranchingMap(9)
        for (PositionedScroll ps : Phext.phokenize(buffer)) map.put(ps.coord, ps.text)
    }

    List<PositionedScroll> scrolls() {
        List<PositionedScroll> out = new ArrayList<>()
        for (List e : map.items()) out.add(new PositionedScroll((Coord) e[0], (byte[]) e[1]))
        return out
    }

    byte[] serialize() { Phext.dephokenize(scrolls()) }

    byte[] fetch(Coord coord) {
        byte[] v = map.fetch(coord)
        return v == null ? new byte[0] : v
    }

    boolean contains(Coord coord) { map.contains(coord) }

    void update(Coord coord, byte[] text, boolean overwrite) {
        if (text.length == 0) {
            if (overwrite) map.remove(coord)
        } else if (overwrite) {
            map.put(coord, text)
        } else {
            byte[] existing = map.fetch(coord)
            if (existing == null) {
                map.put(coord, text)
            } else {
                ByteArrayOutputStream baos = new ByteArrayOutputStream()
                baos.write(existing); baos.write(text)
                map.put(coord, baos.toByteArray())
            }
        }
    }

    void insert(Coord coord, byte[] text) { update(coord, text, false) }
    void replace(Coord coord, byte[] text) { update(coord, text, true) }
    void remove(Coord coord) { map.remove(coord) }
    void append(Coord coord, byte[] text) { insert(coord, text) }
}
