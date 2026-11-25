// libphext-v — a V port of libphext (0.6.1 parity).
//
// Semantics are normative from libphext-py: a phext is a byte buffer;
// nine dimension-break bytes walk a 9-component coordinate; scroll text
// is a maximal run of non-break bytes (newline 0x0A is ordinary text).
// All buffers are []u8 so control bytes are never reinterpreted.
// Coordinates are [9]i64, ordered lexicographically; string form
// a.b.c/d.e.f/g.h.i.
module main

pub const dimension_breaks = [u8(0x01), 0x1f, 0x1e, 0x1d, 0x1c, 0x1a, 0x19, 0x18, 0x17]

pub struct Coord {
pub mut:
	v [9]i64
}

pub fn coord_root() Coord {
	return Coord{v: [i64(1), 1, 1, 1, 1, 1, 1, 1, 1]!}
}

pub fn coord_parse(s string) !Coord {
	groups := s.trim_space().split('/')
	if groups.len != 3 {
		return error('coordinate must be a.b.c/d.e.f/g.h.i: ${s}')
	}
	mut nums := []i64{cap: 9}
	for g in groups {
		for p in g.split('.') {
			nums << p.i64()
		}
	}
	if nums.len != 9 {
		return error('coordinate needs 9 parts: ${s}')
	}
	for n in nums {
		if n < 1 {
			return error('components must be >= 1: ${s}')
		}
	}
	mut c := coord_root()
	for i in 0 .. 9 {
		c.v[i] = nums[i]
	}
	return c
}

pub fn (c Coord) str() string {
	return '${c.v[0]}.${c.v[1]}.${c.v[2]}/${c.v[3]}.${c.v[4]}.${c.v[5]}/${c.v[6]}.${c.v[7]}.${c.v[8]}'
}

pub fn coord_compare(a Coord, b Coord) int {
	for i in 0 .. 9 {
		if a.v[i] != b.v[i] {
			return if a.v[i] < b.v[i] { -1 } else { 1 }
		}
	}
	return 0
}

pub fn coord_apply_break(c Coord, d int) Coord {
	mut out := c
	out.v[d] += 1
	for k in d + 1 .. 9 {
		out.v[k] = 1
	}
	return out
}

fn break_dim(b u8) int {
	for d, db in dimension_breaks {
		if db == b {
			return d
		}
	}
	return -1
}

pub struct PositionedScroll {
pub:
	coord Coord
	text  []u8
}

pub fn phokenize(buffer []u8) []PositionedScroll {
	mut out := []PositionedScroll{}
	mut coord := coord_root()
	mut run_start := 0
	for i, b in buffer {
		d := break_dim(b)
		if d >= 0 {
			if i > run_start {
				out << PositionedScroll{coord: coord, text: buffer[run_start..i].clone()}
			}
			coord = coord_apply_break(coord, d)
			run_start = i + 1
		}
	}
	if buffer.len > run_start {
		out << PositionedScroll{coord: coord, text: buffer[run_start..].clone()}
	}
	return out
}

fn emit_advance(mut out []u8, loc Coord, target Coord) Coord {
	if coord_compare(loc, target) < 0 {
		mut dim := 0
		for loc.v[dim] == target.v[dim] {
			dim += 1
		}
		for _ in 0 .. (target.v[dim] - loc.v[dim]) {
			out << dimension_breaks[dim]
		}
		for lower in dim + 1 .. 9 {
			for _ in 0 .. (target.v[lower] - 1) {
				out << dimension_breaks[lower]
			}
		}
	}
	return target
}

pub fn dephokenize(stack []PositionedScroll) []u8 {
	mut sorted := stack.clone()
	sorted.sort_with_compare(fn (a &PositionedScroll, b &PositionedScroll) int {
		return coord_compare(a.coord, b.coord)
	})
	mut out := []u8{}
	mut loc := coord_root()
	for ps in sorted {
		if ps.text.len == 0 {
			continue
		}
		loc = emit_advance(mut out, loc, ps.coord)
		out << ps.text
	}
	return out
}

fn dephokenize_in_order(stack []PositionedScroll) []u8 {
	mut out := []u8{}
	mut loc := coord_root()
	for ps in stack {
		loc = emit_advance(mut out, loc, ps.coord)
		out << ps.text
	}
	return out
}

pub fn normalize(buffer []u8) []u8 {
	return dephokenize(phokenize(buffer))
}

pub fn phext_fetch(buffer []u8, coord Coord) []u8 {
	for ps in phokenize(buffer) {
		if coord_compare(ps.coord, coord) == 0 {
			return ps.text
		}
	}
	return []u8{}
}

fn phext_update(buffer []u8, coord Coord, scroll []u8, overwrite bool) []u8 {
	items := phokenize(buffer)
	mut result := []PositionedScroll{}
	next_ps := PositionedScroll{coord: coord, text: scroll}
	mut appended := false
	for ps in items {
		cmp := coord_compare(ps.coord, coord)
		if cmp > 0 && !appended {
			result << next_ps
			appended = true
			result << ps
		} else if cmp == 0 && !appended {
			if overwrite {
				result << next_ps
			} else {
				mut merged := ps.text.clone()
				merged << scroll
				result << PositionedScroll{coord: coord, text: merged}
			}
			appended = true
		} else {
			result << ps
		}
	}
	if !appended {
		result << next_ps
	}
	return dephokenize_in_order(result)
}

// insert: existing text is prepended to the inserted text.
pub fn phext_insert(buffer []u8, coord Coord, scroll []u8) []u8 {
	return phext_update(buffer, coord, scroll, false)
}

pub fn phext_replace(buffer []u8, coord Coord, scroll []u8) []u8 {
	return phext_update(buffer, coord, scroll, true)
}

// remove: replace with "" then normalize — coordinate-preserving:
// the removed coordinate reads "" and neighbours do not shift.
pub fn phext_remove(buffer []u8, coord Coord) []u8 {
	return normalize(phext_update(buffer, coord, []u8{}, true))
}

pub fn phext_explode(buffer []u8) map[string][]u8 {
	mut out := map[string][]u8{}
	for ps in phokenize(buffer) {
		out[ps.coord.str()] = ps.text
	}
	return out
}

pub fn phext_implode(m map[string][]u8) []u8 {
	mut stack := []PositionedScroll{}
	for k, t in m {
		stack << PositionedScroll{coord: coord_parse(k) or { coord_root() }, text: t}
	}
	return dephokenize(stack)
}

// ------------------------------------------------------------------
// DynamicPhext: capacity-managed dynamic array scroll store.
// Start at capacity 1, double when full on append, shrink only at
// quarter load (never half — that thrashes).
pub struct DynamicPhext {
pub mut:
	capacity        int = 1
	resize_count    int
	elements_copied i64
	shrink_divisor  int = 4
mut:
	data []PositionedScroll
	n    int
}

pub fn new_dynamic(buffer []u8) DynamicPhext {
	mut d := DynamicPhext{data: []PositionedScroll{len: 1}}
	if buffer.len > 0 {
		d.load(buffer)
	}
	return d
}

pub fn (d &DynamicPhext) length() int {
	return d.n
}

fn (mut d DynamicPhext) resize(new_capacity int) {
	mut nd := []PositionedScroll{len: new_capacity}
	for i in 0 .. d.n {
		nd[i] = d.data[i]
	}
	d.data = nd
	d.capacity = new_capacity
	d.resize_count += 1
	d.elements_copied += d.n
}

fn (mut d DynamicPhext) grow_if_full() {
	if d.n == d.capacity {
		d.resize(2 * d.capacity)
	}
}

fn (mut d DynamicPhext) shrink_if_sparse() {
	if d.capacity > 1 && d.n <= d.capacity / d.shrink_divisor {
		mut nc := d.capacity / 2
		if nc < 1 {
			nc = 1
		}
		d.resize(nc)
	}
}

fn (mut d DynamicPhext) push(ps PositionedScroll) {
	d.grow_if_full()
	d.data[d.n] = ps
	d.n += 1
}

pub fn (mut d DynamicPhext) load(buffer []u8) {
	d.capacity = 1
	d.data = []PositionedScroll{len: 1}
	d.n = 0
	d.resize_count = 0
	d.elements_copied = 0
	for ps in phokenize(buffer) {
		d.push(ps)
	}
}

pub fn (d &DynamicPhext) scrolls() []PositionedScroll {
	return d.data[..d.n].clone()
}

pub fn (d &DynamicPhext) serialize() []u8 {
	return dephokenize(d.scrolls())
}

fn (d &DynamicPhext) find(coord Coord) (int, bool) {
	mut lo := 0
	mut hi := d.n
	for lo < hi {
		mid := (lo + hi) / 2
		cmp := coord_compare(d.data[mid].coord, coord)
		if cmp < 0 {
			lo = mid + 1
		} else if cmp > 0 {
			hi = mid
		} else {
			return mid, true
		}
	}
	return lo, false
}

pub fn (d &DynamicPhext) fetch(coord Coord) []u8 {
	idx, found := d.find(coord)
	if found {
		return d.data[idx].text
	}
	return []u8{}
}

pub fn (d &DynamicPhext) contains(coord Coord) bool {
	_, found := d.find(coord)
	return found
}

pub fn (mut d DynamicPhext) append(coord Coord, text []u8) {
	if d.n > 0 && coord_compare(coord, d.data[d.n - 1].coord) <= 0 {
		panic('append requires a coordinate past the current tail')
	}
	if text.len > 0 {
		d.push(PositionedScroll{coord: coord, text: text})
	}
}

pub fn (mut d DynamicPhext) update(coord Coord, text []u8, overwrite bool) {
	idx, found := d.find(coord)
	if found {
		if text.len == 0 {
			if overwrite {
				d.remove_at(idx)
			}
		} else if overwrite {
			d.data[idx] = PositionedScroll{coord: coord, text: text}
		} else {
			mut merged := d.data[idx].text.clone()
			merged << text
			d.data[idx] = PositionedScroll{coord: coord, text: merged}
		}
	} else if text.len > 0 {
		d.grow_if_full()
		mut i := d.n
		for i > idx {
			d.data[i] = d.data[i - 1]
			i -= 1
		}
		d.data[idx] = PositionedScroll{coord: coord, text: text}
		d.n += 1
	}
}

pub fn (mut d DynamicPhext) insert(coord Coord, text []u8) {
	d.update(coord, text, false)
}

pub fn (mut d DynamicPhext) replace(coord Coord, text []u8) {
	d.update(coord, text, true)
}

fn (mut d DynamicPhext) remove_at(idx int) {
	mut i := idx
	for i < d.n - 1 {
		d.data[i] = d.data[i + 1]
		i += 1
	}
	d.n -= 1
	d.shrink_if_sparse()
}

pub fn (mut d DynamicPhext) remove(coord Coord) {
	idx, found := d.find(coord)
	if found {
		d.remove_at(idx)
	}
}

// ------------------------------------------------------------------
// TransitivePhext: scroll store over a branching map keyed by the
// coordinate string (V maps are the native branching store here);
// items are always enumerated in lexicographic coordinate order.
pub struct TransitivePhext {
pub mut:
	m map[string][]u8
}

pub fn new_transitive(buffer []u8) TransitivePhext {
	mut t := TransitivePhext{m: map[string][]u8{}}
	if buffer.len > 0 {
		t.load(buffer)
	}
	return t
}

pub fn (t &TransitivePhext) length() int {
	return t.m.len
}

pub fn (mut t TransitivePhext) load(buffer []u8) {
	t.m = map[string][]u8{}
	for ps in phokenize(buffer) {
		t.m[ps.coord.str()] = ps.text
	}
}

pub fn (t &TransitivePhext) scrolls() []PositionedScroll {
	mut keys := t.m.keys()
	keys.sort_with_compare(fn (a &string, b &string) int {
		ca := coord_parse(a) or { coord_root() }
		cb := coord_parse(b) or { coord_root() }
		return coord_compare(ca, cb)
	})
	mut out := []PositionedScroll{}
	for k in keys {
		out << PositionedScroll{coord: coord_parse(k) or { coord_root() }, text: t.m[k]}
	}
	return out
}

pub fn (t &TransitivePhext) serialize() []u8 {
	return dephokenize(t.scrolls())
}

pub fn (t &TransitivePhext) fetch(coord Coord) []u8 {
	return t.m[coord.str()] or { []u8{} }
}

pub fn (t &TransitivePhext) contains(coord Coord) bool {
	return coord.str() in t.m
}

pub fn (mut t TransitivePhext) update(coord Coord, text []u8, overwrite bool) {
	k := coord.str()
	if text.len == 0 {
		if overwrite {
			t.m.delete(k)
		}
	} else if overwrite {
		t.m[k] = text
	} else {
		if k in t.m {
			mut merged := t.m[k].clone()
			merged << text
			t.m[k] = merged
		} else {
			t.m[k] = text
		}
	}
}

pub fn (mut t TransitivePhext) insert(coord Coord, text []u8) {
	t.update(coord, text, false)
}

pub fn (mut t TransitivePhext) replace(coord Coord, text []u8) {
	t.update(coord, text, true)
}

pub fn (mut t TransitivePhext) remove(coord Coord) {
	t.m.delete(coord.str())
}

pub fn (mut t TransitivePhext) append(coord Coord, text []u8) {
	t.insert(coord, text)
}
