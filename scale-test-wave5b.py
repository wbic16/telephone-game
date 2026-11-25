#!/usr/bin/env python3
"""Game-scale init + validate timing for one adapter (wave 5b).

Method (mirrors harness/serve-conformance.md): serve init on a
snapshot COPY of games/test-001/stress.phext (never the original),
timed against the driver's 30 s timeout; then a placement is made
through the same serve (choose+apply), the placed state is built
locally (placement + appended index line + dummy event scroll, as in
adapter_selftest), the serve is re-init'd on the pre-turn snapshot,
and driver-form validate is timed against the 60 s timeout.

Usage: scale-test-wave5b.py <adapter_path> <impl>
"""
import base64
import gzip
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = os.path.expanduser("~/workspace/libphext-telephone")
SNAPSHOT = "/tmp/wave5b-test001-snapshot.phext"
INDEX = (1, 1, 1, 1, 1, 1, 1, 1, 1)
EVENT1K = (1, 1, 1, 1, 1, 1, 2, 1, 1002)
BREAKS = b"\x01\x1f\x1e\x1d\x1c\x1a\x19\x18\x17"
BDIM = {b: d for d, b in enumerate(BREAKS)}


def sha256(b):
    return hashlib.sha256(b).hexdigest()


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

    def ask(self, payload, timeout_note=""):
        t0 = time.time()
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        dt = time.time() - t0
        assert line, "serve closed for %s" % payload.get("cmd")
        line = line.strip()
        if line.startswith("GZ1:"):
            line = gzip.decompress(base64.b64decode(line[4:])).decode()
        return json.loads(line), dt

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=15)
        except Exception:
            self.proc.kill()


def main():
    adapter = os.path.abspath(sys.argv[1])
    impl = sys.argv[2]
    if not os.path.exists(SNAPSHOT):
        data = open(os.path.join(ROOT, "games/test-001/stress.phext"), "rb").read()
        with open(SNAPSHOT, "wb") as f:
            f.write(data)
    prior = open(SNAPSHOT, "rb").read()
    print("snapshot: %d bytes sha256=%s" % (len(prior), sha256(prior)))

    serve = Serve(adapter)
    try:
        init, dt_init = serve.ask({"cmd": "init", "state_path": SNAPSHOT})
        print("init: %.2f s -> %s (driver timeout 30 s)" % (dt_init, init))
        step, dt_ch = serve.ask({"cmd": "choose", "state": b64(prior),
                                 "position": "4.4.4/4.4.4/4.4.4", "turn": 1001})
        print("choose: %.2f s -> %s" % (dt_ch, step))
        applied, dt_ap = serve.ask({"cmd": "apply", "state": b64(prior),
                                    "step": step})
        new_state = base64.b64decode(applied["state_b64"])
        print("apply: %.2f s sha match=%s" % (dt_ap, applied["state_sha256"] == sha256(new_state)))
        new_map = explode(new_state)
        text_sha = sha256(step["text"].encode("latin-1"))
        index_line = "1001 %s %s %s" % (step["coordinate"], text_sha, impl)
        placed_map = dict(new_map)
        old_index = explode(prior).get(INDEX, b"")
        placed_map[INDEX] = old_index + (index_line + "\n").encode()
        placed_map[EVENT1K] = b"{}"
        placed = implode(placed_map)
        # re-init on the pre-turn snapshot so the cache is the prior state
        serve.ask({"cmd": "init", "state_path": SNAPSHOT})
        val, dt_val = serve.ask({"cmd": "validate", "state": b64(placed),
                                 "step": step,
                                 "event_coord": "1.1.1/1.1.1/2.1.1002",
                                 "index_line": index_line})
        print("validate: %.2f s -> %s (driver timeout 60 s)" % (dt_val, val))
    finally:
        serve.close()


if __name__ == "__main__":
    main()
