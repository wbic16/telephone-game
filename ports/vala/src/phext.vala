// libphext-vala — a Vala port of libphext (0.6.1 parity).
//
// Semantics are normative from libphext-py: a phext is a byte buffer;
// nine dimension-break bytes walk a 9-component coordinate; scroll text
// is a maximal run of non-break bytes (newline 0x0A is ordinary text).
// All buffers are uint8[] so control bytes are never reinterpreted.
// Coordinates are int64[9], ordered lexicographically; string form
// a.b.c/d.e.f/g.h.i.

public class PhextCoord {
    public int64[] v;
    public PhextCoord() { v = new int64[9]; for (int i = 0; i < 9; i++) v[i] = 1; }
    public PhextCoord copy() { var c = new PhextCoord(); for (int i = 0; i < 9; i++) c.v[i] = v[i]; return c; }
    public string to_string() {
        return "%lld.%lld.%lld/%lld.%lld.%lld/%lld.%lld.%lld".printf(
            v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8]);
    }
    public static PhextCoord parse(string s) throws Error {
        var groups = s.strip().split("/");
        if (groups.length != 3) throw new Error(Quark.from_string("coord"), 0, "bad coordinate %s", s);
        var c = new PhextCoord();
        int n = 0;
        foreach (var g in groups) {
            foreach (var p in g.split(".")) {
                if (n >= 9) throw new Error(Quark.from_string("coord"), 0, "bad coordinate %s", s);
                c.v[n++] = int64.parse(p);
            }
        }
        if (n != 9) throw new Error(Quark.from_string("coord"), 0, "bad coordinate %s", s);
        for (int i = 0; i < 9; i++) if (c.v[i] < 1) throw new Error(Quark.from_string("coord"), 0, "bad coordinate %s", s);
        return c;
    }
    public static int compare(PhextCoord a, PhextCoord b) {
        for (int i = 0; i < 9; i++) {
            if (a.v[i] != b.v[i]) return a.v[i] < b.v[i] ? -1 : 1;
        }
        return 0;
    }
    public PhextCoord apply_break(int d) {
        var c = copy();
        c.v[d] += 1;
        for (int k = d + 1; k < 9; k++) c.v[k] = 1;
        return c;
    }
}

public class PositionedScroll {
    public PhextCoord coord;
    public uint8[] text;
    public PositionedScroll(PhextCoord c, uint8[] t) { coord = c; text = t; }
}

// Wrapper so byte arrays can be HashTable values (Vala generics do
// not accept array type arguments).
public class Bytes {
    public uint8[] data;
    public Bytes(uint8[] d) { data = d; }
}

public class Phext {
    public const uint8[] DIMENSION_BREAKS = {0x01, 0x1f, 0x1e, 0x1d, 0x1c, 0x1a, 0x19, 0x18, 0x17};

    public static int break_dim(uint8 b) {
        for (int d = 0; d < 9; d++) if (DIMENSION_BREAKS[d] == b) return d;
        return -1;
    }

    public static PositionedScroll[] phokenize(uint8[] buffer) {
        PositionedScroll[] out = {};
        var coord = new PhextCoord();
        int run_start = 0;
        for (int i = 0; i < buffer.length; i++) {
            int d = break_dim(buffer[i]);
            if (d >= 0) {
                if (i > run_start) out += new PositionedScroll(coord, buffer[run_start:i]);
                coord = coord.apply_break(d);
                run_start = i + 1;
            }
        }
        if (buffer.length > run_start) out += new PositionedScroll(coord, buffer[run_start:buffer.length]);
        return out;
    }

    private static void emit_advance(ByteArray ba, PhextCoord loc, PhextCoord target) {
        if (PhextCoord.compare(loc, target) < 0) {
            int dim = 0;
            while (loc.v[dim] == target.v[dim]) dim++;
            for (int64 j = 0; j < target.v[dim] - loc.v[dim]; j++) {
                uint8[] one = {DIMENSION_BREAKS[dim]};
                ba.append(one);
            }
            for (int lower = dim + 1; lower < 9; lower++) {
                for (int64 j = 0; j < target.v[lower] - 1; j++) {
                    uint8[] one = {DIMENSION_BREAKS[lower]};
                    ba.append(one);
                }
            }
            for (int i = 0; i < 9; i++) loc.v[i] = target.v[i];
        }
    }

    private static void sort_scrolls(PositionedScroll[] arr) {
        for (int i = 1; i < arr.length; i++) {
            var tmp = arr[i];
            int j = i - 1;
            while (j >= 0 && PhextCoord.compare(arr[j].coord, tmp.coord) > 0) { arr[j + 1] = arr[j]; j--; }
            arr[j + 1] = tmp;
        }
    }

    public static uint8[] dephokenize(PositionedScroll[] stack) {
        var sorted = stack;
        sort_scrolls(sorted);
        var ba = new ByteArray();
        var loc = new PhextCoord();
        foreach (var ps in sorted) {
            if (ps.text.length == 0) continue;
            emit_advance(ba, loc, ps.coord);
            ba.append(ps.text);
        }
        return ba.data;
    }

    private static uint8[] dephokenize_in_order(PositionedScroll[] stack) {
        var ba = new ByteArray();
        var loc = new PhextCoord();
        foreach (var ps in stack) {
            emit_advance(ba, loc, ps.coord);
            ba.append(ps.text);
        }
        return ba.data;
    }

    public static uint8[] normalize(uint8[] buffer) { return dephokenize(phokenize(buffer)); }

    public static uint8[] fetch(uint8[] buffer, PhextCoord coord) {
        foreach (var ps in phokenize(buffer))
            if (PhextCoord.compare(ps.coord, coord) == 0) return ps.text;
        return {};
    }

    private static uint8[] update(uint8[] buffer, PhextCoord coord, uint8[] scroll, bool overwrite) {
        var items = phokenize(buffer);
        PositionedScroll[] result = {};
        var next_ps = new PositionedScroll(coord, scroll);
        bool appended = false;
        foreach (var ps in items) {
            int cmp = PhextCoord.compare(ps.coord, coord);
            if (cmp > 0 && !appended) { result += next_ps; appended = true; result += ps; }
            else if (cmp == 0 && !appended) {
                if (overwrite) result += next_ps;
                else {
                    var mba = new ByteArray();
                    mba.append(ps.text);
                    mba.append(scroll);
                    result += new PositionedScroll(coord, mba.data);
                }
                appended = true;
            } else result += ps;
        }
        if (!appended) result += next_ps;
        return dephokenize_in_order(result);
    }

    // insert: existing text is prepended to the inserted text.
    public static uint8[] insert(uint8[] buffer, PhextCoord coord, uint8[] scroll) {
        return update(buffer, coord, scroll, false);
    }
    public static uint8[] replace(uint8[] buffer, PhextCoord coord, uint8[] scroll) {
        return update(buffer, coord, scroll, true);
    }
    // remove: replace with "" then normalize — coordinate-preserving.
    public static uint8[] remove(uint8[] buffer, PhextCoord coord) {
        return normalize(update(buffer, coord, {}, true));
    }

    public static HashTable<string, Bytes> explode(uint8[] buffer) {
        var out = new HashTable<string, Bytes>(str_hash, str_equal);
        foreach (var ps in phokenize(buffer)) out.insert(ps.coord.to_string(), new Bytes(ps.text));
        return out;
    }

    public static uint8[] implode(HashTable<string, Bytes> map) {
        PositionedScroll[] stack = {};
        map.foreach((k, t) => {
            try { stack += new PositionedScroll(PhextCoord.parse(k), t.data); } catch (Error e) {}
        });
        return dephokenize(stack);
    }
}

// ------------------------------------------------------------------
// DynamicPhext: capacity-managed dynamic array scroll store.
public class DynamicPhext {
    private PositionedScroll[] data;
    public int capacity { get; private set; }
    public int resize_count { get; private set; }
    public int64 elements_copied { get; private set; }
    public int shrink_divisor { get; private set; }
    private int n;

    public DynamicPhext(uint8[] buffer = {}, int shrink_divisor = 4) {
        this.shrink_divisor = shrink_divisor;
        data = new PositionedScroll[1];
        capacity = 1; n = 0; resize_count = 0; elements_copied = 0;
        if (buffer.length > 0) load(buffer);
    }
    public int length { get { return n; } }

    private void resize(int new_capacity) {
        var nd = new PositionedScroll[new_capacity];
        for (int i = 0; i < n; i++) nd[i] = data[i];
        data = nd; capacity = new_capacity; resize_count++; elements_copied += n;
    }
    private void grow_if_full() { if (n == capacity) resize(2 * capacity); }
    private void shrink_if_sparse() {
        if (capacity > 1 && n <= capacity / shrink_divisor) resize(int.max(1, capacity / 2));
    }
    private void push(PositionedScroll ps) { grow_if_full(); data[n++] = ps; }

    public void load(uint8[] buffer) {
        data = new PositionedScroll[1]; capacity = 1; n = 0; resize_count = 0; elements_copied = 0;
        foreach (var ps in Phext.phokenize(buffer)) push(ps);
    }
    public PositionedScroll[] scrolls() { return data[0:n]; }
    public uint8[] serialize() { return Phext.dephokenize(scrolls()); }

    private int find(PhextCoord coord, out bool found) {
        int lo = 0, hi = n;
        while (lo < hi) {
            int mid = (lo + hi) / 2;
            int cmp = PhextCoord.compare(data[mid].coord, coord);
            if (cmp < 0) lo = mid + 1;
            else if (cmp > 0) hi = mid;
            else { found = true; return mid; }
        }
        found = false; return lo;
    }
    public uint8[] fetch(PhextCoord coord) {
        bool found; int idx = find(coord, out found);
        if (found) return data[idx].text;
        return new uint8[0];
    }
    public bool contains(PhextCoord coord) { bool f; find(coord, out f); return f; }
    public void append(PhextCoord coord, uint8[] text) {
        if (n > 0 && PhextCoord.compare(coord, data[n - 1].coord) <= 0)
            stderr.printf("append requires a coordinate past the current tail\n");
        else if (text.length > 0) push(new PositionedScroll(coord, text));
    }
    public void update(PhextCoord coord, uint8[] text, bool overwrite) {
        bool found; int idx = find(coord, out found);
        if (found) {
            if (text.length == 0) { if (overwrite) remove_at(idx); }
            else if (overwrite) data[idx] = new PositionedScroll(coord, text);
            else {
                var mba = new ByteArray();
                mba.append(data[idx].text);
                mba.append(text);
                data[idx] = new PositionedScroll(coord, mba.data);
            }
        } else if (text.length > 0) {
            grow_if_full();
            for (int i = n; i > idx; i--) data[i] = data[i - 1];
            data[idx] = new PositionedScroll(coord, text);
            n++;
        }
    }
    public void insert(PhextCoord coord, uint8[] text) { update(coord, text, false); }
    public void replace(PhextCoord coord, uint8[] text) { update(coord, text, true); }
    private void remove_at(int idx) {
        for (int i = idx; i < n - 1; i++) data[i] = data[i + 1];
        n--; shrink_if_sparse();
    }
    public void remove(PhextCoord coord) {
        bool found; int idx = find(coord, out found);
        if (found) remove_at(idx);
    }
}

// ------------------------------------------------------------------
// TransitivePhext: scroll store over a hash map keyed by coordinate
// string; enumeration is always in coordinate order.
public class TransitivePhext {
    private HashTable<string, Bytes> map;
    public TransitivePhext(uint8[] buffer = {}) {
        map = new HashTable<string, Bytes>(str_hash, str_equal);
        if (buffer.length > 0) load(buffer);
    }
    public int length { get { return (int) map.size(); } }
    public void load(uint8[] buffer) {
        map = new HashTable<string, Bytes>(str_hash, str_equal);
        foreach (var ps in Phext.phokenize(buffer)) map.insert(ps.coord.to_string(), new Bytes(ps.text));
    }
    public PositionedScroll[] scrolls() {
        PositionedScroll[] out = {};
        map.foreach((k, t) => {
            try { out += new PositionedScroll(PhextCoord.parse(k), t.data); } catch (Error e) {}
        });
        return out;
    }
    public uint8[] serialize() { return Phext.dephokenize(scrolls()); }
    public uint8[] fetch(PhextCoord coord) {
        var t = map.lookup(coord.to_string());
        if (t != null) return t.data;
        return new uint8[0];
    }
    public bool contains(PhextCoord coord) { return map.contains(coord.to_string()); }
    public void update(PhextCoord coord, uint8[] text, bool overwrite) {
        var k = coord.to_string();
        if (text.length == 0) { if (overwrite) map.remove(k); }
        else if (overwrite) map.insert(k, new Bytes(text));
        else {
            var existing = map.lookup(k);
            if (existing != null) {
                var mba = new ByteArray();
                mba.append(existing.data);
                mba.append(text);
                map.insert(k, new Bytes(mba.data));
            } else map.insert(k, new Bytes(text));
        }
    }
    public void insert(PhextCoord coord, uint8[] text) { update(coord, text, false); }
    public void replace(PhextCoord coord, uint8[] text) { update(coord, text, true); }
    public void remove(PhextCoord coord) { map.remove(coord.to_string()); }
    public void append(PhextCoord coord, uint8[] text) { insert(coord, text); }
}
