<cfscript>
// Hub-side CLI for libphext-cfml (Exocortical Telephone Game,
// contract v2), running on Lucee via CommandBox.
//
// Transport (file-based, driven by hub/run-cli.sh): the request JSON
// is in the file named by env TELCFML_REQ; the response JSON is
// written to the file named by env TELCFML_RESP. One invocation
// handles exactly one request (CommandBox/Lucee startup is the
// process); serve-mode persistence lives in the local adapter, and
// the init cache lives on disk in this port's own hub dir
// (~/telephone-cfml/cache/state.b64) — validate materializes it
// through this port's own libphext, exactly like the in-process
// caches of the other ports.
//
// State crosses the wire as base64 under "state". GZ1 framing
// (gzip+base64 over 8 KB) is applied by run-cli.sh / the adapter.
//
// This CLI wraps only this port's own libphext (src/phext.cfm).
// Canonical JSON is hand-written here (must match the harness's
// Python json.dumps exactly); SHA-256/base64 are Lucee's; PGP goes
// through subprocess gpg with a per-port GNUPGHOME
// (~/telephone-cfml/gnupg unless TELEPHONE_GNUPGHOME).

include "phext.cfm";

IMPL = "cfml";
INDEX_CS = "1.1.1/1.1.1/1.1.1";
KEYS_CS = "1.1.1/1.1.1/1.1.2";
KH_CS = "1.1.1/1.1.1/1.1.3";

function homeDir() {
    return createObject("java", "java.lang.System").getProperty("user.home");
}
function envOr(name, fallback) {
    var v = createObject("java", "java.lang.System").getenv(arguments.name);
    return isNull(v) ? arguments.fallback : v;
}
function cacheDir() {
    var d = homeDir() & "/telephone-cfml/cache";
    if (!directoryExists(d)) directoryCreate(d);
    return d;
}
function gnupgHome() {
    var h = envOr("TELEPHONE_GNUPGHOME", homeDir() & "/telephone-cfml/gnupg");
    if (!directoryExists(h)) directoryCreate(h);
    return h;
}
function sha256hexBuf(required string buf) {
    return lcase(hash(bufToBinary(arguments.buf), "SHA-256"));
}
function sha256hexText(required string s) {
    return lcase(hash(arguments.s, "SHA-256", "UTF-8"));
}
function b64OfBuf(required string buf) {
    return binaryEncode(bufToBinary(arguments.buf), "base64");
}
function bufOfB64(required string b64) {
    return bufFromBinary(binaryDecode(arguments.b64, "base64"));
}
function stateOf(required struct req) {
    if (structKeyExists(arguments.req, "state")) return bufOfB64(arguments.req.state);
    return bufOfB64(arguments.req.state_b64);
}

// ------------------------------------------------------------ canon JSON
function escapeJSONStr(required string s) {
    var sb = newSB();
    sb.append('"');
    for (var i = 1; i <= len(arguments.s); i++) {
        var code = asc(mid(arguments.s, i, 1));
        if (code == 34) sb.append('\"');
        else if (code == 92) sb.append('\\');
        else if (code == 10) sb.append('\n');
        else if (code == 13) sb.append('\r');
        else if (code == 9) sb.append('\t');
        else if (code == 8) sb.append('\b');
        else if (code == 12) sb.append('\f');
        else if (code < 32 || code > 126) {
            var hex = createObject("java", "java.lang.Integer").toHexString(code);
            sb.append('\u' & repeatString("0", 4 - len(hex)) & hex);
        } else {
            sb.append(chr(code));
        }
    }
    sb.append('"');
    return sb.toString();
}
function canonJSON(required any v) {
    if (isNull(arguments.v)) return "null";
    if (isNumeric(arguments.v)) {
        var n = val(arguments.v);
        if (n == int(n)) return toString(int(n));
        return toString(n);
    }
    if (isBoolean(arguments.v)) return arguments.v ? "true" : "false";
    if (isArray(arguments.v)) {
        var parts = [];
        for (var x in arguments.v) arrayAppend(parts, canonJSON(x));
        return "[" & arrayToList(parts, ",") & "]";
    }
    if (isStruct(arguments.v)) {
        var keys = structKeyArray(arguments.v);
        arraySort(keys, "text", "asc");
        var parts = [];
        for (var k in keys) {
            var vs = "null";
            try { vs = canonJSON(arguments.v[k]); } catch (any e) { vs = "null"; }
            arrayAppend(parts, escapeJSONStr(k) & ":" & vs);
        }
        return "{" & arrayToList(parts, ",") & "}";
    }
    // simple value: string
    return escapeJSONStr(toString(arguments.v));
}

// ------------------------------------------------------------ gpg
function shStatus(required string cmd) {
    // Run /bin/sh -c <cmd> via Java ProcessBuilder; return exit code.
    try {
        var list = createObject("java", "java.util.ArrayList").init();
        list.add("/bin/sh");
        list.add("-c");
        list.add(arguments.cmd);
        var pb = createObject("java", "java.lang.ProcessBuilder").init(list);
        var devnull = createObject("java", "java.io.File").init("/dev/null");
        pb.redirectOutput(devnull);
        pb.redirectError(devnull);
        var proc = pb.start();
        return proc.waitFor();
    } catch (any ex) {
        return 1;
    }
}
function tmpFile(required string tag, required string content) {
    var p = cacheDir() & "/" & arguments.tag & "-" &
            createObject("java", "java.lang.System").currentTimeMillis() & ".tmp";
    fileWrite(p, arguments.content, "iso-8859-1");
    return p;
}
function runGpg(required string args, required string input) {
    var home = gnupgHome();
    var inF = tmpFile("gpgin", arguments.input);
    var outF = inF & ".out";
    var rc = shStatus("GNUPGHOME=" & home & " gpg --batch --yes " & arguments.args &
                      " < " & inF & " > " & outF);
    if (rc != 0) {
        fileDelete(inF);
        throw("gpg failed: " & arguments.args);
    }
    var out = fileRead(outF, "iso-8859-1");
    fileDelete(inF); fileDelete(outF);
    return out;
}
function doKeygen() {
    var uid = "telephone-" & IMPL;
    var keys = runGpg("--list-keys --with-colons", "");
    if (!find("pub", keys)) {
        runGpg("--pinentry-mode loopback --passphrase '' --quick-generate-key " &
               uid & " ed25519 sign never", "");
    }
    var pub = runGpg("--armor --export " & uid, "");
    var r = {}; r["impl"] = IMPL; r["pubkey"] = pub; return r;
}
function doAttest(required any descriptor) {
    var uid = "telephone-" & IMPL;
    var sig = runGpg("--pinentry-mode loopback --passphrase '' --detach-sign --armor -u " & uid,
                     canonJSON(arguments.descriptor));
    var r = {}; r["signature"] = sig; return r;
}
function verifySignature(required string pubkeysText, required string data,
                         required string sigB64) {
    var dir = cacheDir() & "/verify-" &
              createObject("java", "java.lang.System").currentTimeMillis();
    directoryCreate(dir & "/gnupg");
    var keysF = dir & "/keys.asc"; var sigF = dir & "/sig.asc"; var dataF = dir & "/data.bin";
    fileWrite(keysF, arguments.pubkeysText, "utf-8");
    fileWrite(sigF, bufOfB64(arguments.sigB64), "iso-8859-1");
    fileWrite(dataF, arguments.data, "iso-8859-1");
    var home = dir & "/gnupg";
    if (shStatus("GNUPGHOME=" & home & " gpg --batch --import " & keysF) != 0) return false;
    return shStatus("GNUPGHOME=" & home & " gpg --batch --verify " & sigF & " " & dataF) == 0;
}

// ------------------------------------------------------------ game
function doEcho(required any ping) {
    var inner = {}; inner["impl"] = IMPL; inner["ping"] = arguments.ping;
    var r = {}; r["impl"] = IMPL; r["echo"] = sha256hexText(canonJSON(inner)); return r;
}
function doElect(required string position, required array candidates, required numeric turn) {
    var names = [];
    for (var c in arguments.candidates) arrayAppend(names, toString(c));
    var pool = [];
    for (var n in names) if (n != IMPL) arrayAppend(pool, n);
    if (arrayLen(pool) == 0) pool = names;
    var seed = sha256hexText(IMPL & "-elect:" & arguments.position & ":" &
                             int(arguments.turn) & ":" & arrayToList(names, ","));
    var idx = (inputBaseN(left(seed, 8), 16) % arrayLen(pool)) + 1;
    var r = {}; r["elect"] = pool[idx]; return r;
}
function doChoose(required string data, required string position, required numeric turn) {
    var m = phextExplode(arguments.data);
    var pos = coordParse(arguments.position);
    while (structKeyExists(m, coordString(pos))) pos[9] += 1;
    var r = {}; r["op"] = "insert"; r["coordinate"] = coordString(pos);
    r["text"] = IMPL & " was here, turn " & int(arguments.turn); return r;
}
function doApply(required string data, required struct step) {
    var coord = coordParse(arguments.step.coordinate);
    var m = phextExplode(arguments.data);
    if (structKeyExists(m, coordString(coord))) throw("coordinate already occupied");
    m[coordString(coord)] = arguments.step.text;
    var result = phextImplode(m);
    var r = {}; r["state_b64"] = b64OfBuf(result); r["state_sha256"] = sha256hexBuf(result); return r;
}
function doInit(required string data) {
    fileWrite(cacheDir() & "/state.b64", b64OfBuf(arguments.data), "utf-8");
    var r = {}; r["impl"] = IMPL; r["verdict"] = "pass"; return r;
}
function vfail(required string detail) {
    var r = {}; r["impl"] = IMPL; r["verdict"] = "fail"; r["detail"] = arguments.detail; return r;
}
function doValidate(required string data, required struct step,
                    required string eventCoordS, required string indexLine) {
    var cacheF = cacheDir() & "/state.b64";
    if (!fileExists(cacheF)) throw("validate before init");
    var prior = bufOfB64(fileRead(cacheF, "utf-8"));
    var old = phextExplode(prior);
    var newMap = phextExplode(arguments.data);
    var coord = coordParse(arguments.step.coordinate);
    var ev = coordParse(arguments.eventCoordS);
    var cs = coordString(coord);
    if (!structKeyExists(newMap, cs) || newMap[cs] != arguments.step.text) {
        return vfail("placed scroll missing or altered");
    }
    for (var c in old) {
        if (c == INDEX_CS) continue;
        if (!structKeyExists(newMap, c) || newMap[c] != old[c]) {
            return vfail("prior scroll overwritten at " & c);
        }
    }
    for (var c in newMap) {
        if (!structKeyExists(old, c) && c != cs && c != coordString(ev)) {
            return vfail("unexpected new scroll at " & c);
        }
    }
    var idx = structKeyExists(newMap, INDEX_CS) ? newMap[INDEX_CS] : "";
    var idxTrim = reReplace(idx, "\n+$", "");
    var lineTrim = reReplace(arguments.indexLine, "\n+$", "");
    if (right(idxTrim, len(lineTrim)) != lineTrim) {
        return vfail("index does not record the placement");
    }
    fileWrite(cacheF, b64OfBuf(arguments.data), "utf-8");
    var r = {}; r["impl"] = IMPL; r["verdict"] = "pass"; return r;
}
function vfailN(required numeric n, required string msg) {
    var ff = {}; ff["detail"] = arguments.msg;
    var r = {}; r["impl"] = IMPL; r["verdict"] = "fail";
    r["placements_checked"] = int(arguments.n); r["first_failure"] = ff; return r;
}
function doVerify(required string data) {
    var m = phextExplode(arguments.data);
    var keysText = structKeyExists(m, KEYS_CS) ? m[KEYS_CS] : "";
    var kh = structKeyExists(m, KH_CS) ? trim(m[KH_CS]) : "";
    if (sha256hexBuf(keysText) != kh) {
        return vfailN(0, "keys-hash scroll does not match keys");
    }
    var events = {};
    for (var cs in m) {
        var coord = coordParse(cs);
        if (coord[1] == 1 && coord[2] == 1 && coord[3] == 1 && coord[4] == 1 &&
            coord[5] == 1 && coord[6] == 1 && coord[7] == 2 && coord[8] == 1) {
            events[coord[9]] = deserializeJSON(m[cs]);
        }
    }
    var seqs = structKeyArray(events);
    arraySort(seqs, "numeric", "asc");
    var prevHash = javacast("null", "");
    var havePrev = false;
    var placements = {};
    for (var i = 1; i <= arrayLen(seqs); i++) {
        var s = seqs[i];
        if (s != i) return vfailN(structCount(placements), "event seq gap at " & s);
        var ev = events[s];
        var prev = structKeyExists(ev, "prev") ? ev.prev : javacast("null", "");
        var prevCanon = isNull(prev) ? "null" : canonJSON(prev);
        var expectCanon = havePrev ? ('"' & prevHash & '"') : "null";
        // prev is either null or a hex string
        if (prevCanon != expectCanon) {
            return vfailN(structCount(placements), "event chain broken at seq " & s);
        }
        var body = ev.body;
        prevHash = sha256hexText(canonJSON(body));
        havePrev = true;
        if (!structKeyExists(body, "type") || body.type != "placement") continue;
        var cs2 = body.coord;
        if (structKeyExists(placements, cs2)) {
            return vfailN(structCount(placements), "coordinate reused at seq " & s);
        }
        if (!structKeyExists(m, cs2) || sha256hexBuf(m[cs2]) != body.text_sha256) {
            return vfailN(structCount(placements), "placement scroll hash mismatch seq " & s);
        }
        var desc = {}; desc["turn"] = body.turn; desc["coordinate"] = cs2;
        desc["scroll_sha256"] = body.text_sha256; desc["file_sha256"] = body.file_sha256;
        if (!verifySignature(keysText, canonJSON(desc), body.att)) {
            return vfailN(structCount(placements), "attestation fails at seq " & s);
        }
        placements[cs2] = body;
    }
    var idxText = structKeyExists(m, INDEX_CS) ? m[INDEX_CS] : "";
    var idxLines = [];
    for (var ln in listToArray(idxText, chr(10))) {
        if (len(ln) > 0 && mid(ln, 1, 1) != chr(35)) arrayAppend(idxLines, ln);
    }
    if (arrayLen(idxLines) != structCount(placements)) {
        return vfailN(structCount(placements), "index lines != placements");
    }
    for (var ln in idxLines) {
        var parts = listToArray(ln, " ");
        // format: <turn> <coord> <sha256> <actor...> — split into 4 max
        var p1 = find(" ", ln);
        var rest1 = mid(ln, p1 + 1, len(ln));
        var p2 = find(" ", rest1);
        var coordPart = left(rest1, p2 - 1);
        var rest2 = mid(rest1, p2 + 1, len(rest1));
        var p3 = find(" ", rest2);
        var hashPart = p3 > 0 ? left(rest2, p3 - 1) : rest2;
        if (!structKeyExists(placements, coordPart) ||
            placements[coordPart].text_sha256 != hashPart) {
            return vfailN(structCount(placements), "index hash mismatch: " & left(ln, 40));
        }
    }
    var r = {}; r["impl"] = IMPL; r["verdict"] = "pass";
    r["placements_checked"] = structCount(placements);
    r["first_failure"] = javacast("null", ""); return r;
}

// ------------------------------------------------------------ dispatch
function dispatch(required struct req) {
    var cmd = arguments.req.cmd;
    if (cmd == "id") { var r = {}; r["impl"] = IMPL; return r; }
    if (cmd == "keygen") return doKeygen();
    if (cmd == "echo") return doEcho(arguments.req.ping);
    if (cmd == "elect") return doElect(arguments.req.position, arguments.req.candidates, arguments.req.turn);
    if (cmd == "choose") return doChoose(stateOf(arguments.req), arguments.req.position, arguments.req.turn);
    if (cmd == "apply") return doApply(stateOf(arguments.req), arguments.req.step);
    if (cmd == "attest") return doAttest(arguments.req.descriptor);
    if (cmd == "init") return doInit(stateOf(arguments.req));
    if (cmd == "validate") return doValidate(stateOf(arguments.req), arguments.req.step,
                                             arguments.req.event_coord, arguments.req.index_line);
    if (cmd == "verify") return doVerify(stateOf(arguments.req));
    throw("unknown cmd " & cmd);
}

// ------------------------------------------------------------ main
// One request per file pair. Factored as a function so the warm
// daemon (src/daemon.cfm, which includes this file) can serve
// many requests inside one Lucee context; the one-shot entry
// below runs only when TELCFML_REQ is set in the environment
// (the run-cli.sh fallback path), never on include.
function processRequestFile(required string reqP, required string respP) {
    try {
        var reqText = fileRead(arguments.reqP, "utf-8");
        var req = deserializeJSON(reqText);
        var resp = dispatch(req);
        fileWrite(arguments.respP, canonJSON(resp), "utf-8");
    } catch (any e) {
        var er = {}; er["error"] = e.message;
        fileWrite(arguments.respP, canonJSON(er), "utf-8");
    }
}
reqPath = envOr("TELCFML_REQ", "");
respPath = envOr("TELCFML_RESP", "");
if (len(reqPath) > 0) processRequestFile(reqPath, respPath);
</cfscript>
