// Hub-side CLI for libphext-groovy (Exocortical Telephone Game,
// contract v2).
//
// Transport: with the argument `serve`, stdin carries one JSON
// request per line and stdout carries one JSON response per line.
// With no argument, stdin carries ONE JSON object and stdout ONE
// response. State crosses the wire as base64 under "state".
// Serve lines over 8 KB travel GZ1-framed: "GZ1:" + base64(gzip(line)).
//
// This CLI wraps only this port's own libphext (phext.Phext).
// JSON is hand-written here (canonical form must match the harness's
// Python json.dumps exactly); base64/SHA-256/gzip are the JDK's;
// PGP goes through subprocess gpg with a per-port GNUPGHOME
// (~/telephone-groovy/gnupg unless TELEPHONE_GNUPGHOME).
package phext

import java.io.*
import java.nio.file.*
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

class Json {
    static class Parser {
        private final String text
        private int pos = 0
        Parser(String text) { this.text = text }
        private void skipWs() {
            while (pos < text.length() && " \t\n\r".indexOf((int) text.charAt(pos)) >= 0) pos++
        }
        private int peek() { pos < text.length() ? (int) text.charAt(pos) : -1 }
        private int next() { (int) text.charAt(pos++) }
        private void expect(int c) {
            if (next() != c) throw new IllegalArgumentException("expected " + (char) c)
        }
        Object value() {
            skipWs()
            int c = peek()
            if (c == 123) return obj()
            if (c == 91) return arr()
            if (c == 34) return str()
            if (c == 116) { literal("true"); return Boolean.TRUE }
            if (c == 102) { literal("false"); return Boolean.FALSE }
            if (c == 110) { literal("null"); return null }
            return number()
        }
        private void literal(String lit) {
            if (!text.startsWith(lit, pos)) throw new IllegalArgumentException("bad literal")
            pos += lit.length()
        }
        Map<String, Object> obj() {
            expect(123)
            skipWs()
            Map<String, Object> out = new LinkedHashMap<>()
            if (peek() == 125) { next(); return out }
            while (true) {
                skipWs()
                String k = str()
                skipWs()
                expect(58)
                out.put(k, value())
                skipWs()
                int c = next()
                if (c == 125) break
                if (c != 44) throw new IllegalArgumentException("expected , or }")
            }
            return out
        }
        List<Object> arr() {
            expect(91)
            skipWs()
            List<Object> out = new ArrayList<>()
            if (peek() == 93) { next(); return out }
            while (true) {
                out.add(value())
                skipWs()
                int c = next()
                if (c == 93) break
                if (c != 44) throw new IllegalArgumentException("expected , or ]")
            }
            return out
        }
        String str() {
            expect(34)
            StringBuilder out = new StringBuilder()
            while (true) {
                int c = next()
                if (c == 34) break
                if (c == 92) {
                    int e = next()
                    if (e == 110) out.append('\n')
                    else if (e == 114) out.append('\r')
                    else if (e == 116) out.append('\t')
                    else if (e == 98) out.append('\b')
                    else if (e == 102) out.append('\f')
                    else if (e == 117) {
                        out.append((char) Integer.parseInt(text.substring(pos, pos + 4), 16))
                        pos += 4
                    } else out.append((char) e)
                } else out.append((char) c)
            }
            return out.toString()
        }
        Object number() {
            int start = pos
            while (pos < text.length() && "-+0123456789.eE".indexOf((int) text.charAt(pos)) >= 0) pos++
            String tok = text.substring(start, pos)
            if (tok.contains('.') || tok.contains('e') || tok.contains('E'))
                return Double.parseDouble(tok)
            try { return Long.parseLong(tok) } catch (NumberFormatException ex) { return Double.parseDouble(tok) }
        }
    }

    static Object parse(String text) { new Parser(text).value() }

    static String write(Object v) {
        StringBuilder out = new StringBuilder()
        writeInto(out, v)
        out.toString()
    }
    private static void writeInto(StringBuilder out, Object v) {
        if (v == null) { out.append("null"); return }
        if (v instanceof String) { writeString(out, (String) v); return }
        if (v instanceof Boolean) { out.append(v.toString()); return }
        if (v instanceof Double || v instanceof Float) {
            double d = ((Number) v).doubleValue()
            if (d == Math.rint(d) && !Double.isInfinite(d)) out.append(Long.toString((long) d))
            else out.append(Double.toString(d))
            return
        }
        if (v instanceof Number) { out.append(v.toString()); return }
        if (v instanceof Map) {
            out.append('{')
            boolean first = true
            List<Map.Entry> entries = new ArrayList<>(((Map) v).entrySet())
            entries.sort { a, b -> ((String) a.key).compareTo((String) b.key) }
            for (Map.Entry e : entries) {
                if (!first) out.append(',')
                first = false
                writeString(out, (String) e.key)
                out.append(':')
                writeInto(out, e.value)
            }
            out.append('}')
            return
        }
        if (v instanceof List) {
            out.append('[')
            boolean first = true
            for (Object item : (List) v) {
                if (!first) out.append(',')
                first = false
                writeInto(out, item)
            }
            out.append(']')
            return
        }
        throw new IllegalArgumentException("not json: " + v.class)
    }
    private static void writeString(StringBuilder out, String s) {
        out.append('"')
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i)
            if (ch == '"') out.append('\\"')
            else if (ch == '\\') out.append('\\\\')
            else if (ch == '\n') out.append('\\n')
            else if (ch == '\r') out.append('\\r')
            else if (ch == '\t') out.append('\\t')
            else if (ch < 0x20 || ch > 0x7e) out.append(String.format('\\u%04x', (int) ch))
            else out.append(ch)
        }
        out.append('"')
    }
}

class Cli {
    static final String IMPL = "groovy"
    static final Coord INDEX_COORD = Phext.coordParse("1.1.1/1.1.1/1.1.1")
    static final Coord KEYS_COORD = Phext.coordParse("1.1.1/1.1.1/1.1.2")
    static final Coord KH_COORD = Phext.coordParse("1.1.1/1.1.1/1.1.3")
    static final long[] EVENT_PREFIX = [1, 1, 1, 1, 1, 1, 2, 1] as long[]

    static Map<Coord, byte[]> cacheMap = null
    static String cacheHash = ""

    static String sha256hex(byte[] bs) {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(bs)
        StringBuilder sb = new StringBuilder()
        for (byte b : d) sb.append(String.format("%02x", b & 0xFF))
        return sb.toString()
    }

    static String b64(byte[] bs) { Base64.getEncoder().encodeToString(bs) }
    static byte[] unb64(String s) { Base64.getDecoder().decode(s) }
    static byte[] latin1Bytes(String s) { s.getBytes("ISO-8859-1") }
    static String latin1String(byte[] bs) { new String(bs, "ISO-8859-1") }
    static String utf8String(byte[] bs) { new String(bs, "UTF-8") }
    static byte[] canon(Object v) { Json.write(v).getBytes("UTF-8") }

    static byte[] stateOf(Map req) {
        Object s = req.get("state")
        if (s == null) s = req.get("state_b64")
        return unb64((String) s)
    }

    static byte[] gzip(byte[] bs) {
        ByteArrayOutputStream buf = new ByteArrayOutputStream()
        GZIPOutputStream out = new GZIPOutputStream(buf)
        out.write(bs); out.close()
        return buf.toByteArray()
    }

    static byte[] gunzip(byte[] bs) {
        GZIPInputStream inp = new GZIPInputStream(new ByteArrayInputStream(bs))
        return inp.readAllBytes()
    }

    // ------------------------------------------------------------ gpg
    static String gnupgHome() {
        String h = System.getenv("TELEPHONE_GNUPGHOME")
        if (h == null) h = System.getProperty("user.home") + "/telephone-" + IMPL + "/gnupg"
        File f = new File(h)
        f.mkdirs()
        try { new ProcessBuilder("chmod", "700", h).start().waitFor() } catch (Exception ignored) {}
        return h
    }

    static byte[] runGpg(String home, List<String> args, byte[] input) {
        List<String> cmd = new ArrayList<>()
        cmd.add("gpg"); cmd.add("--batch"); cmd.add("--yes")
        cmd.addAll(args)
        ProcessBuilder pb = new ProcessBuilder(cmd)
        pb.environment().put("GNUPGHOME", home)
        Process p = pb.start()
        if (input != null) {
            OutputStream os = p.getOutputStream()
            os.write(input)
            os.close()
        } else {
            p.getOutputStream().close()
        }
        byte[] out = p.getInputStream().readAllBytes()
        byte[] err = p.getErrorStream().readAllBytes()
        int rc = p.waitFor()
        if (rc != 0) throw new RuntimeException("gpg failed: " + new String(err, "UTF-8"))
        return out
    }

    static Map keygen() {
        String home = gnupgHome()
        String uid = "telephone-" + IMPL
        String keys = new String(runGpg(home, ["--list-keys", "--with-colons"], null), "UTF-8")
        if (!keys.contains("pub")) {
            runGpg(home, ["--pinentry-mode", "loopback", "--passphrase", "",
                          "--quick-generate-key", uid, "ed25519", "sign", "never"], null)
        }
        String pub = new String(runGpg(home, ["--armor", "--export", uid], null), "UTF-8")
        return [impl: IMPL, pubkey: pub]
    }

    static Map attest(Object descriptor) {
        String home = gnupgHome()
        String uid = "telephone-" + IMPL
        byte[] sig = runGpg(home, ["--pinentry-mode", "loopback", "--passphrase", "",
                                   "--detach-sign", "--armor", "-u", uid],
                            canon(descriptor))
        return [signature: new String(sig, "UTF-8")]
    }

    static boolean verifySignature(String pubkeysText, byte[] data, String sigB64) {
        try {
            Path td = Files.createTempDirectory("telverify")
            Path home = td.resolve("gnupg")
            Files.createDirectories(home)
            try { new ProcessBuilder("chmod", "700", home.toString()).start().waitFor() } catch (Exception ignored) {}
            Closure<Integer> run = { List<String> a, byte[] inp ->
                List<String> cmd = new ArrayList<>()
                cmd.add("gpg"); cmd.add("--batch"); cmd.add("--yes")
                cmd.addAll(a)
                ProcessBuilder pb = new ProcessBuilder(cmd)
                pb.environment().put("GNUPGHOME", home.toString())
                Process p = pb.start()
                OutputStream os = p.getOutputStream()
                if (inp != null) os.write(inp)
                os.close()
                p.getInputStream().readAllBytes()
                p.getErrorStream().readAllBytes()
                return p.waitFor()
            }
            if (run(["--import"], pubkeysText.getBytes("UTF-8")) != 0) return false
            Path sigfile = td.resolve("sig.asc")
            Files.write(sigfile, unb64(sigB64))
            return run(["--verify", sigfile.toString(), "-"], data) == 0
        } catch (Exception e) {
            return false
        }
    }

    // ------------------------------------------------------------ game
    static Map doEcho(Object ping) {
        return [impl: IMPL, echo: sha256hex(canon([impl: IMPL, ping: ping]))]
    }

    static Map doElect(String position, List candidates, long turn) {
        List pool = candidates.findAll { it != IMPL }
        if (pool.isEmpty()) pool = new ArrayList(candidates)
        String seed = sha256hex((IMPL + "-elect:" + position + ":" + turn + ":" +
                                 candidates.join(",")).getBytes("UTF-8"))
        return [elect: pool.get((int) (Long.parseLong(seed.substring(0, 8), 16) % pool.size()))]
    }

    static Map doChoose(byte[] data, String position, long turn) {
        Map<Coord, byte[]> m = Phext.explode(data)
        Coord pos = Phext.coordParse(position)
        while (m.containsKey(pos)) {
            long[] nv = pos.v.clone()
            nv[8] += 1
            pos = new Coord(nv)
        }
        return [op: "insert", coordinate: Phext.coordString(pos),
                text: IMPL + " was here, turn " + turn]
    }

    static Map doApply(byte[] data, Map step) {
        Coord coord = Phext.coordParse((String) step.get("coordinate"))
        Map<Coord, byte[]> m = Phext.explode(data)
        if (m.containsKey(coord)) throw new IllegalArgumentException("coordinate already occupied")
        m.put(coord, latin1Bytes((String) step.get("text")))
        byte[] out = Phext.implode(m)
        return [state_b64: b64(out), state_sha256: sha256hex(out)]
    }

    static Map doInit(byte[] data) {
        cacheMap = Phext.explode(data)
        cacheHash = sha256hex(data)
        return [impl: IMPL, verdict: "pass"]
    }

    static Map vfail(String detail) { [impl: IMPL, verdict: "fail", detail: detail] }

    static Map doValidate(byte[] data, Map step, String eventCoordS, String indexLine) {
        Map<Coord, byte[]> newMap = Phext.explode(data)
        Coord coord = Phext.coordParse((String) step.get("coordinate"))
        Coord ev = Phext.coordParse(eventCoordS)
        Map<Coord, byte[]> old = cacheMap
        byte[] placed = newMap.get(coord)
        if (placed == null || latin1String(placed) != step.get("text"))
            return vfail("placed scroll missing or altered")
        for (Map.Entry<Coord, byte[]> e : old.entrySet()) {
            if (e.getKey() == INDEX_COORD) continue
            byte[] nv = newMap.get(e.getKey())
            if (nv == null || !Arrays.equals(nv, e.getValue()))
                return vfail("prior scroll overwritten at " + Phext.coordString(e.getKey()))
        }
        for (Coord c : newMap.keySet()) {
            if (!old.containsKey(c) && c != coord && c != ev)
                return vfail("unexpected new scroll at " + Phext.coordString(c))
        }
        String idx = latin1String(newMap.getOrDefault(INDEX_COORD, new byte[0]))
        if (!idx.replaceAll('\n+$', "").endsWith(indexLine.replaceAll('\n+$', "")))
            return vfail("index does not record the placement")
        cacheMap = newMap
        cacheHash = sha256hex(data)
        return [impl: IMPL, verdict: "pass"]
    }

    static Map vfailN(int n, String msg) {
        [impl: IMPL, verdict: "fail", placements_checked: n,
         first_failure: [detail: msg]]
    }

    static Map doVerify(byte[] data) {
        Map<Coord, byte[]> m = Phext.explode(data)
        String keysText = utf8String(m.getOrDefault(KEYS_COORD, new byte[0]))
        if (sha256hex(keysText.getBytes("UTF-8")) !=
                latin1String(m.getOrDefault(KH_COORD, new byte[0])).trim())
            return vfailN(0, "keys-hash scroll does not match keys")
        Map<Long, Map> events = new TreeMap<>()
        for (Map.Entry<Coord, byte[]> e : m.entrySet()) {
            boolean isEvent = true
            for (int i = 0; i < 8; i++) if (e.getKey().v[i] != EVENT_PREFIX[i]) isEvent = false
            if (isEvent) events.put(e.getKey().v[8], (Map) Json.parse(utf8String(e.getValue())))
        }
        String prevHash = null
        Map<Coord, Map> placements = new LinkedHashMap<>()
        int i = 0
        for (Map.Entry<Long, Map> ee : events.entrySet()) {
            long s = ee.getKey()
            if (s != i + 1) return vfailN(placements.size(), "event seq gap at " + s)
            i++
            Map ev = ee.getValue()
            if (ev.get("prev") != prevHash)
                return vfailN(placements.size(), "event chain broken at seq " + s)
            Map body = (Map) ev.get("body")
            prevHash = sha256hex(canon(body))
            if (body.get("type") == "placement") {
                Coord coord = Phext.coordParse((String) body.get("coord"))
                if (placements.containsKey(coord))
                    return vfailN(placements.size(), "coordinate reused at seq " + s)
                byte[] t = m.get(coord)
                if (t == null || sha256hex(t) != body.get("text_sha256"))
                    return vfailN(placements.size(), "placement scroll hash mismatch seq " + s)
                Map desc = [turn: body.get("turn"), coordinate: body.get("coord"),
                            scroll_sha256: body.get("text_sha256"),
                            file_sha256: body.get("file_sha256")]
                if (!verifySignature(keysText, canon(desc), (String) body.get("att")))
                    return vfailN(placements.size(), "attestation fails at seq " + s)
                placements.put(coord, body)
            }
        }
        List<String> idxLines = new ArrayList<>()
        for (String ln : latin1String(m.getOrDefault(INDEX_COORD, new byte[0])).split("\n")) {
            if (!ln.isEmpty() && !ln.startsWith("#")) idxLines.add(ln)
        }
        if (idxLines.size() != placements.size())
            return vfailN(placements.size(), "index lines != placements")
        for (String ln : idxLines) {
            String[] parts = ln.split(" ", 4)
            Map body = placements.get(Phext.coordParse(parts[1]))
            if (body == null || body.get("text_sha256") != parts[2])
                return vfailN(placements.size(), "index hash mismatch: " +
                              ln.substring(0, Math.min(40, ln.length())))
        }
        return [impl: IMPL, verdict: "pass", placements_checked: placements.size(),
                first_failure: null]
    }

    // ------------------------------------------------------------ dispatch
    static Map dispatch(Map req) {
        switch ((String) req.get("cmd")) {
            case "id": return [impl: IMPL]
            case "keygen": return keygen()
            case "echo": return doEcho(req.get("ping"))
            case "elect":
                return doElect((String) req.get("position"), (List) req.get("candidates"),
                               ((Number) req.get("turn")).longValue())
            case "choose":
                return doChoose(stateOf(req), (String) req.get("position"),
                                ((Number) req.get("turn")).longValue())
            case "apply": return doApply(stateOf(req), (Map) req.get("step"))
            case "attest": return attest(req.get("descriptor"))
            case "init": return doInit(stateOf(req))
            case "validate":
                return doValidate(stateOf(req), (Map) req.get("step"),
                                  (String) req.get("event_coord"), (String) req.get("index_line"))
            case "verify": return doVerify(stateOf(req))
            default: throw new IllegalArgumentException("unknown cmd " + req.get("cmd"))
        }
    }

    static String handleLine(String line) {
        try {
            Map req = (Map) Json.parse(line)
            String resp = Json.write(dispatch(req))
            if (resp.length() > 8192)
                return "GZ1:" + b64(gzip(resp.getBytes("UTF-8")))
            return resp
        } catch (Exception e) {
            return Json.write([error: e.getClass().getSimpleName() + ": " + e.getMessage()])
        }
    }

    static String unframe(String line) {
        if (line.startsWith("GZ1:"))
            return new String(gunzip(unb64(line.substring(4))), "UTF-8")
        return line
    }

    static void main(String[] args) {
        if (Arrays.asList(args).contains("serve")) {
            BufferedReader rdr = new BufferedReader(new InputStreamReader(System.in, "UTF-8"))
            String line
            while ((line = rdr.readLine()) != null) {
                if (line.trim().isEmpty()) continue
                System.out.println(handleLine(unframe(line.trim())))
                System.out.flush()
            }
        } else {
            String text = new String(System.in.readAllBytes(), "UTF-8").trim()
            if (!text.isEmpty()) System.out.println(handleLine(unframe(text)))
        }
    }
}
