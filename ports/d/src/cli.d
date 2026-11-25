// Hub-side CLI for libphext-d (Exocortical Telephone Game, contract v2).
//
// Transport: with the argument `serve`, stdin carries one JSON request
// per line and stdout carries one JSON response per line. With no
// argument, stdin carries ONE JSON object and stdout ONE response.
// This CLI serves the four libphext hooks the local adapter
// (ports/d/adapter, harness/adapter_base.py) plugs into its shared
// game machinery: explode / implode / insert / fetch. Requests carry
// phext state as base64 under "state" (v2) or "state_b64".
// SHA-256 and Base64 are D stdlib (std.digest.sha, std.base64).
module cli;

import std.base64 : Base64;
import std.digest.sha : sha256Of, toHexString;
import std.json : JSONValue, parseJSON;
import std.stdio : stdin, stdout, writeln;
import std.zlib : Compress, UnCompress, HeaderFormat;
import phext;

enum IMPL = "d";

string sha256hex(const(ubyte)[] bytes) {
    import std.string : toLower;
    return toHexString(sha256Of(bytes)).toLower().idup;
}

ubyte[] stateOf(JSONValue req) {
    auto s = ("state" in req) ? req["state"].str : req["state_b64"].str;
    return Base64.decode(s);
}

string b64(const(ubyte)[] bytes) {
    return Base64.encode(bytes);
}

JSONValue dispatch(JSONValue req) {
    auto cmd = req["cmd"].str;
    switch (cmd) {
    case "id":
        return JSONValue(["impl": JSONValue(IMPL)]);
    case "explode": {
        auto map = explode(stateOf(req));
        JSONValue[string] m;
        foreach (coord, text; map) m[coord.toString()] = b64(text);
        JSONValue out_;
        out_["map"] = m;
        return out_;
    }
    case "implode": {
        ubyte[][Coordinate] map;
        foreach (k, v; req["map"].object)
            map[Coordinate.parse(k)] = Base64.decode(v.str);
        auto bytes = implode(map);
        JSONValue out_;
        out_["state_b64"] = b64(bytes);
        out_["state_sha256"] = sha256hex(bytes);
        return out_;
    }
    case "insert": {
        // Game insert (adapter_base hook semantics): unused coord only.
        auto coord = Coordinate.parse(req["coordinate"].str);
        auto map = explode(stateOf(req));
        if (coord in map) {
            JSONValue out_;
            out_["error"] = "coordinate already occupied";
            return out_;
        }
        map[coord] = Base64.decode(req["text_b64"].str);
        auto bytes = implode(map);
        JSONValue out_;
        out_["state_b64"] = b64(bytes);
        out_["state_sha256"] = sha256hex(bytes);
        return out_;
    }
    case "fetch": {
        auto got = fetch(stateOf(req), Coordinate.parse(req["coordinate"].str));
        JSONValue out_;
        out_["text_b64"] = b64(got);
        return out_;
    }
    default:
        throw new Exception("unknown cmd " ~ cmd);
    }
}

// Wire compression (see ports/d/adapter): requests over 64 KiB may
// arrive as {"gz_b64": "<base64 gzip of the request JSON>"} and large
// responses are returned the same way. Gzip is std.zlib.
JSONValue unwrap(JSONValue req) {
    if ("gz_b64" in req) {
        auto comp = Base64.decode(req["gz_b64"].str);
        auto uc = new UnCompress(HeaderFormat.gzip);
        auto data = cast(string) uc.uncompress(comp) ~ cast(string) uc.flush();
        return parseJSON(data);
    }
    return req;
}

string wrap(JSONValue out_) {
    auto s = out_.toString();
    if (s.length > 65536) {
        auto c = new Compress(6, HeaderFormat.gzip);
        auto data = cast(ubyte[]) c.compress(cast(void[]) s) ~
                    cast(ubyte[]) c.flush();
        JSONValue w;
        w["gz_b64"] = Base64.encode(data);
        return w.toString();
    }
    return s;
}

string handleLine(string line) {
    JSONValue out_;
    try {
        out_ = dispatch(unwrap(parseJSON(line)));
    } catch (Exception e) {
        out_ = JSONValue(["error": JSONValue(e.msg)]);
    }
    return wrap(out_);
}

void main(string[] args) {
    if (args.length > 1 && args[1] == "serve") {
        foreach (line; stdin.byLine()) {
            if (line.length == 0) continue;
            writeln(handleLine(line.idup));
            stdout.flush();
        }
    } else {
        import std.array : appender;
        auto app = appender!(char[])();
        foreach (chunk; stdin.byChunk(65536)) app.put(cast(char[]) chunk);
        writeln(handleLine(app.data.idup));
    }
}
