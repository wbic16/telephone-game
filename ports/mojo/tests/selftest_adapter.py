#!/usr/bin/env python3
"""Adapter self-test (contract v2, PINNED formats) for the tcl port.

Checks: one-shot id; serve id + echo twice identical; keygen (twice,
stable armored pubkey); seek finds the Test of Will in the CYOA corpus
by raw I/O and the reported offset reads back the title; elect returns
a candidate (twice identical); choose+apply insert-only round-trip
with validate passing against the prior state; attest produces an
armored signature; a one-placement stress.phext built entirely through
the adapter in the PINNED formats (keys scroll "== <id> ==" block,
keys-hash = sha256 of the keys scroll text exactly as inscribed,
index header + "<turn> <coord> <sha256> <actor>" line, event scroll
canonical JSON {"prev": null, "body": {...placement...}} with the
attestation descriptor {"turn","coordinate","scroll_sha256",
"file_sha256"}) verifies pass with placements_checked == 1.

Run: python3 tests/selftest_adapter.py
"""
import base64
import hashlib
import json
import subprocess
import sys
from pathlib import Path

IMPL = "mojo"
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
    return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True)


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
                     "candidates": [IMPL, "go", "php", "perl", "reference"],
                     "turn": 3}
        w1 = serve.call(elect_req)["elect"]
        w2 = serve.call(elect_req)["elect"]
        check(w1 == w2 and w1 in elect_req["candidates"], f"elect -> {w1}")

        kg1 = json.loads(run_oneshot("keygen"))
        kg2 = json.loads(run_oneshot("keygen"))
        pubkey = kg1["pubkey"]
        check(kg1["impl"] == IMPL and "BEGIN PGP PUBLIC KEY BLOCK" in pubkey,
              "keygen returns armored pubkey")
        check(kg2["pubkey"] == pubkey, "keygen is stable")

        found = json.loads(run_oneshot("seek", str(CORPUS)))
        check(found["coordinate"] == "13.13.13/13.13.13/13.13.13",
              "seek coordinate")
        check(found["title"] == "The Test of Will",
              f"seek title: {found['title']!r}")
        with open(found["path"], "rb") as f:
            f.seek(found["offset"])
            head = f.read(len(found["title"]))
        check(head.decode("utf-8") == found["title"],
              "seek offset reads back the title")

        def apply(state, coord, text, op="insert"):
            step = {"op": op, "coordinate": coord, "text": text}
            resp = serve.call({"cmd": "apply", "state": b64(state),
                               "step": step})
            assert resp["state_sha256"] == sha256(
                base64.b64decode(resp["state_b64"]))
            return base64.b64decode(resp["state_b64"])

        keys_text = "== %s ==\n%s" % (IMPL, pubkey)
        if not keys_text.endswith("\n"):
            keys_text += "\n"
        state = b""
        state = apply(state, "1.1.1/1.1.1/1.1.2", keys_text)
        state = apply(state, "1.1.1/1.1.1/1.1.3",
                      sha256(keys_text.encode()))
        prior = state
        position = "844.178.692/976.4.46/689.816.709"
        step = serve.call({"cmd": "choose", "state": b64(prior),
                           "position": position, "turn": 1})
        check(step["op"] == "insert", f"choose is insert-only: {step['op']}")
        state = apply(state, step["coordinate"], step["text"])
        placed_state = state
        val = serve.call({"cmd": "validate", "state": b64(state),
                          "step": step, "prior_state": b64(prior)})
        check(val["verdict"] == "pass",
              f"validate placement: {val.get('detail')}")

        descriptor = {"turn": 1, "coordinate": step["coordinate"],
                      "scroll_sha256": sha256(step["text"].encode()),
                      "file_sha256": sha256(placed_state)}
        att = serve.call({"cmd": "attest", "descriptor": descriptor})
        signature = base64.b64decode(att["signature"]).decode()
        check("BEGIN PGP SIGNATURE" in signature,
              "attest returns armored signature")

        body = {"type": "placement", "turn": 1, "actor": IMPL,
                "elect_by": IMPL, "coord": step["coordinate"],
                "text_sha256": descriptor["scroll_sha256"],
                "file_sha256": descriptor["file_sha256"],
                "att": att["signature"], "echoes": [],
                "consensus_prev": {}}
        event = {"prev": None, "body": body}
        state = apply(state, "1.1.1/1.1.1/2.1.1", canon(event))
        index_text = ("# exocortical stress testing - index of "
                      "generated scrolls\n1 %s %s %s\n"
                      % (step["coordinate"], descriptor["scroll_sha256"],
                         IMPL))
        state = apply(state, "1.1.1/1.1.1/1.1.1", index_text)

        ver = serve.call({"cmd": "verify", "state": b64(state),
                          "pubkeys": keys_text})
        check(ver["verdict"] == "pass" and ver["placements_checked"] == 1,
              f"verify one-placement stress.phext: {ver}")
    finally:
        serve.close()

    print("PASS" if not failures else f"FAILURES: {failures}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
