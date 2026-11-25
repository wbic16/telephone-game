// Hub-side CLI for libphext-v (Exocortical Telephone Game, contract v2).
//
// Transport: with the argument `serve`, stdin carries one JSON request
// per line and stdout carries one JSON response per line. With no
// argument, stdin carries ONE JSON object and stdout ONE response.
// State crosses the wire as base64 under "state". Serve lines over
// 8 KB travel GZ1-framed: "GZ1:" + base64(gzip(line)).
//
// This CLI wraps only this port's own libphext (src/phext.v). JSON is
// hand-written here (canonical form must match the harness's Python
// json.dumps exactly); SHA-256/base64/gzip are V's standard library;
// PGP goes through subprocess gpg with a per-port GNUPGHOME
// (~/telephone-v/gnupg unless TELEPHONE_GNUPGHOME).
module main

import crypto.sha256
import encoding.base64
import compress.gzip
import os

const impl = 'v'
const index_coord_s = '1.1.1/1.1.1/1.1.1'
const keys_coord_s = '1.1.1/1.1.1/1.1.2'
const kh_coord_s = '1.1.1/1.1.1/1.1.3'

// ---------------------------------------------------------------- JSON
enum JKind {
	null_
	boolean
	integer
	float_
	str
	arr
	obj
}

struct JVal {
mut:
	kind JKind
	b    bool
	i    i64
	f    f64
	s    string
	a    []JVal
	o    map[string]JVal
}

fn jnull() JVal {
	return JVal{kind: .null_}
}
fn jstr(s string) JVal {
	return JVal{kind: .str, s: s}
}
fn jint(i i64) JVal {
	return JVal{kind: .integer, i: i}
}
fn jbool(b bool) JVal {
	return JVal{kind: .boolean, b: b}
}
fn jarr(a []JVal) JVal {
	return JVal{kind: .arr, a: a}
}
fn jobj(o map[string]JVal) JVal {
	return JVal{kind: .obj, o: o}
}

struct JParser {
mut:
	s   string
	pos int
}

fn (mut p JParser) skip_ws() {
	for p.pos < p.s.len && p.s[p.pos] in [` `, `\t`, `\n`, `\r`] {
		p.pos += 1
	}
}

fn (mut p JParser) parse() !JVal {
	v := p.value()!
	p.skip_ws()
	return v
}

fn (mut p JParser) value() !JVal {
	p.skip_ws()
	if p.pos >= p.s.len {
		return error('unexpected eof')
	}
	c := p.s[p.pos]
	return match c {
		`{` { p.parse_obj()! }
		`[` { p.parse_arr()! }
		`"` { jstr(p.parse_str()!) }
		`t` { p.expect_word('true')!; jbool(true) }
		`f` { p.expect_word('false')!; jbool(false) }
		`n` { p.expect_word('null')!; jnull() }
		else { p.parse_num()! }
	}
}

fn (mut p JParser) expect_word(w string) ! {
	for ch in w {
		if p.pos >= p.s.len || p.s[p.pos] != ch {
			return error('bad literal')
		}
		p.pos += 1
	}
}

fn (mut p JParser) parse_obj() !JVal {
	p.pos += 1 // {
	p.skip_ws()
	mut out := map[string]JVal{}
	if p.pos < p.s.len && p.s[p.pos] == `}` {
		p.pos += 1
		return jobj(out)
	}
	for {
		p.skip_ws()
		k := p.parse_str()!
		p.skip_ws()
		if p.s[p.pos] != `:` {
			return error('expected :')
		}
		p.pos += 1
		out[k] = p.value()!
		p.skip_ws()
		c := p.s[p.pos]
		p.pos += 1
		if c == `}` {
			break
		}
		if c != `,` {
			return error('expected , or }')
		}
	}
	return jobj(out)
}

fn (mut p JParser) parse_arr() !JVal {
	p.pos += 1 // [
	p.skip_ws()
	mut out := []JVal{}
	if p.pos < p.s.len && p.s[p.pos] == `]` {
		p.pos += 1
		return jarr(out)
	}
	for {
		out << p.value()!
		p.skip_ws()
		c := p.s[p.pos]
		p.pos += 1
		if c == `]` {
			break
		}
		if c != `,` {
			return error('expected , or ]')
		}
	}
	return jarr(out)
}

fn (mut p JParser) parse_str() !string {
	p.pos += 1 // "
	mut out := []u8{}
	for {
		if p.pos >= p.s.len {
			return error('unterminated string')
		}
		c := p.s[p.pos]
		p.pos += 1
		if c == `"` {
			break
		}
		if c == `\\` {
			e := p.s[p.pos]
			p.pos += 1
			match e {
				`n` { out << u8(`\n`) }
				`r` { out << u8(`\r`) }
				`t` { out << u8(`\t`) }
				`b` { out << u8(8) }
				`f` { out << u8(12) }
				`/` { out << u8(`/`) }
				`u` {
					mut cp := p.s[p.pos..p.pos + 4].parse_int(16, 32)!
					p.pos += 4
					if cp >= 0xD800 && cp <= 0xDBFF && p.pos + 6 <= p.s.len
						&& p.s[p.pos] == `\\` && p.s[p.pos + 1] == `u` {
						lo := p.s[p.pos + 2..p.pos + 6].parse_int(16, 32)!
						if lo >= 0xDC00 && lo <= 0xDFFF {
							p.pos += 6
							cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
						}
					}
					r := rune(cp)
					out << r.bytes()
				}
				else { out << e }
			}
		} else {
			out << c
		}
	}
	return out.bytestr()
}

fn (mut p JParser) parse_num() !JVal {
	start := p.pos
	for p.pos < p.s.len && p.s[p.pos] in [`-`, `+`, `0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`, `.`, `e`, `E`] {
		p.pos += 1
	}
	txt := p.s[start..p.pos]
	if txt.contains_any('eE.') {
		return JVal{kind: .float_, f: txt.f64()}
	}
	return jint(txt.i64())
}

// Matches Python json.dumps(..., ensure_ascii=True) escaping.
fn json_escape(s string) string {
	mut sb := []u8{}
	sb << u8(`"`)
	for cp in s.runes() {
		match int(cp) {
			0x22 { sb << '\\"'.bytes() }
			0x5C { sb << '\\\\'.bytes() }
			0x0A { sb << '\\n'.bytes() }
			0x0D { sb << '\\r'.bytes() }
			0x09 { sb << '\\t'.bytes() }
			0x08 { sb << '\\b'.bytes() }
			0x0C { sb << '\\f'.bytes() }
			else {
				v := int(cp)
				if v < 0x20 || v > 0x7E {
					if v > 0xFFFF {
						x := v - 0x10000
						sb << ('\\u' + (0xD800 + (x >> 10)).hex()).bytes()
						sb << ('\\u' + (0xDC00 + (x & 0x3FF)).hex()).bytes()
					} else {
						h := v.hex()
						sb << ('\\u' + '0'.repeat(4 - h.len) + h).bytes()
					}
				} else {
					sb << u8(v)
				}
			}
		}
	}
	sb << u8(`"`)
	return sb.bytestr()
}

fn json_write(v JVal) string {
	match v.kind {
		.null_ { return 'null' }
		.boolean { return v.b.str() }
		.integer { return v.i.str() }
		.float_ { return v.f.str() }
		.str { return json_escape(v.s) }
		.arr {
			mut parts := []string{}
			for x in v.a {
				parts << json_write(x)
			}
			return '[' + parts.join(',') + ']'
		}
		.obj {
			mut keys := v.o.keys()
			keys.sort()
			mut parts := []string{}
			for k in keys {
				parts << json_escape(k) + ':' + json_write(v.o[k])
			}
			return '{' + parts.join(',') + '}'
		}
	}
}

fn canon_bytes(v JVal) []u8 {
	return json_write(v).bytes()
}

// ---------------------------------------------------------------- util
fn sha256hex(bs []u8) string {
	return sha256.sum(bs).hex()
}

fn state_of(req JVal) []u8 {
	s := req.o['state'] or { req.o['state_b64'] or { jstr('') } }
	return base64.decode(s.s)
}

fn sh(cmd string) !string {
	r := os.execute(cmd)
	if r.exit_code != 0 {
		return error('command failed (${r.exit_code}): ${cmd}: ${r.output}')
	}
	return r.output
}

fn tmpfile(tag string, data []u8) string {
	path := os.join_path(os.temp_dir(), 'telv-${tag}-${os.getpid()}-${data.len}.tmp')
	os.write_file_array(path, data) or { panic(err) }
	return path
}

// ---------------------------------------------------------------- gpg
fn gnupg_home() string {
	home := os.getenv_opt('TELEPHONE_GNUPGHOME') or {
		os.join_path(os.home_dir(), 'telephone-${impl}', 'gnupg')
	}
	os.mkdir_all(home, mode: 0o700) or {}
	os.chmod(home, 0o700) or {}
	return home
}

fn run_gpg(args string, input []u8) ![]u8 {
	home := gnupg_home()
	in_f := tmpfile('gpgin', input)
	out_f := in_f + '.out'
	defer {
		os.rm(in_f) or {}
		os.rm(out_f) or {}
	}
	sh('GNUPGHOME=${home} gpg --batch --yes ${args} < ${in_f} > ${out_f}')!
	return os.read_bytes(out_f)
}

fn do_keygen() !JVal {
	uid := 'telephone-${impl}'
	keys := run_gpg('--list-keys --with-colons', []u8{})!.bytestr()
	if !keys.contains('pub') {
		run_gpg('--pinentry-mode loopback --passphrase "" --quick-generate-key ${uid} ed25519 sign never',
			[]u8{})!
	}
	pubkey_str := run_gpg('--armor --export ${uid}', []u8{})!.bytestr()
	return jobj({'impl': jstr(impl), 'pubkey': jstr(pubkey_str)})
}

fn do_attest(descriptor JVal) !JVal {
	uid := 'telephone-${impl}'
	sig := run_gpg('--pinentry-mode loopback --passphrase "" --detach-sign --armor -u ${uid}',
		canon_bytes(descriptor))!
	return jobj({'signature': jstr(sig.bytestr())})
}

fn verify_signature(pubkeys_text string, data []u8, sig_b64 string) bool {
	dir := os.join_path(os.temp_dir(), 'telv-verify-${os.getpid()}')
	home := os.join_path(dir, 'gnupg')
	os.mkdir_all(home, mode: 0o700) or { return false }
	os.chmod(home, 0o700) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	keys_f := tmpfile('keys', pubkeys_text.bytes())
	sig_f := tmpfile('sig', base64.decode(sig_b64))
	data_f := tmpfile('data', data)
	defer {
		os.rm(keys_f) or {}
		os.rm(sig_f) or {}
		os.rm(data_f) or {}
	}
	if (os.execute('GNUPGHOME=${home} gpg --batch --import ${keys_f}')).exit_code != 0 {
		return false
	}
	return (os.execute('GNUPGHOME=${home} gpg --batch --verify ${sig_f} ${data_f}')).exit_code == 0
}

// ---------------------------------------------------------------- game
struct Cache {
mut:
	map_  map[string][]u8
	hash  string
	has   bool
}

__global (
	cache Cache
)

fn do_echo(ping JVal) JVal {
	h := sha256hex(canon_bytes(jobj({'impl': jstr(impl), 'ping': ping})))
	return jobj({'impl': jstr(impl), 'echo': jstr(h)})
}

fn do_elect(position string, candidates []JVal, turn i64) JVal {
	mut names := []string{}
	for c in candidates {
		names << c.s
	}
	mut pool := names.filter(it != impl)
	if pool.len == 0 {
		pool = names.clone()
	}
	seed := sha256hex('${impl}-elect:${position}:${turn}:${names.join(',')}'.bytes())
	idx := (seed[0..8].parse_int(16, 64) or { 0 }) % i64(pool.len)
	return jobj({'elect': jstr(pool[int(idx)])})
}

fn do_choose(data []u8, position string, turn i64) !JVal {
	m := phext_explode(data)
	mut pos := coord_parse(position)!
	for pos.str() in m {
		pos.v[8] += 1
	}
	return jobj({
		'op':         jstr('insert')
		'coordinate': jstr(pos.str())
		'text':       jstr('${impl} was here, turn ${turn}')
	})
}

fn do_apply(data []u8, step JVal) !JVal {
	coord := coord_parse(step.o['coordinate'].s)!
	m := phext_explode(data)
	if coord.str() in m {
		return error('coordinate already occupied')
	}
	mut m2 := m.clone()
	m2[coord.str()] = step.o['text'].s.bytes()
	result := phext_implode(m2)
	return jobj({
		'state_b64':    jstr(base64.encode(result))
		'state_sha256': jstr(sha256hex(result))
	})
}

fn do_init(data []u8) JVal {
	cache.map_ = phext_explode(data)
	cache.hash = sha256hex(data)
	cache.has = true
	return jobj({'impl': jstr(impl), 'verdict': jstr('pass')})
}

fn vfail(detail string) JVal {
	return jobj({'impl': jstr(impl), 'verdict': jstr('fail'), 'detail': jstr(detail)})
}

fn do_validate(data []u8, step JVal, event_coord_s string, index_line string) !JVal {
	nmap := phext_explode(data)
	coord := coord_parse(step.o['coordinate'].s)!
	ev := coord_parse(event_coord_s)!
	if !cache.has {
		return error('validate before init')
	}
	old := cache.map_.clone()
	placed := nmap[coord.str()] or { return vfail('placed scroll missing or altered') }
	if placed.bytestr() != step.o['text'].s {
		return vfail('placed scroll missing or altered')
	}
	for c, t in old {
		if c == index_coord_s {
			continue
		}
		nv := nmap[c] or { return vfail('prior scroll overwritten at ${c}') }
		if nv != t {
			return vfail('prior scroll overwritten at ${c}')
		}
	}
	for c in nmap.keys() {
		if c !in old && c != coord.str() && c != ev.str() {
			return vfail('unexpected new scroll at ${c}')
		}
	}
	idx := (nmap[index_coord_s] or { []u8{} }).bytestr()
	if !idx.trim_right('\n').ends_with(index_line.trim_right('\n')) {
		return vfail('index does not record the placement')
	}
	cache.map_ = nmap.clone()
	cache.hash = sha256hex(data)
	return jobj({'impl': jstr(impl), 'verdict': jstr('pass')})
}

fn vfail_n(n int, msg string) JVal {
	return jobj({
		'impl':               jstr(impl)
		'verdict':            jstr('fail')
		'placements_checked': jint(i64(n))
		'first_failure':      jobj({'detail': jstr(msg)})
	})
}

fn do_verify(data []u8) !JVal {
	m := phext_explode(data)
	keys_text := (m[keys_coord_s] or { []u8{} }).bytestr()
	kh := (m[kh_coord_s] or { []u8{} }).bytestr().trim_space()
	if sha256hex(keys_text.bytes()) != kh {
		return vfail_n(0, 'keys-hash scroll does not match keys')
	}
	mut events := map[int]JVal{}
	for c, t in m {
		coord := coord_parse(c)!
		if coord.v[0] == 1 && coord.v[1] == 1 && coord.v[2] == 1 && coord.v[3] == 1
			&& coord.v[4] == 1 && coord.v[5] == 1 && coord.v[6] == 2 && coord.v[7] == 1 {
			mut p := JParser{s: t.bytestr()}
			events[int(coord.v[8])] = p.parse()!
		}
	}
	mut prev_hash := jnull()
	mut placements := map[string]JVal{}
	mut seqs := events.keys()
	seqs.sort()
	for i, s in seqs {
		if s != i + 1 {
			return vfail_n(placements.len, 'event seq gap at ${s}')
		}
		ev := events[s]
		prev := ev.o['prev'] or { jnull() }
		if json_write(prev) != json_write(prev_hash) {
			return vfail_n(placements.len, 'event chain broken at seq ${s}')
		}
		body := ev.o['body']
		prev_hash = jstr(sha256hex(canon_bytes(body)))
		if (body.o['type'] or { jnull() }).s != 'placement' {
			continue
		}
		cs := body.o['coord'].s
		if cs in placements {
			return vfail_n(placements.len, 'coordinate reused at seq ${s}')
		}
		t := m[cs] or { return vfail_n(placements.len, 'placement scroll hash mismatch seq ${s}') }
		if sha256hex(t) != body.o['text_sha256'].s {
			return vfail_n(placements.len, 'placement scroll hash mismatch seq ${s}')
		}
		desc := jobj({
			'turn':          body.o['turn']
			'coordinate':    jstr(cs)
			'scroll_sha256': body.o['text_sha256']
			'file_sha256':   body.o['file_sha256']
		})
		if !verify_signature(keys_text, canon_bytes(desc), body.o['att'].s) {
			return vfail_n(placements.len, 'attestation fails at seq ${s}')
		}
		placements[cs] = body
	}
	idx_text := (m[index_coord_s] or { []u8{} }).bytestr()
	mut idx_lines := []string{}
	for ln in idx_text.split('\n') {
		if ln.len > 0 && !ln.starts_with('#') {
			idx_lines << ln
		}
	}
	if idx_lines.len != placements.len {
		return vfail_n(placements.len, 'index lines != placements')
	}
	for ln in idx_lines {
		parts := ln.split_nth(' ', 4)
		body := placements[parts[1]] or {
			return vfail_n(placements.len, 'index hash mismatch: ${ln[..40]}')
		}
		if body.o['text_sha256'].s != parts[2] {
			return vfail_n(placements.len, 'index hash mismatch: ${ln[..40]}')
		}
	}
	return jobj({
		'impl':               jstr(impl)
		'verdict':            jstr('pass')
		'placements_checked': jint(i64(placements.len))
		'first_failure':      jnull()
	})
}

// ---------------------------------------------------------------- dispatch
fn dispatch(req JVal) !JVal {
	cmd := req.o['cmd'].s
	return match cmd {
		'id' { jobj({'impl': jstr(impl)}) }
		'keygen' { do_keygen()! }
		'echo' { do_echo(req.o['ping']) }
		'elect' {
			do_elect(req.o['position'].s, req.o['candidates'].a, req.o['turn'].i)
		}
		'choose' {
			do_choose(state_of(req), req.o['position'].s, req.o['turn'].i)!
		}
		'apply' { do_apply(state_of(req), req.o['step'])! }
		'attest' { do_attest(req.o['descriptor'])! }
		'init' { do_init(state_of(req)) }
		'validate' {
			do_validate(state_of(req), req.o['step'], req.o['event_coord'].s,
				req.o['index_line'].s)!
		}
		'verify' { do_verify(state_of(req))! }
		else { return error('unknown cmd ${cmd}') }
	}
}

fn handle_line(line string) string {
	mut p := JParser{s: line}
	req := p.parse() or {
		return json_write(jobj({'error': jstr('parse: ${err}')}))
	}
	resp := dispatch(req) or {
		return json_write(jobj({'error': jstr('${err}')}))
	}
	out := json_write(resp)
	if out.len > 8192 {
		comp := gzip.compress(out.bytes()) or { return out }
		return 'GZ1:' + base64.encode(comp)
	}
	return out
}

fn unframe(line string) string {
	if line.starts_with('GZ1:') {
		data := gzip.decompress(base64.decode(line[4..])) or { return line }
		return data.bytestr()
	}
	return line
}

fn main() {
	args := os.args[1..]
	if args.len > 0 && args[0] == 'serve' {
		for {
			line := os.get_line()
			if line.len == 0 {
				break
			}
			trimmed := line.trim_space()
			if trimmed.len == 0 {
				continue
			}
			println(handle_line(unframe(trimmed)))
			os.flush()
		}
	} else {
		mut text := ''
		for {
			ln := os.get_line()
			if ln.len == 0 {
				break
			}
			text += ln
		}
		trimmed := text.trim_space()
		if trimmed.len > 0 {
			println(handle_line(unframe(trimmed)))
		}
	}
}
