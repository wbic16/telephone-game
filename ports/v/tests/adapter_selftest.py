#!/usr/bin/env python3
"""Adapter self-test for one telephone-game port — contract v2,
in the harness adapter_base formats.

Checks: `id`; `keygen` returns an armored pubkey and is stable;
`seek` finds the Test of Will in CYOA (verified by a raw read at the
reported offset); over one serve session — echo twice identical,
elect returns a candidate, choose emits an insert at an unused
coordinate, apply round-trips it and leaves prior scrolls untouched,
attest returns a base64 armored PGP signature, init+validate pass on
the placed state and fail on a tampered one; and verify passes a
constructed stress.phext (keys + keys-hash + index + one hash-chained
attested placement event), with placements_checked == 1.

Usage: adapter_selftest.py <adapter_path> <impl_id> [cyoa_root]
"""
import base64
import hashlib
import json
import os
import subprocess
import sys

ZERO = None  # first event's prev is null in the adapter_base chain
CYOA_DEFAULT = os.path.expanduser("~/workspace/phext")
INDEX = (1, 1, 1, 1, 1, 1, 1, 1, 1)
KEYS = (1, 1, 1, 1, 1, 1, 1, 1, 2)
KH = (1, 1, 1, 1, 1, 1, 1, 1, 3)
EVENT1 = (1, 1, 1, 1, 1, 1, 2, 1, 1)
BREAKS = b"\x01\x1f\x1e\x1d\x1c\x1a\x19\x18\x17"
BDIM = {b: d for d, b in enumerate(BREAKS)}


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def b64(b):
    return base64.b64encode(b).decode()


def explode(data):
    out = {}
    coord = [1] * 9
    run = bytearray()
    for byte in data:
        d = BDIM.get(byte)
        if d is None:
            run.append(byte)
        else:
            if run:
                out[tuple(coord)] = bytes(run)
                run = bytearray()
            coord[d] += 1
            for lower in range(d + 1, 9):
                coord[lower] = 1
    if run:
        out[tuple(coord)] = bytes(run)
    return out


def implode(mapping):
    out = []
    loc = [1] * 9
    for coord in sorted(mapping):
        text = mapping[coord]
        if not text:
            continue
        if tuple(loc) < coord:
            dim = 0
            while loc[dim] == coord[dim]:
                dim += 1
            out.append(bytes([BREAKS[dim]]) * (coord[dim] - loc[dim]))
            loc = loc[:dim] + [coord[dim]] + [1] * (8 - dim)
            for lower in range(dim + 1, 9):
                out.append(bytes([BREAKS[lower]]) * (coord[lower] - 1))
                loc[lower] = coord[lower]
        out.append(text)
    return b"".join(out)


def parse_coord(s):
    return tuple(int(x) for grp in s.split("/") for x in grp.split("."))


class Serve:
    def __init__(self, adapter):
        self.proc = subprocess.Popen([adapter, "serve"],
                                     stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True)

    def ask(self, payload):
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        assert line, "serve closed the connection for %s" % payload.get("cmd")
        return json.loads(line)

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=15)
        except Exception:
            self.proc.kill()


def one_shot(adapter, args):
    p = subprocess.run([adapter] + args,
                       capture_output=True, text=True, timeout=1200)
    assert p.returncode == 0, "%s failed: %s" % (args[0], p.stderr[:400])
    return p.stdout.strip()


def main():
    adapter = os.path.abspath(sys.argv[1])
    impl = sys.argv[2]
    cyoa = sys.argv[3] if len(sys.argv) > 3 else CYOA_DEFAULT
    failures = []

    def check(cond, name):
        print(("ok   " if cond else "FAIL ") + name)
        if not cond:
            failures.append(name)

    check(one_shot(adapter, ["id"]) == impl, "id == %s" % impl)

    kg1 = json.loads(one_shot(adapter, ["keygen"]))
    kg2 = json.loads(one_shot(adapter, ["keygen"]))
    check(kg1.get("impl") == impl and
          "BEGIN PGP PUBLIC KEY BLOCK" in kg1.get("pubkey", ""),
          "keygen returns armored pubkey")
    check(kg1.get("pubkey") == kg2.get("pubkey"), "keygen is stable")
    pubkey = kg1["pubkey"]

    found = json.loads(one_shot(adapter, ["seek", cyoa]))
    ok_seek = (found.get("coordinate") == "13.13.13/13.13.13/13.13.13" and
               found.get("title") == "The Test of Will" and
               (found.get("path") or "").endswith(
                   "choose-your-own-adventure.phext"))
    check(ok_seek, "seek finds the Test of Will: %s" %
          {k: found.get(k) for k in ("path", "offset", "title")})
    if ok_seek:
        with open(found["path"], "rb") as f:
            data = f.read()
        off = found["offset"]
        check(data[off:off + 16] == b"The Test of Will",
              "raw read at seek offset confirms the scroll")

    serve = Serve(adapter)
    try:
        ping = {"game": "selftest", "round": 1, "nonce": "ab" * 32}
        e1 = serve.ask({"cmd": "echo", "ping": ping})
        e2 = serve.ask({"cmd": "echo", "ping": ping})
        check(e1 == e2 and e1.get("impl") == impl and e1.get("echo"),
              "echo twice identical")

        el = serve.ask({"cmd": "elect", "position": "4.4.4/4.4.4/4.4.4",
                        "candidates": ["reference", impl, "py"], "turn": 1})
        check(el.get("elect") in ("reference", impl, "py"),
              "elect returns a candidate: %s" % el)

        # choose + apply (insert-only at an unused coordinate)
        prior_map = {INDEX: b"# stress index\n",
                     (9, 9, 9, 9, 9, 9, 9, 9, 9): b"old scroll"}
        prior = implode(prior_map)
        step = serve.ask({"cmd": "choose", "state": b64(prior),
                          "position": "4.4.4/4.4.4/4.4.4", "turn": 1})
        check(step.get("op") == "insert" and "coordinate" in step,
              "choose emits insert only: %s" % step)
        check(explode(prior).get(parse_coord(step["coordinate"])) is None,
              "choose coordinate is unused in the given state")
        applied = serve.ask({"cmd": "apply", "state": b64(prior),
                             "step": step})
        new_state = base64.b64decode(applied["state_b64"])
        check(applied["state_sha256"] == sha256(new_state),
              "apply state_sha256 matches")
        new_map = explode(new_state)
        check(new_map.get(parse_coord(step["coordinate"])) ==
              step["text"].encode("latin-1"),
              "applied scroll present with the step text")
        check(new_map.get((9, 9, 9, 9, 9, 9, 9, 9, 9)) == b"old scroll",
              "prior scroll untouched by apply")

        # attest (descriptor in the verify format of adapter_base)
        descriptor = {"turn": 1, "coordinate": step["coordinate"],
                      "scroll_sha256": sha256(step["text"].encode("latin-1")),
                      "file_sha256": sha256(prior)}
        att = serve.ask({"cmd": "attest", "descriptor": descriptor})
        sig_armored = base64.b64decode(att.get("signature", "")).decode(
            "utf-8", "replace")
        check("BEGIN PGP SIGNATURE" in sig_armored,
              "attest returns a base64 armored PGP signature")

        # init + validate (pass, then fail on tampering)
        init = serve.ask({"cmd": "init", "state": b64(prior)})
        check(init.get("verdict") == "pass", "init caches the prior state")
        index_line = "1 %s %s %s" % (step["coordinate"],
                                     descriptor["scroll_sha256"], impl)
        placed_map = dict(new_map)
        placed_map[INDEX] = prior_map[INDEX] + (index_line + "\n").encode()
        placed_map[EVENT1] = b"{}"
        placed = implode(placed_map)
        val = serve.ask({"cmd": "validate", "state": b64(placed),
                         "step": step, "event_coord": "1.1.1/1.1.1/2.1.1",
                         "index_line": index_line})
        check(val.get("verdict") == "pass", "validate passes: %s" % val)
        serve.ask({"cmd": "init", "state": b64(prior)})
        tampered_map = dict(placed_map)
        tampered_map[(9, 9, 9, 9, 9, 9, 9, 9, 9)] = b"forged"
        val2 = serve.ask({"cmd": "validate",
                          "state": b64(implode(tampered_map)),
                          "step": step, "event_coord": "1.1.1/1.1.1/2.1.1",
                          "index_line": index_line})
        check(val2.get("verdict") == "fail",
              "validate fails on overwritten prior scroll")

        # verify a constructed stress.phext (adapter_base format)
        base_map = {INDEX: b"# stress index\n",
                    KEYS: pubkey.encode(),
                    KH: sha256(pubkey.encode()).encode()}
        base = implode(base_map)
        step2 = serve.ask({"cmd": "choose", "state": b64(base),
                           "position": "4.4.4/4.4.4/4.4.4", "turn": 1})
        desc2 = {"turn": 1, "coordinate": step2["coordinate"],
                 "scroll_sha256": sha256(step2["text"].encode("latin-1")),
                 "file_sha256": sha256(base)}
        att2 = serve.ask({"cmd": "attest", "descriptor": desc2})
        body = {"type": "placement", "turn": 1, "coord": step2["coordinate"],
                "text_sha256": desc2["scroll_sha256"],
                "file_sha256": desc2["file_sha256"],
                "att": att2["signature"]}
        event = {"prev": None, "body": body}
        final_map = dict(base_map)
        final_map[parse_coord(step2["coordinate"])] = \
            step2["text"].encode("latin-1")
        final_map[EVENT1] = json.dumps(event).encode()
        final_map[INDEX] = ("# stress index\n1 %s %s %s\n" %
                            (step2["coordinate"], desc2["scroll_sha256"],
                             impl)).encode()
        ver = serve.ask({"cmd": "verify", "state": b64(implode(final_map)),
                         "pubkeys": pubkey})
        check(ver.get("verdict") == "pass" and
              ver.get("placements_checked") == 1,
              "verify stress.phext passes: %s" % ver)
    finally:
        serve.close()

    print("selftest %s: %s" % (impl, "PASS" if not failures else
                               "FAIL (%d)" % len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
