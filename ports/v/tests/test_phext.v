// Test suite for libphext-v — plain assertions, no framework.
// Run: test_phext [fixtures_dir]
module main

import os

__global (
	checks   int
	failures int
)

fn ok(cond bool, name string) {
	checks += 1
	if !cond {
		failures += 1
		eprintln('FAIL: ${name}')
	}
}

fn eqb(a []u8, b []u8, name string) {
	ok(a == b, name)
}

fn b(s string) []u8 {
	return s.bytes()
}

fn c(s string) Coord {
	return coord_parse(s) or { panic(err) }
}

fn walk_fixtures(dir string) []string {
	mut out := []string{}
	entries := os.ls(dir) or { return out }
	for e in entries {
		p := os.join_path(dir, e)
		if os.is_dir(p) {
			out << walk_fixtures(p)
		} else if e == 'input.phext' {
			out << p
		}
	}
	return out
}

fn main() {
	// coordinate
	ok(coord_parse('1.2.3/4.5.6/7.8.9')!.str() == '1.2.3/4.5.6/7.8.9', 'coord format')
	ok(coord_compare(c('1.1.1/1.1.1/1.1.1'), c('1.1.1/1.1.1/1.1.2')) < 0, 'order scroll')
	ok(coord_compare(c('1.1.1/1.1.1/1.1.9'), c('1.1.1/1.1.2/1.1.1')) < 0, 'order section')
	ok(coord_compare(c('2.1.1/1.1.1/1.1.1'), c('1.9.9/9.9.9/9.9.9')) > 0, 'order library')
	ok(coord_parse('1.1.1/1.1.1/1.1.1')! == coord_root(), 'root')
	if _ := coord_parse('0.1.1/1.1.1/1.1.1') {
		ok(false, 'coord rejects 0')
	} else {
		ok(true, 'coord rejects 0')
	}
	if _ := coord_parse('1.1/1.1.1/1.1.1') {
		ok(false, 'coord rejects short')
	} else {
		ok(true, 'coord rejects short')
	}

	// phokenize
	mut sc := phokenize(b('hello'))
	ok(sc.len == 1, 'one scroll')
	ok(sc[0].coord.str() == '1.1.1/1.1.1/1.1.1', 'first coord')
	eqb(sc[0].text, b('hello'), 'first text')
	sc = phokenize(b('a\x17b\x17\x17c\nline2'))
	ok(sc.len == 3, 'scroll breaks')
	ok(sc[1].coord.str() == '1.1.1/1.1.1/1.1.2', 'second coord')
	ok(sc[2].coord.str() == '1.1.1/1.1.1/1.1.4', 'gap coord advance')
	eqb(sc[2].text, b('c\nline2'), 'newline is ordinary text')
	sc = phokenize(b('x\x01y'))
	ok(sc[1].coord.str() == '2.1.1/1.1.1/1.1.1', 'library break resets')
	sc = phokenize(b('x\x18y'))
	ok(sc[1].coord.str() == '1.1.1/1.1.1/1.2.1', 'section break')
	ok(phokenize(b('')).len == 0, 'empty buffer')
	sc = phokenize([u8(0x61), 0x00, 0xFF, 0x62])
	ok(sc.len == 1 && sc[0].text.len == 4, 'binary text preserved')

	// round trip
	sample := b('alpha\x17beta\x18gamma\x01delta')
	eqb(dephokenize(phokenize(sample)), sample, 'round trip sample')
	built := dephokenize([PositionedScroll{coord: c('1.1.1/1.1.1/1.1.2'), text: b('two')},
		PositionedScroll{coord: c('1.1.1/1.1.1/1.1.1'), text: b('one')}])
	eqb(built, b('one\x17two'), 'dephokenize sorts canonically')
	eqb(normalize(normalize(b('\x17\x17lead'))), normalize(b('\x17\x17lead')), 'normalize idempotent')

	// fetch incl. gaps
	buf := b('one\x17two\x17\x17four')
	eqb(phext_fetch(buf, c('1.1.1/1.1.1/1.1.1')), b('one'), 'fetch 1')
	eqb(phext_fetch(buf, c('1.1.1/1.1.1/1.1.4')), b('four'), 'fetch 4')
	eqb(phext_fetch(buf, c('1.1.1/1.1.1/1.1.3')), b(''), 'gap fetch is empty')
	eqb(phext_fetch(buf, c('9.9.9/9.9.9/9.9.9')), b(''), 'far gap fetch is empty')
	eqb(phext_fetch(b(''), c('1.1.1/1.1.1/1.1.1')), b(''), 'fetch empty buffer')

	// insert
	mut res := phext_insert(b('base'), c('1.1.1/1.1.1/1.1.1'), b('+more'))
	eqb(phext_fetch(res, c('1.1.1/1.1.1/1.1.1')), b('base+more'), 'insert appends after existing')
	res = phext_insert(b(''), c('1.1.1/1.1.1/1.1.3'), b('new'))
	eqb(phext_fetch(res, c('1.1.1/1.1.1/1.1.3')), b('new'), 'insert creates at gap')
	eqb(res, b('\x17\x17new'), 'insert at gap emits breaks')
	res = phext_insert(b('a\x17c'), c('1.1.1/1.1.1/1.1.2'), b('b'))
	eqb(phext_fetch(res, c('1.1.1/1.1.1/1.1.2')), b('cb'), 'insert merges existing + inserted')

	// replace / remove — remove is coordinate-preserving
	res = phext_replace(b('old\x17keep'), c('1.1.1/1.1.1/1.1.1'), b('new'))
	eqb(res, b('new\x17keep'), 'replace overwrites')
	res = phext_replace(b('a'), c('1.1.1/1.1.1/1.1.5'), b('deep'))
	eqb(phext_fetch(res, c('1.1.1/1.1.1/1.1.5')), b('deep'), 'replace creates')
	res = phext_remove(b('a\x17b\x17c'), c('1.1.1/1.1.1/1.1.2'))
	eqb(res, b('a\x17\x17c'), 'remove leaves a gap (no renumbering)')
	eqb(phext_fetch(res, c('1.1.1/1.1.1/1.1.2')), b(''), 'removed coordinate reads empty')
	eqb(phext_fetch(res, c('1.1.1/1.1.1/1.1.3')), b('c'), 'neighbour keeps its coordinate')
	ok(phext_remove(b('only'), c('1.1.1/1.1.1/1.1.1')).len == 0, 'remove sole scroll')
	eqb(phext_remove(b('a'), c('5.5.5/5.5.5/5.5.5')), b('a'), 'remove gap is a no-op')

	// explode / implode
	mp := phext_explode(b('x\x17y'))
	ok(mp.len == 2, 'explode count')
	eqb(phext_implode(mp), b('x\x17y'), 'implode round trip')

	// Dynamic + Transitive equivalence with the string path
	mut dyn := new_dynamic([]u8{})
	mut trn := new_transitive([]u8{})
	mut str_buf := []u8{}
	steps := [
		['insert', '1.1.1/1.1.1/1.1.1', 'alpha'],
		['insert', '1.1.1/1.1.1/1.1.3', 'gamma'],
		['insert', '1.1.1/1.1.1/1.1.2', 'beta'],
		['insert', '1.1.1/1.1.1/1.1.2', '+'],
		['replace', '2.1.1/1.1.1/1.1.1', 'lib2'],
		['remove', '1.1.1/1.1.1/1.1.3', ''],
		['insert', '1.1.1/1.1.1/1.1.1', ''],
		['replace', '1.1.1/1.1.1/1.1.1', ''],
	]
	for st in steps {
		op, cs, tx := st[0], st[1], st[2]
		cc := c(cs)
		t := b(tx)
		match op {
			'insert' {
				str_buf = phext_insert(str_buf, cc, t)
				dyn.insert(cc, t)
				trn.insert(cc, t)
			}
			'replace' {
				str_buf = phext_replace(str_buf, cc, t)
				dyn.replace(cc, t)
				trn.replace(cc, t)
			}
			'remove' {
				str_buf = phext_remove(str_buf, cc)
				dyn.remove(cc)
				trn.remove(cc)
			}
			else {}
		}
		eqb(dyn.serialize(), str_buf, 'dynamic == string after ${op} ${cs}')
		eqb(trn.serialize(), str_buf, 'transitive == string after ${op} ${cs}')
		eqb(dyn.fetch(cc), phext_fetch(str_buf, cc), 'dynamic fetch after op')
		eqb(trn.fetch(cc), phext_fetch(str_buf, cc), 'transitive fetch after op')
	}
	eqb(dyn.fetch(c('1.1.1/1.1.1/1.1.3')), b(''), 'dynamic removed coord is gap')
	eqb(trn.fetch(c('1.1.1/1.1.1/1.1.3')), b(''), 'transitive removed coord is gap')
	eqb(dyn.fetch(c('2.1.1/1.1.1/1.1.1')), b('lib2'), 'dynamic neighbour unmoved')
	eqb(trn.fetch(c('2.1.1/1.1.1/1.1.1')), b('lib2'), 'transitive neighbour unmoved')
	ok(dyn.length() == trn.length(), 'store lengths agree')

	// DynamicPhext capacity discipline
	mut cap := new_dynamic([]u8{})
	for i in 1 .. 65 {
		mut cc := coord_root()
		cc.v[8] = i64(i)
		cap.append(cc, b('s'))
	}
	ok(cap.capacity == 64, 'capacity doubles to fit 64')
	ok(cap.resize_count <= 7, 'resize count is logarithmic')

	// fixtures
	args := os.args[1..]
	if args.len > 0 {
		files := walk_fixtures(args[0])
		mut identical := 0
		mut idem := 0
		for path in files {
			data := os.read_bytes(path) or { continue }
			if dephokenize(phokenize(data)) == data {
				identical += 1
			}
			n1 := normalize(data)
			if normalize(n1) == n1 {
				idem += 1
			}
		}
		println('fixtures: ${files.len} input.phext, ${identical} byte-identical round-trips, ${idem} normalize-idempotent')
		ok(files.len == 16, '16 fixtures found')
		ok(identical == files.len, 'fixtures byte-identical round-trips')
		ok(idem == files.len, 'all fixtures normalize idempotently')
	} else {
		println('fixtures: skipped (no fixtures dir)')
	}

	println('v suite: ${checks} checks, ${failures} failures')
	exit(if failures == 0 { 0 } else { 1 })
}
