// libphext-d — a D port of libphext (0.6.1 parity).
//
// Semantics are normative from libphext-py: a phext is a byte buffer;
// nine dimension-break bytes walk a 9-component coordinate; scroll text
// is a maximal run of non-break bytes (newline 0x0A is ordinary text).
// All buffers are ubyte[] so control bytes and arbitrary byte sequences
// are never reinterpreted.
module phext;

import std.algorithm : sort;
import std.array : appender;
import std.exception : enforce;

// Dimension breaks in dimension order (library .. scroll).
immutable ubyte[9] DIMENSION_BREAKS = [0x01, 0x1F, 0x1E, 0x1D, 0x1C,
                                       0x1A, 0x19, 0x18, 0x17];

// Dimension index of a break byte, or -1 for ordinary text bytes.
int breakDim(ubyte b) {
    foreach (d, br; DIMENSION_BREAKS)
        if (b == br) return cast(int) d;
    return -1;
}

// A phext coordinate: 9 components, each >= 1, ordered
// lexicographically. String form: a.b.c/d.e.f/g.h.i
struct Coordinate {
    int[9] v;

    this(int[9] parts) {
        foreach (x; parts) enforce(x >= 1, "coordinate components must be >= 1");
        v = parts;
    }

    static Coordinate parse(string s) {
        import std.conv : to;
        import std.string : split, strip;
        auto groups = strip(s).split("/");
        enforce(groups.length == 3, "coordinate must be a.b.c/d.e.f/g.h.i: " ~ s);
        int[9] nums;
        int i = 0;
        foreach (g; groups)
            foreach (p; g.split("."))
                nums[i++] = to!int(p);
        enforce(i == 9, "coordinate needs 9 parts: " ~ s);
        return Coordinate(nums);
    }

    static Coordinate root() {
        int[9] ones = 1;
        return Coordinate(ones);
    }

    int opCmp(const Coordinate other) const {
        foreach (i; 0 .. 9)
            if (v[i] != other.v[i]) return v[i] < other.v[i] ? -1 : 1;
        return 0;
    }

    bool opEquals(const Coordinate other) const { return v == other.v; }
    size_t toHash() const @safe nothrow { size_t h; foreach (x; v) h = h * 31 + x; return h; }

    // Apply a break at dimension d (0-based): increment component d,
    // reset all lower components to 1.
    Coordinate applyBreak(int d) const {
        int[9] out_;
        out_[] = v[];
        out_[d] += 1;
        foreach (lower; d + 1 .. 9) out_[lower] = 1;
        return Coordinate(out_);
    }

    string toString() const {
        import std.format : format;
        return format("%d.%d.%d/%d.%d.%d/%d.%d.%d",
                      v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8]);
    }
}

struct PositionedScroll {
    Coordinate coord;
    ubyte[] text;
}

private void applyBreakTo(ref int[9] coord, int d) {
    coord[d] += 1;
    foreach (lower; d + 1 .. 9) coord[lower] = 1;
}

// phokenize: ordered list of PositionedScroll in buffer.
PositionedScroll[] phokenize(const(ubyte)[] buffer) {
    PositionedScroll[] out_;
    int[9] coord = 1;
    size_t runStart = 0;
    foreach (i, b; buffer) {
        int d = breakDim(b);
        if (d < 0) continue;
        if (i > runStart)
            out_ ~= PositionedScroll(Coordinate(coord),
                                    buffer[runStart .. i].dup);
        applyBreakTo(coord, d);
        runStart = i + 1;
    }
    if (buffer.length > runStart)
        out_ ~= PositionedScroll(Coordinate(coord),
                                buffer[runStart .. $].dup);
    return out_;
}

// advance: break bytes that move loc up to target (mutates loc).
private ubyte[] advance(ref int[9] loc, Coordinate target) {
    ubyte[] out_;
    bool less = false;
    foreach (i; 0 .. 9) if (loc[i] != target.v[i]) { less = loc[i] < target.v[i]; break; }
    bool equal = loc == target.v;
    if (equal || !less) return out_;
    int dim = 0;
    while (loc[dim] == target.v[dim]) dim++;
    foreach (_; 0 .. target.v[dim] - loc[dim]) out_ ~= DIMENSION_BREAKS[dim];
    loc[dim] = target.v[dim];
    foreach (lower; dim + 1 .. 9) loc[lower] = 1;
    foreach (lower; dim + 1 .. 9) {
        foreach (_; 0 .. target.v[lower] - 1) out_ ~= DIMENSION_BREAKS[lower];
        loc[lower] = target.v[lower];
    }
    return out_;
}

// dephokenize: canonical bytes — sorted coordinate order, advancing
// from 1.1.1/1.1.1/1.1.1; empty scrolls contribute nothing.
ubyte[] dephokenize(PositionedScroll[] stack) {
    auto sorted = stack.dup;
    sort!((a, b) => a.coord < b.coord)(sorted);
    auto app = appender!(ubyte[])();
    int[9] loc = 1;
    foreach (ps; sorted) {
        if (ps.text.length == 0) continue;
        app.put(advance(loc, ps.coord));
        app.put(ps.text);
    }
    return app.data;
}

// normalize = phokenize then dephokenize.
ubyte[] normalize(const(ubyte)[] buffer) {
    return dephokenize(phokenize(buffer));
}

// fetch: text at coord, or "" for a gap coordinate.
ubyte[] fetch(const(ubyte)[] buffer, Coordinate coord) {
    foreach (ps; phokenize(buffer))
        if (ps.coord == coord) return ps.text;
    return [];
}

ubyte[] update(const(ubyte)[] buffer, Coordinate coord, const(ubyte)[] scroll,
               bool overwrite) {
    auto items = phokenize(buffer);
    PositionedScroll[] result;
    auto next = PositionedScroll(coord, scroll.dup);
    bool appended = false;
    foreach (ps; items) {
        if (ps.coord > coord && !appended) {
            result ~= next;
            appended = true;
        }
        if (ps.coord == coord && !appended) {
            if (!overwrite) next.text = ps.text ~ next.text;
            result ~= next;
            appended = true;
            continue;
        }
        result ~= ps;
    }
    if (!appended) result ~= next;
    // dephokenize without the sort: update output follows phokenize
    // order with the new scroll placed in coordinate order (as py).
    auto app = appender!(ubyte[])();
    int[9] loc = 1;
    foreach (ps; result) {
        app.put(advance(loc, ps.coord));
        app.put(ps.text);
    }
    return app.data;
}

// insert: existing text is prepended to the inserted text.
ubyte[] insert(const(ubyte)[] buffer, Coordinate coord, const(ubyte)[] scroll) {
    return update(buffer, coord, scroll, false);
}

// replace: overwrite the scroll at coord.
ubyte[] replace(const(ubyte)[] buffer, Coordinate coord, const(ubyte)[] scroll) {
    return update(buffer, coord, scroll, true);
}

// remove: replace with "" then normalize — coordinate-preserving:
// the removed coordinate reads "" and neighbours do not shift.
ubyte[] remove(const(ubyte)[] buffer, Coordinate coord) {
    return normalize(update(buffer, coord, [], true));
}

// explode: map form (Coordinate -> text).
ubyte[][Coordinate] explode(const(ubyte)[] buffer) {
    ubyte[][Coordinate] out_;
    foreach (ps; phokenize(buffer)) out_[ps.coord] = ps.text;
    return out_;
}

// implode: canonical bytes from a Coordinate -> text map.
ubyte[] implode(ubyte[][Coordinate] map) {
    PositionedScroll[] parts;
    foreach (coord, text; map) parts ~= PositionedScroll(coord, text);
    return dephokenize(parts);
}

// ------------------------------------------------------------------
// DynamicPhext: capacity-managed dynamic array scroll store.
// Start at capacity 1, double when full on append, shrink only at
// quarter load (never half — that thrashes). Edit semantics are
// Phext.update's own; the array stays in coordinate order so
// serialize() is byte-identical to the string path.
class DynamicPhext {
    private PositionedScroll[] _data;
    private size_t _capacity;
    private size_t _n;
    private int _shrinkDivisor;
    private PhextStats _stats;

    struct PhextStats { int resizeCount; long elementsCopied; }

    this(const(ubyte)[] buffer = null, int shrinkDivisor = 4) {
        enforce(shrinkDivisor >= 2, "shrink_divisor must be >= 2");
        _shrinkDivisor = shrinkDivisor;
        _capacity = 1;
        _data = new PositionedScroll[_capacity];
        _n = 0;
        if (buffer.length) load(buffer);
    }

    @property size_t capacity() const { return _capacity; }
    @property int resizeCount() const { return _stats.resizeCount; }
    @property long elementsCopied() const { return _stats.elementsCopied; }
    void resetStats() { _stats = PhextStats.init; }
    @property size_t length() const { return _n; }

    private void _resize(size_t newCapacity) {
        auto nd = new PositionedScroll[newCapacity];
        foreach (i; 0 .. _n) nd[i] = _data[i];
        _data = nd;
        _capacity = newCapacity;
        _stats.resizeCount += 1;
        _stats.elementsCopied += _n;
    }

    private void _growIfFull() {
        if (_n == _capacity) _resize(2 * _capacity);
    }

    private void _shrinkIfSparse() {
        if (_capacity > 1 && _n <= _capacity / _shrinkDivisor)
            _resize(_capacity / 2 > 1 ? _capacity / 2 : 1);
    }

    private void _push(PositionedScroll ps) {
        _growIfFull();
        _data[_n] = ps;
        _n += 1;
    }

    void load(const(ubyte)[] buffer) {
        _capacity = 1;
        _data = new PositionedScroll[_capacity];
        _n = 0;
        resetStats();
        foreach (ps; phokenize(buffer)) _push(ps);
    }

    PositionedScroll[] scrolls() { return _data[0 .. _n].dup; }
    ubyte[] serialize() { return dephokenize(scrolls()); }

    // Binary search: (index, found); index is the insertion point.
    private Tuple!(size_t, bool) _find(Coordinate coord) {
        size_t lo = 0, hi = _n;
        while (lo < hi) {
            size_t mid = (lo + hi) / 2;
            if (_data[mid].coord < coord) lo = mid + 1;
            else if (_data[mid].coord > coord) hi = mid;
            else return Tuple!(size_t, bool)(mid, true);
        }
        return Tuple!(size_t, bool)(lo, false);
    }

    ubyte[] fetch(Coordinate coord) {
        auto f = _find(coord);
        return f[1] ? _data[f[0]].text : null;
    }

    bool contains(Coordinate coord) { return _find(coord)[1]; }

    void append(Coordinate coord, const(ubyte)[] text) {
        enforce(_n == 0 || coord > _data[_n - 1].coord,
                "append requires a coordinate past the current tail");
        if (text.length == 0) return;
        _push(PositionedScroll(coord, text.dup));
    }

    void update(Coordinate coord, const(ubyte)[] text, bool overwrite) {
        auto f = _find(coord);
        size_t index = f[0];
        if (f[1]) {
            if (text.length == 0) {
                if (overwrite) _removeAt(index);
                return;
            }
            auto t = overwrite ? text.dup : _data[index].text ~ text;
            _data[index] = PositionedScroll(coord, t);
            return;
        }
        if (text.length == 0) return;
        _growIfFull();
        for (size_t i = _n; i > index; i--) _data[i] = _data[i - 1];
        _data[index] = PositionedScroll(coord, text.dup);
        _n += 1;
    }

    void insert(Coordinate coord, const(ubyte)[] text) { update(coord, text, false); }
    void replace(Coordinate coord, const(ubyte)[] text) { update(coord, text, true); }

    private void _removeAt(size_t index) {
        foreach (i; index .. _n - 1) _data[i] = _data[i + 1];
        _n -= 1;
        _data[_n] = PositionedScroll.init;
        _shrinkIfSparse();
    }

    void remove(Coordinate coord) {
        auto f = _find(coord);
        if (f[1]) _removeAt(f[0]);
    }
}

import std.typecons : Tuple;

// ------------------------------------------------------------------
// TransitivePhext: branching hash-map scroll store — one hash map per
// coordinate dimension (9 layers, derived from the coordinate width),
// leaves holding scroll text. Fetch/insert/remove touch one map per
// dimension. Serialization walks sorted keys at every level, which is
// coordinate order, so serialize() is byte-identical to the string
// path.
class BranchingMap {
    private static class Node {
        Node[int] children;
        ubyte[] leaf;
        bool hasLeaf;
    }

    private Node _root;
    private int _depth;
    private size_t _count;

    this(int depth) {
        enforce(depth >= 1, "depth must be >= 1");
        _depth = depth;
        _root = new Node;
    }

    @property size_t length() const { return _count; }
    @property int depth() const { return _depth; }

    ubyte[] fetch(int[9] key) { return _fetch(_root, key, 0); }

    private ubyte[] _fetch(Node node, int[9] key, int level) {
        auto child = key[level] in node.children;
        if (child is null) return null;
        if (level == _depth - 1) return (*child).hasLeaf ? (*child).leaf : null;
        return _fetch(*child, key, level + 1);
    }

    bool contains(int[9] key) { return fetch(key) !is null; }

    // Returns true when a new leaf was created.
    bool put(int[9] key, const(ubyte)[] value) {
        bool created = _put(_root, key, 0, value);
        if (created) _count += 1;
        return created;
    }

    private bool _put(Node node, int[9] key, int level, const(ubyte)[] value) {
        int comp = key[level];
        auto child = comp in node.children;
        if (level == _depth - 1) {
            bool created = child is null || !(*child).hasLeaf;
            if (child is null) { node.children[comp] = new Node; child = comp in node.children; }
            (*child).leaf = value.dup;
            (*child).hasLeaf = true;
            return created;
        }
        if (child is null) { node.children[comp] = new Node; child = comp in node.children; }
        return _put(*child, key, level + 1, value);
    }

    bool remove(int[9] key) {
        bool removed = _remove(_root, key, 0);
        if (removed) _count -= 1;
        return removed;
    }

    private bool _remove(Node node, int[9] key, int level) {
        int comp = key[level];
        auto child = comp in node.children;
        if (child is null) return false;
        if (level == _depth - 1) {
            if (!(*child).hasLeaf) return false;
            node.children.remove(comp);
            return true;
        }
        bool removed = _remove(*child, key, level + 1);
        if (removed && (*child).children.length == 0 && !(*child).hasLeaf)
            node.children.remove(comp);
        return removed;
    }

    // Items in lexicographic (coordinate) order.
    void items(void delegate(int[9], ubyte[]) sink) { _items(_root, [], sink); }

    private void _items(Node node, int[] prefix,
                        void delegate(int[9], ubyte[]) sink) {
        auto keys = node.children.keys;
        sort(keys);
        foreach (comp; keys) {
            auto child = node.children[comp];
            if (child.hasLeaf) {
                int[9] key;
                auto p = prefix ~ comp;
                foreach (i; 0 .. 9) key[i] = p[i];
                sink(key, child.leaf);
            }
            if (child.children.length)
                _items(child, prefix ~ comp, sink);
        }
    }
}

class TransitivePhext {
    private BranchingMap _map;

    this(const(ubyte)[] buffer = null) {
        _map = new BranchingMap(9);
        if (buffer.length) load(buffer);
    }

    @property int depth() const { return _map.depth; }
    @property size_t length() const { return _map.length; }

    void load(const(ubyte)[] buffer) {
        _map = new BranchingMap(9);
        foreach (ps; phokenize(buffer)) _map.put(ps.coord.v, ps.text);
    }

    PositionedScroll[] scrolls() {
        PositionedScroll[] out_;
        _map.items((key, text) { out_ ~= PositionedScroll(Coordinate(key), text); });
        return out_;
    }

    ubyte[] serialize() { return dephokenize(scrolls()); }

    ubyte[] fetch(Coordinate coord) {
        auto val = _map.fetch(coord.v);
        return val is null ? cast(ubyte[])[] : val;
    }

    bool contains(Coordinate coord) { return _map.contains(coord.v); }

    void update(Coordinate coord, const(ubyte)[] text, bool overwrite) {
        if (text.length == 0) {
            if (overwrite) _map.remove(coord.v);
            return;
        }
        auto t = text.dup;
        if (!overwrite) {
            auto existing = _map.fetch(coord.v);
            if (existing !is null) t = existing ~ t;
        }
        _map.put(coord.v, t);
    }

    void insert(Coordinate coord, const(ubyte)[] text) { update(coord, text, false); }
    void replace(Coordinate coord, const(ubyte)[] text) { update(coord, text, true); }
    void remove(Coordinate coord) { _map.remove(coord.v); }
    void append(Coordinate coord, const(ubyte)[] text) { insert(coord, text); }
}
