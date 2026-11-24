"""Shared adapter machinery for the Exocortical Telephone Game (v2).

Implements everything in ADAPTER-CONTRACT.md except the phext operations
themselves: each participant plugs in its OWN libphext via four hooks
(explode, implode, insert, fetch) — the cross-check lives in those hooks.
The rest (PGP identity, the CYOA seek, echolocation, popcorn election,
per-step self-validation, the total verify walk) is game machinery, shared
so every participant plays by identical rules.
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX_COORD = (1, 1, 1, 1, 1, 1, 1, 1, 1)
KEYS_COORD = (1, 1, 1, 1, 1, 1, 1, 1, 2)
KH_COORD = (1, 1, 1, 1, 1, 1, 1, 1, 3)
EVENT_PREFIX = (1, 1, 1, 1, 1, 1, 2, 1)  # + seq as scroll component


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canon(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def parse_coord(s):
    return tuple(int(x) for grp in s.split("/") for x in grp.split("."))


def coord_str(pos) -> str:
    return "%d.%d.%d/%d.%d.%d/%d.%d.%d" % tuple(pos)


def event_coord(seq):
    return EVENT_PREFIX + (seq,)


class Adapter:
    IMPL = "?"
    # ---- hooks, overridden per implementation (its own libphext) ----
    def explode(self, data: bytes):
        raise NotImplementedError

    def implode(self, mapping) -> bytes:
        raise NotImplementedError

    def insert(self, data: bytes, coord, text: bytes) -> bytes:
        raise NotImplementedError

    def fetch(self, data: bytes, coord) -> bytes:
        raise NotImplementedError

    def choose(self, state: bytes, position, turn):
        raise NotImplementedError

    def elect(self, position, candidates, turn, placements):
        raise NotImplementedError

    # ---- identity (PGP) ----
    @property
    def key_home(self):
        home = os.path.join(ROOT, "harness", "keys", self.IMPL)
        os.makedirs(home, mode=0o700, exist_ok=True)
        os.chmod(home, 0o700)
        return home

    def _gpg(self, args, inp=None):
        env = dict(os.environ, GNUPGHOME=self.key_home)
        p = subprocess.run(["gpg", "--batch", "--yes"] + args, input=inp,
                           capture_output=True, env=env, timeout=120)
        if p.returncode != 0:
            raise RuntimeError("gpg failed: " + p.stderr.decode("utf-8",
                                                                 "replace"))
        return p.stdout

    def keygen(self):
        uid = "telephone-%s" % self.IMPL
        keys = self._gpg(["--list-keys", "--with-colons"]).decode()
        if "pub" not in keys:
            self._gpg(["--pinentry-mode", "loopback", "--passphrase", "",
                       "--quick-generate-key", uid, "ed25519", "sign",
                       "never"])
        pub = self._gpg(["--armor", "--export", uid]).decode()
        return {"impl": self.IMPL, "pubkey": pub}

    def attest(self, descriptor):
        uid = "telephone-%s" % self.IMPL
        sig = self._gpg(["--pinentry-mode", "loopback", "--passphrase", "",
                         "--detach-sign", "--armor", "-u", uid],
                        inp=canon(descriptor))
        return {"signature": base64.b64encode(sig).decode()}

    @staticmethod
    def verify_signature(pubkeys_text, data: bytes, sig_b64) -> bool:
        with tempfile.TemporaryDirectory() as td:
            home = os.path.join(td, "gnupg")
            os.makedirs(home, mode=0o700)
            env = dict(os.environ, GNUPGHOME=home)
            p = subprocess.run(["gpg", "--batch", "--import"],
                               input=pubkeys_text.encode(),
                               capture_output=True, env=env, timeout=120)
            if p.returncode != 0:
                return False
            sigfile = os.path.join(td, "sig.asc")
            with open(sigfile, "wb") as f:
                f.write(base64.b64decode(sig_b64))
            p = subprocess.run(["gpg", "--batch", "--verify", sigfile, "-"],
                               input=data, capture_output=True, env=env,
                               timeout=120)
            return p.returncode == 0

    # ---- the draw: seek the Test of Will in CYOA, raw file I/O only ----
    def seek(self, root):
        files = []
        for dp, _dn, fn in os.walk(root):
            for name in fn:
                p = os.path.join(dp, name)
                try:
                    files.append((os.path.getsize(p), p))
                except OSError:
                    pass
        files.sort()  # smallest first — this seeker's strategy
        for _size, path in files:
            try:
                data = open(path, "rb").read()
            except OSError:
                continue
            if b"The Test of Will" not in data:
                continue
            for coord, text in self.explode(data).items():
                if text.startswith(b"The Test of Will"):
                    head = text.split(b"\n", 2)
                    if len(head) > 1 and \
                            head[1].strip() == ("Coordinate: " +
                                                coord_str(coord)).encode():
                        off = data.find(text[:64])
                        return {"impl": self.IMPL, "path": path,
                                "offset": off,
                                "coordinate": coord_str(coord),
                                "title": head[0].decode("utf-8", "replace")}
        return {"impl": self.IMPL, "path": None}

    # ---- echolocation ----
    def echo(self, ping):
        return {"impl": self.IMPL,
                "echo": sha256(canon({"impl": self.IMPL, "ping": ping}))}

    # ---- per-step self-validation (serve-cached) ----
    def init_cache(self, state_b64):
        data = base64.b64decode(state_b64)
        self._cache_map = self.explode(data)
        self._cache_hash = sha256(data)
        return {"impl": self.IMPL, "verdict": "pass"}

    def validate(self, state_b64, step, event_coord_s, index_line):
        data = base64.b64decode(state_b64)
        new = self.explode(data)
        coord = parse_coord(step["coordinate"])
        ev = parse_coord(event_coord_s)
        old = self._cache_map
        if new.get(coord) != step["text"].encode("latin-1"):
            return self._vfail("placed scroll missing or altered")
        for c, text in old.items():
            if c == INDEX_COORD:
                continue
            if new.get(c) != text:
                return self._vfail("prior scroll overwritten at %s"
                                   % coord_str(c))
        for c in new:
            if c not in old and c not in (coord, ev):
                return self._vfail("unexpected new scroll at %s"
                                   % coord_str(c))
        idx = new.get(INDEX_COORD, b"").decode("latin-1")
        if not idx.rstrip("\n").endswith(index_line.rstrip("\n")):
            return self._vfail("index does not record the placement")
        self._cache_map = new
        self._cache_hash = sha256(data)
        return {"impl": self.IMPL, "verdict": "pass"}

    def _vfail(self, detail):
        return {"impl": self.IMPL, "verdict": "fail", "detail": detail}

    # ---- total verification walk ----
    def verify(self, state_b64, pubkeys_text):
        data = base64.b64decode(state_b64)
        m = self.explode(data)
        keys_text = m.get(KEYS_COORD, b"").decode("utf-8", "replace")
        if sha256(keys_text.encode()) != \
                m.get(KH_COORD, b"").decode("latin-1").strip():
            return self._fail(0, "keys-hash scroll does not match keys")
        events = {}
        for c, text in m.items():
            if c[:8] == EVENT_PREFIX:
                events[c[8]] = json.loads(text)
        prev_hash, placements = None, {}
        seqs = sorted(events)
        for i, s in enumerate(seqs):
            if s != i + 1:
                return self._fail(len(placements), "event seq gap at %d" % s)
            ev = events[s]
            if ev.get("prev") != prev_hash:
                return self._fail(len(placements),
                                  "event chain broken at seq %d" % s)
            prev_hash = sha256(canon(ev["body"]))
            if ev["body"].get("type") == "placement":
                body = ev["body"]
                coord = parse_coord(body["coord"])
                if coord in placements:
                    return self._fail(len(placements),
                                      "coordinate reused at seq %d" % s)
                text = m.get(coord)
                if text is None or sha256(text) != body["text_sha256"]:
                    return self._fail(len(placements),
                                      "placement scroll hash mismatch seq %d"
                                      % s)
                desc = {"turn": body["turn"], "coordinate": body["coord"],
                        "scroll_sha256": body["text_sha256"],
                        "file_sha256": body["file_sha256"]}
                if not self.verify_signature(keys_text, canon(desc),
                                             body["att"]):
                    return self._fail(len(placements),
                                      "attestation fails at seq %d" % s)
                placements[coord] = body
        idx_lines = [ln for ln in
                     m.get(INDEX_COORD, b"").decode("latin-1").splitlines()
                     if ln and not ln.startswith("#")]
        if len(idx_lines) != len(placements):
            return self._fail(len(placements),
                              "index lines != placements")
        for ln in idx_lines:
            _n, cs, h, _actor = ln.split(" ", 3)
            if placements.get(parse_coord(cs), {}).get("text_sha256") != h:
                return self._fail(len(placements),
                                  "index hash mismatch: " + ln[:40])
        return {"impl": self.IMPL, "verdict": "pass",
                "placements_checked": len(placements),
                "first_failure": None}

    def _fail(self, n, msg):
        return {"impl": self.IMPL, "verdict": "fail",
                "placements_checked": n, "first_failure": {"detail": msg}}

    # ---- dispatch ----
    @staticmethod
    def _state_bytes(req):
        # Local adapters receive state by path (fast, same machine);
        # SSH-wrapped adapters receive it base64. Both are the contract.
        if "state_path" in req:
            return open(req["state_path"], "rb").read()
        return base64.b64decode(req["state"])

    def handle(self, req):
        cmd = req["cmd"]
        if cmd == "id":
            return {"impl": self.IMPL}
        if cmd == "keygen":
            return self.keygen()
        if cmd == "seek":
            return self.seek(req["root"])
        if cmd == "echo":
            return self.echo(req["ping"])
        if cmd == "elect":
            return {"elect": self.elect(req["position"], req["candidates"],
                                        req["turn"],
                                        req.get("placements", {}))}
        if cmd == "choose":
            return self.choose(self._state_bytes(req),
                               req["position"], req["turn"])
        if cmd == "apply":
            data = self._state_bytes(req)
            step = req["step"]
            out = self.insert(data, parse_coord(step["coordinate"]),
                              step["text"].encode("latin-1"))
            res = {"state_sha256": sha256(out)}
            if "state_out_path" in req:
                with open(req["state_out_path"], "wb") as f:
                    f.write(out)
            else:
                res["state_b64"] = base64.b64encode(out).decode()
            return res
        if cmd == "attest":
            return self.attest(req["descriptor"])
        if cmd == "init":
            return self.init_cache(base64.b64encode(
                self._state_bytes(req)).decode())
        if cmd == "validate":
            return self.validate(base64.b64encode(
                self._state_bytes(req)).decode(), req["step"],
                req["event_coord"], req["index_line"])
        if cmd == "verify":
            return self.verify(base64.b64encode(
                self._state_bytes(req)).decode(), req["pubkeys"])
        raise ValueError("unknown cmd " + cmd)

    def serve(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                out = self.handle(json.loads(line))
            except Exception as e:  # keep the server alive; report the error
                out = {"error": "%s: %s" % (type(e).__name__, e)}
            sys.stdout.write(json.dumps(out) + "\n")
            sys.stdout.flush()

    def main(self):
        if len(sys.argv) > 1 and sys.argv[1] == "serve":
            self.serve()
            return
        if len(sys.argv) > 1 and sys.argv[1] == "keygen":
            print(json.dumps(self.keygen()))
            return
        if len(sys.argv) > 2 and sys.argv[1] == "seek":
            print(json.dumps(self.seek(sys.argv[2])))
            return
        if len(sys.argv) > 1 and sys.argv[1] == "id":
            print(self.IMPL)
            return
        sys.exit("usage: adapter serve|keygen|seek <root>|id")
