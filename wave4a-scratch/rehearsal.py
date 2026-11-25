#!/usr/bin/env python3
"""Wave-4a game-scale rehearsal for one adapter, mirroring
harness/telephone.py cmd_play for a single turn against a COPY of
games/test-001/stress.phext (the original is never written):
  serve init (driver budget 30 s, timed)
  -> choose/apply/attest by the port under test (15 s class)
  -> driver inscription (index line + hash-chained event, via the
     reference libphext-py implementation)
  -> serve validate (driver budget 60 s, timed)
Usage: rehearsal.py <adapter-path> <impl> <workdir>
"""
import base64
import hashlib
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path.home() / "workspace" / "libphext-telephone"
# Minimal driver-side phext walker (latin-1 byte-transparent), the
# same semantics the harness reference implements; used only to
# inscribe the rehearsal turn, never by the port under test.
BREAKS = "\x01\x1f\x1e\x1d\x1c\x1a\x19\x18\x17"
BDIM = {ch: d for d, ch in enumerate(BREAKS)}
INDEX = (1, 1, 1, 1, 1, 1, 1, 1, 1)


def phokenize(buf):
    walker = [1] * 9
    out = []
    i = 0
    while i < len(buf):
        if buf[i] in BDIM:
            d = BDIM[buf[i]]
            walker[d] += 1
            for k in range(d + 1, 9):
                walker[k] = 1
            i += 1
        else:
            j = i
            while j < len(buf) and buf[j] not in BDIM:
                j += 1
            out.append((tuple(walker), buf[i:j]))
            i = j
    return out


def _advance(loc, target):
    target = list(target)
    if loc >= target:
        return "", list(loc)
    d = next(i for i in range(9) if loc[i] != target[i])
    parts = [BREAKS[d] * (target[d] - loc[d])]
    reached = list(loc[:d]) + [target[d]] + [1] * (8 - d)
    for lower in range(d + 1, 9):
        parts.append(BREAKS[lower] * (target[lower] - 1))
        reached[lower] = target[lower]
    return "".join(parts), reached


def dephokenize(scrolls):
    loc = [1] * 9
    out = []
    for coord, text in scrolls:
        adv, loc = _advance(loc, coord)
        out.append(adv)
        out.append(text)
    return "".join(out)


def p_insert(buf, coord, text, overwrite=False):
    items = phokenize(buf)
    result = []
    nxt = (coord, text)
    placed = False
    for c, t in items:
        if not placed and c > coord:
            result.append(nxt)
            placed = True
        if not placed and c == coord:
            result.append((coord, text if overwrite else t + text))
            placed = True
            continue
        result.append((c, t))
    if not placed:
        result.append(nxt)
    return dephokenize(result)


def p_fetch(buf, coord):
    for c, t in phokenize(buf):
        if c == coord:
            return t
    return ""


class Phext:
    def insert(self, buf, coord, text):
        return p_insert(buf, coord, text)

    def replace(self, buf, coord, text):
        return p_insert(buf, coord, text, overwrite=True)

    def fetch(self, buf, coord):
        return p_fetch(buf, coord)


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canon(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


class Serve:
    def __init__(self, adapter):
        self.proc = subprocess.Popen([str(adapter), "serve"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True)

    def call(self, obj, timeout_note=""):
        start = time.time()
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        elapsed = time.time() - start
        assert line, "serve process closed the pipe"
        return json.loads(line), elapsed

    def close(self):
        try:
            self.proc.stdin.close()
        except BrokenPipeError:
            pass
        self.proc.wait(timeout=60)


def main():
    adapter = Path(sys.argv[1])
    impl = sys.argv[2]
    work = Path(sys.argv[3])
    work.mkdir(parents=True, exist_ok=True)
    snap = work / "snapshot.phext"
    shutil.copyfile(ROOT / "games" / "test-001" / "stress.phext", snap)
    dstate = json.loads((ROOT / "games" / "test-001" / "driver-state.json").read_text())
    # derive the chain head from the FILE (driver-state.json can lag it)
    snap_text = snap.read_bytes().decode("latin-1")
    events = {}
    for c, t in phokenize(snap_text):
        if c[:8] == (1, 1, 1, 1, 1, 1, 2, 1):
            events[c[8]] = t
    last_seq = max(events)
    prev_hash = sha256(canon(json.loads(events[last_seq])["body"]).encode())
    seq = last_seq + 1
    turn = seq
    print(f"chain head from file: last event seq {last_seq}, prev {prev_hash[:12]}...")
    position = ".".join(str(x) for x in dstate["position"][:3]) + "/" + \
        ".".join(str(x) for x in dstate["position"][3:6]) + "/" + \
        ".".join(str(x) for x in dstate["position"][6:9])

    serve = Serve(adapter)
    try:
        resp, dt = serve.call({"cmd": "init", "state_path": str(snap)})
        print(f"INIT {impl}: {dt:.2f}s -> {resp}")
        assert resp.get("verdict") == "pass", resp
        assert dt <= 30, "init exceeded the 30 s driver timeout"

        state = snap.read_bytes()
        step, dt = serve.call({"cmd": "choose", "state_path": str(snap),
                               "position": position, "turn": turn})
        print(f"CHOOSE {impl}: {dt:.2f}s -> {step}")
        assert step["op"] == "insert"
        out_path = work / "applied.phext"
        resp, dt = serve.call({"cmd": "apply", "state_path": str(snap),
                               "step": step, "state_out_path": str(out_path)})
        print(f"APPLY {impl}: {dt:.2f}s -> {resp}")
        state = out_path.read_bytes()
        assert sha256(state) == resp["state_sha256"]

        text_hash = sha256(step["text"].encode())
        file_hash = sha256(state)
        descriptor = {"turn": turn, "coordinate": step["coordinate"],
                      "scroll_sha256": text_hash, "file_sha256": file_hash}
        att, dt = serve.call({"cmd": "attest", "descriptor": descriptor})
        print(f"ATTEST {impl}: {dt:.2f}s -> signature {len(att['signature'])} chars")
        signature = att["signature"]
        if "BEGIN PGP SIGNATURE" not in signature:
            signature = base64.b64decode(signature).decode()

        # driver inscription (reference implementation)
        p = Phext()
        text = state.decode("latin-1")
        body = {"type": "placement", "turn": turn, "actor": impl,
                "elect_by": impl, "coord": step["coordinate"],
                "text_sha256": text_hash, "file_sha256": file_hash,
                "att": base64.b64encode(signature.encode()).decode(),
                "echoes": {}, "consensus_prev": None}
        event = {"prev": prev_hash, "body": body}
        ev_coord = (1, 1, 1, 1, 1, 1, 2, 1, seq)
        text = p.insert(text, ev_coord, canon(event))
        index_line = f"{turn} {step['coordinate']} {text_hash} {impl}"
        idx = p.fetch(text, INDEX)
        new_idx = idx + ("" if idx.endswith("\n") or idx == "" else "\n") + index_line + "\n"
        text = p.replace(text, INDEX, new_idx)
        post = work / "post-turn.phext"
        post.write_bytes(text.encode("latin-1"))

        resp, dt = serve.call({"cmd": "validate", "state_path": str(post),
                               "step": step,
                               "event_coord": f"1.1.1/1.1.1/2.1.{seq}",
                               "index_line": index_line})
        print(f"VALIDATE {impl}: {dt:.2f}s -> {resp}")
        assert resp.get("verdict") == "pass", resp
        assert dt <= 60, "validate exceeded the 60 s driver timeout"
    finally:
        serve.close()
    print(f"REHEARSAL {impl}: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
