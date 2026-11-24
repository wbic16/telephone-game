#!/usr/bin/env python3
"""Adapter self-test (contract v2) for the perl port.

Checks: one-shot id; serve id + echo twice identical; keygen (twice,
stable armored pubkey); seek finds the Test of Will in the CYOA corpus
by raw I/O and the reported offset reads back the title; elect returns
a candidate (twice identical); choose+apply insert-only round-trip
with validate passing against the prior state; attest produces an
armored signature; a one-placement stress.phext built entirely through
the adapter (keys scroll, keys-hash, placement, signed event scroll,
index) verifies pass with placements_checked == 1.

Run: python3 tests/selftest_adapter.py
"""
import base64
import hashlib
import json
import subprocess
import sys
from pathlib import Path

IMPL = "perl"
ADAPTER = Path(__file__).resolve().parent.parent / "adapter"
CORPUS = Path.home() / "workspace" / "phext"
failures = []


def check(cond, name):
    print(("ok - " if cond else "FAIL - ") + name)
    if not cond:
        failures.append(name)


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canon(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def run_oneshot(*args):
    proc = subprocess.run([str(ADAPTER), *args], stdout=subprocess.PIPE,
                          check=True, timeout=1200)
    return proc.stdout.decode().strip()


class Serve:
    def __init__(self):
        self.proc = subprocess.Popen(
            [str(ADAPTER), "serve"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, text=True)

    def call(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        assert line, "serve process closed the pipe"
        return json.loads(line)

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=60)


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def main():
    check(run_oneshot("id") == IMPL, "one-shot id")

    serve = Serve()
    try:
        check(serve.call({"cmd": "id"}) == {"impl": IMPL}, "serve id")
        ping = {"game": "selftest", "round": 1, "nonce": "ab" * 32}
        e1 = serve.call({"cmd": "echo", "ping": ping})
        e2 = serve.call({"cmd": "echo", "ping": ping})
        check(e1 == e2 and e1["impl"] == IMPL and len(e1["echo"]) == 64,
              "echo twice identical")

        elect_req = {"cmd": "elect", "position": "5.5.5/5.5.5/5.5.5",
                     "candidates": ["go", "php", "perl", "fortran", "reference"],
                     "turn": 3}
        w1 = serve.call(elect_req)["elect"]
        w2 = serve.call(elect_req)["elect"]
        check(w1 == w2 and w1 in elect_req["candidates"], f"elect -> {w1}")

        # keygen (one-shot), twice: stable pubkey
        kg1 = json.loads(run_oneshot("keygen"))
        kg2 = json.loads(run_oneshot("keygen"))
        pubkey = kg1["pubkey"]
        check(kg1["impl"] == IMPL and "BEGIN PGP PUBLIC KEY BLOCK" in pubkey,
              "keygen returns armored pubkey")
        check(kg2["pubkey"] == pubkey, "keygen is stable")

        # seek (one-shot): finds the Test of Will by raw I/O
        found = json.loads(run_oneshot("seek", str(CORPUS)))
        check(found["coordinate"] == "13.13.13/13.13.13/13.13.13",
              "seek coordinate")
        check(found["title"] == "The Test of Will", f"seek title: {found['title']!r}")
        with open(found["path"], "rb") as f:
            f.seek(found["offset"])
            head = f.read(len(found["title"]))
        check(head.decode("utf-8") == found["title"],
              "seek offset reads back the title")

        # Build a one-placement stress.phext through the adapter.
        def apply(state, coord, text):
            step = {"op": "insert", "coordinate": coord, "text": text}
            resp = serve.call({"cmd": "apply", "state": b64(state), "step": step})
            assert resp["state_sha256"] == sha256(base64.b64decode(resp["state_b64"]))
            return base64.b64decode(resp["state_b64"])

        state = b""
        state = apply(state, "1.1.1/1.1.1/1.1.2", pubkey)
        state = apply(state, "1.1.1/1.1.1/1.1.3",
                      sha256(pubkey.rstrip().encode()))
        prior = state
        position = "844.178.692/976.4.46/689.816.709"
        step = serve.call({"cmd": "choose", "state": b64(prior),
                           "position": position, "turn": 1})
        check(step["op"] == "insert", f"choose is insert-only: {step['op']}")
        state = apply(state, step["coordinate"], step["text"])
        val = serve.call({"cmd": "validate", "state": b64(state), "step": step,
                          "prior_state": b64(prior)})
        check(val["verdict"] == "pass", f"validate placement: {val.get('detail')}")

        descriptor = {"turn": 1, "impl": IMPL, "coordinate": step["coordinate"],
                      "scroll_sha256": sha256(step["text"].encode()),
                      "prior_sha256": sha256(prior)}
        att = serve.call({"cmd": "attest", "descriptor": descriptor})
        signature = att["signature"]
        check("BEGIN PGP SIGNATURE" in signature, "attest returns armored signature")
        event = dict(descriptor)
        event["signature"] = signature
        state = apply(state, "1.1.1/1.1.1/2.1.1", canon(event))
        state = apply(state, "1.1.1/1.1.1/1.1.1",
                      "%s %s\n" % (step["coordinate"], descriptor["scroll_sha256"]))

        ver = serve.call({"cmd": "verify", "state": b64(state), "pubkeys": pubkey})
        check(ver["verdict"] == "pass" and ver["placements_checked"] == 1,
              f"verify one-placement stress.phext: {ver}")
    finally:
        serve.close()

    print("PASS" if not failures else f"FAILURES: {failures}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
