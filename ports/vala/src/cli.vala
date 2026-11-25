// Hub-side CLI for libphext-vala (Exocortical Telephone Game,
// contract v2).
//
// Transport: with the argument `serve`, stdin carries one JSON
// request per line and stdout carries one JSON response per line.
// With no argument, stdin carries ONE JSON object and stdout ONE
// response. State crosses the wire as base64 under "state". Serve
// lines over 8 KB travel GZ1-framed: "GZ1:" + base64(gzip(line)).
//
// This CLI wraps only this port's own libphext (src/phext.vala). JSON
// is hand-written here (canonical form must match the harness's
// Python json.dumps exactly); SHA-256 is GLib's GChecksum, Base64 is
// GLib's; gzip framing shells to gzip(1) on temp files; PGP goes
// through subprocess gpg with a per-port GNUPGHOME
// (~/telephone-vala/gnupg unless TELEPHONE_GNUPGHOME).

const string IMPL = "vala";
const string INDEX_COORD_S = "1.1.1/1.1.1/1.1.1";
const string KEYS_COORD_S = "1.1.1/1.1.1/1.1.2";
const string KH_COORD_S = "1.1.1/1.1.1/1.1.3";

// ---------------------------------------------------------------- JSON
public enum JKind { NULL, BOOL, INT, FLOAT, STR, ARR, OBJ }

public class JVal {
    public JKind kind;
    public bool b;
    public int64 i;
    public double f;
    public string s;
    public JVal[] a;
    public HashTable<string, JVal> o;
    public JVal(JKind k) { kind = k; s = ""; a = {}; o = new HashTable<string, JVal>(str_hash, str_equal); }
    public static JVal nullv() { return new JVal(JKind.NULL); }
    public static JVal strv(string s) { var v = new JVal(JKind.STR); v.s = s; return v; }
    public static JVal intv(int64 i) { var v = new JVal(JKind.INT); v.i = i; return v; }
    public static JVal boolv(bool b) { var v = new JVal(JKind.BOOL); v.b = b; return v; }
    public static JVal arrv(JVal[] a) { var v = new JVal(JKind.ARR); v.a = a; return v; }
    public static JVal objv() { return new JVal(JKind.OBJ); }
    public JVal get(string key) { var v = o.lookup(key); return v != null ? v : nullv(); }
}

public class JParser {
    private string s;
    private int pos;
    private int len;
    public JParser(string s) { this.s = s; pos = 0; len = s.length; }
    private void skip_ws() {
        while (pos < len && (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n' || s[pos] == '\r')) pos++;
    }
    public JVal parse() throws Error { var v = value(); skip_ws(); return v; }
    private JVal value() throws Error {
        skip_ws();
        if (pos >= len) throw new Error(Quark.from_string("json"), 0, "eof");
        uint8 c = s[pos];
        if (c == '{') return parse_obj();
        if (c == '[') return parse_arr();
        if (c == '"') return JVal.strv(parse_str());
        if (c == 't') { expect_word("true"); return JVal.boolv(true); }
        if (c == 'f') { expect_word("false"); return JVal.boolv(false); }
        if (c == 'n') { expect_word("null"); return JVal.nullv(); }
        return parse_num();
    }
    private void expect_word(string w) throws Error {
        for (int k = 0; k < w.length; k++) {
            if (pos >= len || s[pos] != w[k]) throw new Error(Quark.from_string("json"), 0, "bad literal");
            pos++;
        }
    }
    private JVal parse_obj() throws Error {
        pos++;
        skip_ws();
        var out = JVal.objv();
        if (pos < len && s[pos] == '}') { pos++; return out; }
        while (true) {
            skip_ws();
            var k = parse_str();
            skip_ws();
            if (s[pos] != ':') throw new Error(Quark.from_string("json"), 0, "expected :");
            pos++;
            out.o.insert(k, value());
            skip_ws();
            uint8 c = s[pos]; pos++;
            if (c == '}') break;
            if (c != ',') throw new Error(Quark.from_string("json"), 0, "expected , or }");
        }
        return out;
    }
    private JVal parse_arr() throws Error {
        pos++;
        skip_ws();
        JVal[] items = {};
        if (pos < len && s[pos] == ']') { pos++; return JVal.arrv(items); }
        while (true) {
            items += value();
            skip_ws();
            uint8 c = s[pos]; pos++;
            if (c == ']') break;
            if (c != ',') throw new Error(Quark.from_string("json"), 0, "expected , or ]");
        }
        return JVal.arrv(items);
    }
    private string parse_str() throws Error {
        pos++;
        var sb = new StringBuilder();
        while (true) {
            if (pos >= len) throw new Error(Quark.from_string("json"), 0, "unterminated");
            uint8 c = s[pos]; pos++;
            if (c == '"') break;
            if (c == '\\') {
                uint8 e = s[pos]; pos++;
                switch (e) {
                    case 'n': sb.append_c('\n'); break;
                    case 'r': sb.append_c('\r'); break;
                    case 't': sb.append_c('\t'); break;
                    case 'b': sb.append_c(8); break;
                    case 'f': sb.append_c(12); break;
                    case '/': sb.append_c('/'); break;
                    case 'u': {
                        int cp = hex_parse(s.substring(pos, 4));
                        pos += 4;
                        if (cp >= 0xD800 && cp <= 0xDBFF && pos + 6 <= len
                            && s[pos] == '\\' && s[pos + 1] == 'u') {
                            int lo = hex_parse(s.substring(pos + 2, 4));
                            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                                pos += 6;
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            }
                        }
                        sb.append_unichar((unichar) cp);
                        break;
                    }
                    default: sb.append_c((char) e); break;
                }
            } else {
                // copy the raw UTF-8 byte through
                sb.append_c((char) c);
            }
        }
        return sb.str;
    }
    private JVal parse_num() throws Error {
        int start = pos;
        while (pos < len && "-+0123456789.eE".index_of_char(s[pos]) >= 0) pos++;
        var txt = s.substring(start, pos - start);
        if (txt.index_of_char('.') >= 0 || txt.index_of_char('e') >= 0 || txt.index_of_char('E') >= 0) {
            var v = new JVal(JKind.FLOAT); v.f = double.parse(txt); return v;
        }
        return JVal.intv(int64.parse(txt));
    }
}

// Matches Python json.dumps(..., ensure_ascii=True) escaping.
public string json_escape(string s) {
    var sb = new StringBuilder();
    sb.append_c('"');
    int n = s.length;
    for (int i = 0; i < n;) {
        unichar cp;
        s.get_next_char(ref i, out cp);
        switch ((int) cp) {
            case 0x22: sb.append("\\\""); break;
            case 0x5C: sb.append("\\\\"); break;
            case 0x0A: sb.append("\\n"); break;
            case 0x0D: sb.append("\\r"); break;
            case 0x09: sb.append("\\t"); break;
            case 0x08: sb.append("\\b"); break;
            case 0x0C: sb.append("\\f"); break;
            default:
                if (cp < 0x20 || cp > 0x7E) {
                    if (cp > 0xFFFF) {
                        int x = (int) cp - 0x10000;
                        sb.append("\\u%04x\\u%04x".printf(0xD800 + (x >> 10), 0xDC00 + (x & 0x3FF)));
                    } else sb.append("\\u%04x".printf((int) cp));
                } else sb.append_unichar(cp);
                break;
        }
    }
    sb.append_c('"');
    return sb.str;
}

public string json_write(JVal v) {
    switch (v.kind) {
        case JKind.NULL: return "null";
        case JKind.BOOL: return v.b ? "true" : "false";
        case JKind.INT: return "%lld".printf(v.i);
        case JKind.FLOAT: return "%g".printf(v.f);
        case JKind.STR: return json_escape(v.s);
        case JKind.ARR: {
            string[] parts = {};
            foreach (var x in v.a) parts += json_write(x);
            return "[" + string.joinv(",", parts) + "]";
        }
        case JKind.OBJ: {
            var keys = v.o.get_keys();
            keys.sort(strcmp);
            string[] parts = {};
            foreach (var k in keys) parts += json_escape(k) + ":" + json_write(v.o.lookup(k));
            return "{" + string.joinv(",", parts) + "}";
        }
    }
    return "null";
}

public uint8[] canon_bytes(JVal v) { return json_write(v).data; }

public int hex_parse(string h) {
    int r = 0;
    for (int i = 0; i < h.length; i++) {
        uint8 ch = h[i];
        int d = 0;
        if (ch >= '0' && ch <= '9') d = ch - '0';
        else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
        else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
        r = r * 16 + d;
    }
    return r;
}
public int64 hex_parse64(string h) {
    int64 r = 0;
    for (int i = 0; i < h.length; i++) {
        uint8 ch = h[i];
        int d = 0;
        if (ch >= '0' && ch <= '9') d = ch - '0';
        else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
        else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
        r = r * 16 + d;
    }
    return r;
}

// ---------------------------------------------------------------- util
public string sha256hex(uint8[] bs) {
    var cs = new Checksum(ChecksumType.SHA256);
    cs.update(bs, bs.length);
    return cs.get_string();
}

public uint8[] bytes_of(string s) { return s.data; }

public string string_of(uint8[] bs) {
    // latin-1 convention: one byte per char (matches adapter_base).
    var sb = new StringBuilder();
    foreach (var bb in bs) sb.append_c((char) bb);
    return sb.str;
}

public uint8[] state_of(JVal req) {
    var st = req.get("state");
    if (st.kind != JKind.STR) st = req.get("state_b64");
    return Base64.decode(st.s);
}

public string sh(string cmd) throws Error {
    string out, err; int status;
    string[] argv = {"/bin/sh", "-c", cmd};
    Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null,
                       out out, out err, out status);
    if (status != 0) throw new Error(Quark.from_string("sh"), 0, "cmd failed %d: %s: %s", status, cmd, err);
    return out;
}

public int sh_status(string cmd) {
    string out, err; int status;
    string[] argv = {"/bin/sh", "-c", cmd};
    try {
        Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null,
                           out out, out err, out status);
        return status;
    } catch (Error e) {
        return 1;
    }
}

public void write_tmp(string path, uint8[] data) throws Error {
    FileUtils.set_data(path, data);
}

public string tmp_path(string tag) {
    return Path.build_filename(Environment.get_tmp_dir(),
        "telvala-%s-%d.tmp".printf(tag, (int) Posix.getpid()));
}

// ---------------------------------------------------------------- gpg
public string gnupg_home() {
    var home = Environment.get_variable("TELEPHONE_GNUPGHOME");
    if (home == null) home = Path.build_filename(Environment.get_home_dir(), "telephone-" + IMPL, "gnupg");
    DirUtils.create_with_parents(home, 0700);
    Posix.chmod(home, 0700);
    return home;
}

public uint8[] run_gpg(string args, uint8[] input) throws Error {
    var home = gnupg_home();
    var in_f = tmp_path("gpgin");
    var out_f = in_f + ".out";
    write_tmp(in_f, input);
    sh("GNUPGHOME=%s gpg --batch --yes %s < %s > %s".printf(home, args, in_f, out_f));
    uint8[] data;
    FileUtils.get_data(out_f, out data);
    FileUtils.unlink(in_f); FileUtils.unlink(out_f);
    return data;
}

public JVal do_keygen() throws Error {
    var uid = "telephone-" + IMPL;
    var keys = string_of(run_gpg("--list-keys --with-colons", {}));
    if (!keys.contains("pub")) {
        run_gpg("--pinentry-mode loopback --passphrase \"\" --quick-generate-key %s ed25519 sign never".printf(uid), {});
    }
    var pub = string_of(run_gpg("--armor --export %s".printf(uid), {}));
    var r = JVal.objv();
    r.o.insert("impl", JVal.strv(IMPL));
    r.o.insert("pubkey", JVal.strv(pub));
    return r;
}

public JVal do_attest(JVal descriptor) throws Error {
    var uid = "telephone-" + IMPL;
    var sig = run_gpg("--pinentry-mode loopback --passphrase \"\" --detach-sign --armor -u %s".printf(uid),
                      canon_bytes(descriptor));
    var r = JVal.objv();
    r.o.insert("signature", JVal.strv(string_of(sig)));
    return r;
}

public bool verify_signature(string pubkeys_text, uint8[] data, string sig_b64) {
    var dir = tmp_path("verifydir");
    var home = Path.build_filename(dir, "gnupg");
    DirUtils.create_with_parents(home, 0700);
    Posix.chmod(home, 0700);
    var keys_f = tmp_path("keys"); var sig_f = tmp_path("sig"); var data_f = tmp_path("data");
    try {
        write_tmp(keys_f, bytes_of(pubkeys_text));
        write_tmp(sig_f, Base64.decode(sig_b64));
        write_tmp(data_f, data);
        if (sh_status("GNUPGHOME=%s gpg --batch --import %s".printf(home, keys_f)) != 0) return false;
        return sh_status("GNUPGHOME=%s gpg --batch --verify %s %s".printf(home, sig_f, data_f)) == 0;
    } catch (Error e) {
        return false;
    } finally {
        FileUtils.unlink(keys_f); FileUtils.unlink(sig_f); FileUtils.unlink(data_f);
    }
}

// ---------------------------------------------------------------- game
public class TelCache {
    public HashTable<string, Bytes> map_;
    public string hash;
    public bool has;
    public TelCache() { has = false; hash = ""; map_ = new HashTable<string, Bytes>(str_hash, str_equal); }
}
public TelCache CACHE;

public JVal do_echo(JVal ping) {
    var inner = JVal.objv();
    inner.o.insert("impl", JVal.strv(IMPL));
    inner.o.insert("ping", ping);
    var r = JVal.objv();
    r.o.insert("impl", JVal.strv(IMPL));
    r.o.insert("echo", JVal.strv(sha256hex(canon_bytes(inner))));
    return r;
}

public JVal do_elect(string position, JVal[] candidates, int64 turn) {
    string[] names = {};
    foreach (var c in candidates) names += c.s;
    string[] pool = {};
    foreach (var n in names) if (n != IMPL) pool += n;
    if (pool.length == 0) pool = names;
    var seed = sha256hex(bytes_of("%s-elect:%s:%lld:%s".printf(IMPL, position, turn, string.joinv(",", names))));
    int64 idx = hex_parse64(seed.substring(0, 8)) % pool.length;
    var r = JVal.objv();
    r.o.insert("elect", JVal.strv(pool[(int) idx]));
    return r;
}

public JVal do_choose(uint8[] data, string position, int64 turn) throws Error {
    var m = Phext.explode(data);
    var pos = PhextCoord.parse(position);
    while (m.contains(pos.to_string())) pos.v[8] += 1;
    var r = JVal.objv();
    r.o.insert("op", JVal.strv("insert"));
    r.o.insert("coordinate", JVal.strv(pos.to_string()));
    r.o.insert("text", JVal.strv("%s was here, turn %lld".printf(IMPL, turn)));
    return r;
}

public JVal do_apply(uint8[] data, JVal step) throws Error {
    var coord = PhextCoord.parse(step.get("coordinate").s);
    var m = Phext.explode(data);
    if (m.contains(coord.to_string())) throw new Error(Quark.from_string("apply"), 0, "coordinate already occupied");
    m.insert(coord.to_string(), new Bytes(bytes_of(step.get("text").s)));
    var result = Phext.implode(m);
    var r = JVal.objv();
    r.o.insert("state_b64", JVal.strv(Base64.encode(result)));
    r.o.insert("state_sha256", JVal.strv(sha256hex(result)));
    return r;
}

public JVal do_init(uint8[] data) {
    CACHE.map_ = Phext.explode(data);
    CACHE.hash = sha256hex(data);
    CACHE.has = true;
    var r = JVal.objv();
    r.o.insert("impl", JVal.strv(IMPL));
    r.o.insert("verdict", JVal.strv("pass"));
    return r;
}

public JVal vfail(string detail) {
    var r = JVal.objv();
    r.o.insert("impl", JVal.strv(IMPL));
    r.o.insert("verdict", JVal.strv("fail"));
    r.o.insert("detail", JVal.strv(detail));
    return r;
}

public JVal do_validate(uint8[] data, JVal step, string event_coord_s, string index_line) throws Error {
    var new_map = Phext.explode(data);
    var coord = PhextCoord.parse(step.get("coordinate").s);
    var ev = PhextCoord.parse(event_coord_s);
    if (!CACHE.has) throw new Error(Quark.from_string("validate"), 0, "validate before init");
    var old = CACHE.map_;
    var placed_b = new_map.lookup(coord.to_string());
    if (placed_b == null || string_of(placed_b.data) != step.get("text").s)
        return vfail("placed scroll missing or altered");
    var fail = new string[1]; fail[0] = null;
    old.foreach((c, tb) => {
        if (fail[0] != null || c == INDEX_COORD_S) return;
        var t = tb.data;
        var nv_b = new_map.lookup(c);
        if (nv_b == null || nv_b.data.length != t.length) { fail[0] = "prior scroll overwritten at " + c; return; }
        var nv = nv_b.data;
        for (int i = 0; i < t.length; i++) if (nv[i] != t[i]) { fail[0] = "prior scroll overwritten at " + c; return; }
    });
    if (fail[0] != null) return vfail(fail[0]);
    var keys = new_map.get_keys();
    foreach (var c in keys) {
        if (!old.contains(c) && c != coord.to_string() && c != ev.to_string())
            return vfail("unexpected new scroll at " + c);
    }
    var idx_bytes = new_map.lookup(INDEX_COORD_S);
    var idx = idx_bytes != null ? string_of(idx_bytes.data) : "";
    if (!idx.strip().has_suffix(index_line.strip()))
        return vfail("index does not record the placement");
    CACHE.map_ = new_map;
    CACHE.hash = sha256hex(data);
    var r = JVal.objv();
    r.o.insert("impl", JVal.strv(IMPL));
    r.o.insert("verdict", JVal.strv("pass"));
    return r;
}

public JVal vfail_n(int n, string msg) {
    var r = JVal.objv();
    r.o.insert("impl", JVal.strv(IMPL));
    r.o.insert("verdict", JVal.strv("fail"));
    r.o.insert("placements_checked", JVal.intv(n));
    var ff = JVal.objv();
    ff.o.insert("detail", JVal.strv(msg));
    r.o.insert("first_failure", ff);
    return r;
}

public JVal do_verify(uint8[] data) throws Error {
    var m = Phext.explode(data);
    var keys_bytes = m.lookup(KEYS_COORD_S);
    var keys_text = keys_bytes != null ? string_of(keys_bytes.data) : "";
    var kh_bytes = m.lookup(KH_COORD_S);
    var kh = kh_bytes != null ? string_of(kh_bytes.data).strip() : "";
    if (sha256hex(bytes_of(keys_text)) != kh)
        return vfail_n(0, "keys-hash scroll does not match keys");
    var events = new HashTable<int, JVal>(direct_hash, direct_equal);
    m.foreach((cs, tb) => {
        try {
            var coord = PhextCoord.parse(cs);
            if (coord.v[0] == 1 && coord.v[1] == 1 && coord.v[2] == 1 && coord.v[3] == 1
                && coord.v[4] == 1 && coord.v[5] == 1 && coord.v[6] == 2 && coord.v[7] == 1) {
                var p = new JParser(string_of(tb.data));
                events.insert((int) coord.v[8], p.parse());
            }
        } catch (Error e) {}
    });
    int[] seqs = {};
    events.foreach((k, v) => { seqs += k; });
    for (int i = 1; i < seqs.length; i++) {
        int tmp = seqs[i]; int j = i - 1;
        while (j >= 0 && seqs[j] > tmp) { seqs[j + 1] = seqs[j]; j--; }
        seqs[j + 1] = tmp;
    }
    var prev_hash = JVal.nullv();
    var placements = new HashTable<string, JVal>(str_hash, str_equal);
    for (int i = 0; i < seqs.length; i++) {
        int s = seqs[i];
        if (s != i + 1) return vfail_n((int) placements.size(), "event seq gap at %d".printf(s));
        var ev = events.lookup(s);
        if (json_write(ev.get("prev")) != json_write(prev_hash))
            return vfail_n((int) placements.size(), "event chain broken at seq %d".printf(s));
        var body = ev.get("body");
        prev_hash = JVal.strv(sha256hex(canon_bytes(body)));
        if (body.get("type").s != "placement") continue;
        var cs = body.get("coord").s;
        if (placements.contains(cs))
            return vfail_n((int) placements.size(), "coordinate reused at seq %d".printf(s));
        var t_b = m.lookup(cs);
        if (t_b == null || sha256hex(t_b.data) != body.get("text_sha256").s)
            return vfail_n((int) placements.size(), "placement scroll hash mismatch seq %d".printf(s));
        var desc = JVal.objv();
        desc.o.insert("turn", body.get("turn"));
        desc.o.insert("coordinate", JVal.strv(cs));
        desc.o.insert("scroll_sha256", body.get("text_sha256"));
        desc.o.insert("file_sha256", body.get("file_sha256"));
        if (!verify_signature(keys_text, canon_bytes(desc), body.get("att").s))
            return vfail_n((int) placements.size(), "attestation fails at seq %d".printf(s));
        placements.insert(cs, body);
    }
    var idx_bytes = m.lookup(INDEX_COORD_S);
    var idx_text = idx_bytes != null ? string_of(idx_bytes.data) : "";
    string[] idx_lines = {};
    foreach (var ln in idx_text.split("\n"))
        if (ln.length > 0 && !ln.has_prefix("#")) idx_lines += ln;
    if (idx_lines.length != (int) placements.size())
        return vfail_n((int) placements.size(), "index lines != placements");
    foreach (var ln in idx_lines) {
        var parts = ln.split(" ", 4);
        var body = placements.lookup(parts[1]);
        if (body == null || body.get("text_sha256").s != parts[2])
            return vfail_n((int) placements.size(), "index hash mismatch: " + ln.substring(0, int.min(40, ln.length)));
    }
    var r = JVal.objv();
    r.o.insert("impl", JVal.strv(IMPL));
    r.o.insert("verdict", JVal.strv("pass"));
    r.o.insert("placements_checked", JVal.intv((int) placements.size()));
    r.o.insert("first_failure", JVal.nullv());
    return r;
}

// ---------------------------------------------------------------- dispatch
public JVal dispatch(JVal req) throws Error {
    var cmd = req.get("cmd").s;
    switch (cmd) {
        case "id": { var r = JVal.objv(); r.o.insert("impl", JVal.strv(IMPL)); return r; }
        case "keygen": return do_keygen();
        case "echo": return do_echo(req.get("ping"));
        case "elect": return do_elect(req.get("position").s, req.get("candidates").a, req.get("turn").i);
        case "choose": return do_choose(state_of(req), req.get("position").s, req.get("turn").i);
        case "apply": return do_apply(state_of(req), req.get("step"));
        case "attest": return do_attest(req.get("descriptor"));
        case "init": return do_init(state_of(req));
        case "validate": return do_validate(state_of(req), req.get("step"),
                                            req.get("event_coord").s, req.get("index_line").s);
        case "verify": return do_verify(state_of(req));
        default: throw new Error(Quark.from_string("dispatch"), 0, "unknown cmd %s", cmd);
    }
}

public string gzip_b64(string line) throws Error {
    var in_f = tmp_path("gzin"); var out_f = in_f + ".gz";
    write_tmp(in_f, bytes_of(line));
    sh("gzip -c %s | base64 -w0 > %s".printf(in_f, out_f));
    uint8[] data; FileUtils.get_data(out_f, out data);
    FileUtils.unlink(in_f); FileUtils.unlink(out_f);
    return string_of(data);
}

public string gunzip_line(string line) throws Error {
    var in_f = tmp_path("gzun"); var out_f = in_f + ".out";
    write_tmp(in_f, Base64.decode(line));
    sh("gzip -dc %s > %s".printf(in_f, out_f));
    uint8[] data; FileUtils.get_data(out_f, out data);
    FileUtils.unlink(in_f); FileUtils.unlink(out_f);
    return string_of(data);
}

public string handle_line(string line) {
    try {
        var p = new JParser(line);
        var resp = dispatch(p.parse());
        var resp_text = json_write(resp);
        if (resp_text.length > 8192) return "GZ1:" + gzip_b64(resp_text);
        return resp_text;
    } catch (Error e) {
        var r = JVal.objv();
        r.o.insert("error", JVal.strv(e.message));
        return json_write(r);
    }
}

public string unframe(string line) {
    if (line.has_prefix("GZ1:")) {
        try { return gunzip_line(line.substring(4)); } catch (Error e) { return line; }
    }
    return line;
}

public int main(string[] args) {
    CACHE = new TelCache();
    if (args.length > 1 && args[1] == "serve") {
        string line;
        while ((line = stdin.read_line()) != null) {
            var trimmed = line.strip();
            if (trimmed.length == 0) continue;
            stdout.printf("%s\n", handle_line(unframe(trimmed)));
            stdout.flush();
        }
    } else {
        var sb = new StringBuilder();
        string line;
        while ((line = stdin.read_line()) != null) sb.append(line);
        var text = sb.str.strip();
        if (text.length > 0) stdout.printf("%s\n", handle_line(unframe(text)));
    }
    return 0;
}
