#!/usr/bin/env python3
"""Driver for Exocortical Stress Testing — the Exocortical Telephone Game.

Implements RULE.md as ruled (2026-11-24 10:37 CST):
- the draw: a race to find the Test of Will in CYOA by raw file I/O only;
- the game is tracked in stress.phext: index at 1.1.1/1.1.1/1.1.1 (the only
  mutable scroll), public keys at 1.1.1/1.1.1/1.1.2, its hash at
  1.1.1/1.1.1/1.1.3, hash-chained event scrolls at 1.1.1/1.1.1/2.1.<seq>,
  placements as write-once scrolls at their coordinates;
- one implementation at a time; echoes on 5-second intervals; popcorn
  election (the prior winner chooses the next); an elect who does not
  respond within 15 seconds ends the test with failure;
- the only legal move is inserting content at an unused coordinate;
- nodes self-validate the file at each step; failure is overwriting an
  immutable scroll from the prior step, tracked by consensus;
- success is 10,000 scroll placements across the network.

Usage:
  telephone.py new <game> --seed N [--target 10000]
  telephone.py play <game> [--max-steps N]
  telephone.py verify <game>
  telephone.py registry
"""
import argparse
import hashlib
import importlib.util
import json
import os
import random
import select
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.path.join(ROOT, "harness")
GAMES = os.path.join(ROOT, "games")
CERTS = os.path.join(ROOT, "certs")
CYOA_ROOT = os.path.expanduser("~/workspace/phext")
INDEX = (1, 1, 1, 1, 1, 1, 1, 1, 1)
KEYS = (1, 1, 1, 1, 1, 1, 1, 1, 2)
KH = (1, 1, 1, 1, 1, 1, 1, 1, 3)
EVENT_PREFIX = (1, 1, 1, 1, 1, 1, 2, 1)
INDEX_HEADER = "# exocortical stress testing - index of generated scrolls"
FULL_TEST = 10000

_spec = importlib.util.spec_from_file_location(
    "reference_adapter", os.path.join(HARNESS, "reference_adapter.py"))
_ref_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ref_mod)
REF = _ref_mod.ReferenceAdapter()


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canon(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def coord_str(pos) -> str:
    return "%d.%d.%d/%d.%d.%d/%d.%d.%d" % tuple(pos)


def parse_coord(s):
    return tuple(int(x) for grp in s.split("/") for x in grp.split("."))


# ---------------------------------------------------------------- registry
def load_registry():
    regs = {}
    base = os.path.join(HARNESS, "registry.json")
    if os.path.exists(base):
        for e in json.load(open(base)):
            regs[e["id"]] = e
    ports = os.path.join(ROOT, "ports")
    if os.path.isdir(ports):
        for name in sorted(os.listdir(ports)):
            rj = os.path.join(ports, name, "registration.json")
            if os.path.exists(rj):
                e = json.load(open(rj))
                regs[e["id"]] = e
    return regs


def adapter_path(entry):
    a = entry.get("adapter")
    if not a:
        return None
    return a if os.path.isabs(a) else os.path.join(ROOT, a)


def playing(regs):
    return [e for e in regs.values()
            if e.get("status") == "playing" and adapter_path(e)]


# ---------------------------------------------------------------- serve
class Serve:
    def __init__(self, entry):
        self.id = entry["id"]
        self.p = subprocess.Popen([adapter_path(entry), "serve"],
                                  stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True,
                                  bufsize=1)
        self.buf = ""

    def call(self, req, timeout=30):
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()
        line = self._readline(timeout)
        out = json.loads(line)
        if "error" in out:
            raise RuntimeError("%s: %s" % (self.id, out["error"]))
        return out

    def _readline(self, timeout):
        fd = self.p.stdout.fileno()
        deadline = time.monotonic() + timeout
        while "\n" not in self.buf:
            remain = deadline - time.monotonic()
            if remain <= 0:
                raise TimeoutError("%s did not respond" % self.id)
            r, _w, _x = select.select([fd], [], [], remain)
            if not r:
                raise TimeoutError("%s did not respond" % self.id)
            chunk = os.read(fd, 65536).decode("utf-8", "replace")
            if not chunk:
                raise RuntimeError("%s adapter died" % self.id)
            self.buf += chunk
        line, self.buf = self.buf.split("\n", 1)
        return line

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


# ---------------------------------------------------------------- game state
class Game:
    def __init__(self, name):
        self.name = name
        self.dir = os.path.join(GAMES, name)
        self.file = os.path.join(self.dir, "stress.phext")
        self.state_path = os.path.join(self.dir, "driver-state.json")
        self.state = json.load(open(self.state_path)) \
            if os.path.exists(self.state_path) else None

    def load_file(self):
        return open(self.file, "rb").read()

    def save(self, data):
        tmp = self.file + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, self.file)
        with open(self.state_path, "w") as f:
            json.dump(self.state, f, indent=1)

    def append_event(self, data, body):
        """Append a hash-chained event scroll; returns new file bytes."""
        m = REF.explode(data)
        seq = self.state["event_seq"] + 1
        body = dict(body)
        text = canon({"prev": self.state["last_event_hash"], "body": body})
        m[EVENT_PREFIX + (seq,)] = text
        self.state["event_seq"] = seq
        self.state["last_event_hash"] = sha256(canon(body))
        return REF.implode(m)


# ---------------------------------------------------------------- the draw
def run_draw(players):
    procs = {}
    for e in players:
        p = subprocess.Popen([adapter_path(e), "seek", CYOA_ROOT],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True)
        procs[e["id"]] = (p, time.monotonic())
    results, winner = {}, None
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        done = [i for i, (p, _t) in procs.items()
                if p.poll() is not None and i not in results]
        for i in done:
            p, t0 = procs[i]
            try:
                res = json.loads(p.stdout.read() or "{}")
            except Exception:
                res = {"impl": i, "path": None}
            res["elapsed_s"] = round(time.monotonic() - t0, 3)
            results[i] = res
            if winner is None and res.get("path"):
                if verify_finding(res):
                    winner = i
        if winner and len(results) == len(procs):
            break
        if len(results) == len(procs):
            break
        time.sleep(0.02)
    for i, (p, _t) in procs.items():
        if p.poll() is None:
            p.kill()
            results.setdefault(i, {"impl": i, "path": None,
                                   "note": "still seeking when the draw "
                                           "was won"})
    return winner, results


def verify_finding(res):
    try:
        data = open(res["path"], "rb").read()
        m = REF.explode(data)
        text = m.get(parse_coord(res["coordinate"]), b"")
        head = text.split(b"\n", 2)
        return text.startswith(b"The Test of Will") and len(head) > 1 and \
            head[1].strip() == ("Coordinate: " +
                                res["coordinate"]).encode()
    except Exception:
        return False


# ---------------------------------------------------------------- commands
def cmd_new(args):
    regs = load_registry()
    players = playing(regs)
    if len(players) < 2:
        sys.exit("need at least 2 playing implementations")
    game = Game(args.game)
    os.makedirs(os.path.join(game.dir, "tmp"), exist_ok=True)
    # identity: one PGP key per participant, keys inscribed at the start
    pubkeys = {}
    for e in players:
        out = subprocess.run([adapter_path(e), "keygen"],
                             capture_output=True, text=True, timeout=300)
        pubkeys[e["id"]] = json.loads(out.stdout)["pubkey"]
    winner, draw = run_draw(players)
    if winner is None:
        sys.exit("the draw found no verified finder of the Test of Will")
    rng = random.Random(args.seed)
    pos = [rng.randint(1, 999) for _ in range(9)]
    keys_text = "\n".join("== %s ==\n%s" % (e["id"], pubkeys[e["id"]].strip())
                          for e in players) + "\n"
    m = {INDEX: (INDEX_HEADER + "\n").encode(),
         KEYS: keys_text.encode(),
         KH: sha256(keys_text.encode()).encode()}
    data = REF.implode(m)
    game.state = {"game": args.game, "seed": args.seed,
                  "target": args.target, "players": [e["id"] for e in players],
                  "position": pos, "holder": winner, "placements": 0,
                  "event_seq": 0, "last_event_hash": None,
                  "pending_consensus": {}, "pending_echoes": [],
                  "placements_by": {}, "status": "running",
                  "keys_text": keys_text}
    data = game.append_event(data, {
        "type": "genesis", "game": args.game, "seed": args.seed,
        "position": pos, "position_str": coord_str(pos),
        "draw_winner": winner, "draw": draw,
        "players": game.state["players"], "target": args.target})
    game.save(data)
    # every node self-validates the starting file
    serves = {e["id"]: Serve(e) for e in players}
    try:
        for e in players:
            serves[e["id"]].call({"cmd": "init", "state_path": game.file})
    finally:
        for s in serves.values():
            s.close()
    print("game %s: draw won by %s; start position %s; players %s" %
          (args.game, winner, coord_str(pos), game.state["players"]))


def end_test(game, data, serves, result, reason, consensus=None):
    body = {"type": "end", "result": result, "reason": reason,
            "placements": game.state["placements"],
            "consensus_last": consensus or game.state["pending_consensus"]}
    data = game.append_event(data, body)
    game.state["status"] = result
    game.save(data)
    for s in serves.values():
        s.close()
    print("test ended: %s — %s (placements: %d)" %
          (result, reason, game.state["placements"]))


def cmd_play(args):
    regs = load_registry()
    players = playing(regs)
    by_id = {e["id"]: e for e in players}
    game = Game(args.game)
    if not game.state or game.state["status"] != "running":
        sys.exit("game %s is not running" % args.game)
    serves = {e["id"]: Serve(e) for e in players}
    data = game.load_file()
    # reconcile the cached driver state from stress.phext itself —
    # the file is the ground truth, never the cache
    _m = REF.explode(data)
    _lines = [ln for ln in _m[INDEX].decode("latin-1").splitlines()
              if ln and not ln.startswith("#")]
    _events = sorted((c[8], json.loads(t)) for c, t in _m.items()
                     if c[:8] == EVENT_PREFIX)
    game.state["placements"] = len(_lines)
    game.state["placements_by"] = {}
    for _ln in _lines:
        _a = _ln.split(" ", 3)[3]
        game.state["placements_by"][_a] = \
            game.state["placements_by"].get(_a, 0) + 1
    if _events:
        game.state["event_seq"] = _events[-1][0]
        game.state["last_event_hash"] = sha256(canon(_events[-1][1]["body"]))
        if _events[-1][1]["body"].get("type") == "end":
            game.state["status"] = _events[-1][1]["body"]["result"]
        for _s, _ev in reversed(_events):
            if _ev["body"].get("type") == "placement":
                game.state["holder"] = _ev["body"]["actor"]
                game.state["position"] = list(
                    parse_coord(_ev["body"]["coord"]))
                break
    game.state["pending_echoes"] = []
    game.state.pop("last_consensus", None)
    for e in players:  # re-init validator caches on resume
        serves[e["id"]].call({"cmd": "init", "state_path": game.file})
    last_echo = 0.0
    steps = 0
    try:
        while game.state["placements"] < game.state["target"]:
            if args.max_steps and steps >= args.max_steps:
                print("paused at %d placements (max-steps)" %
                      game.state["placements"])
                game.save(data)
                return
            # echoes on 5-second intervals, spanning current + next round
            if time.monotonic() - last_echo >= 5:
                ping = {"game": args.game,
                        "round": game.state["placements"] + 1,
                        "nonce": sha256(data)}
                game.state["pending_echoes"] = [
                    serves[e["id"]].call({"cmd": "echo", "ping": ping})
                    for e in players]
                last_echo = time.monotonic()
            holder = game.state["holder"]
            pos = game.state["position"]
            turn = game.state["placements"] + 1
            counts = game.state["placements_by"]
            # popcorn election: the prior winner chooses the next one
            el = serves[holder].call(
                {"cmd": "elect", "position": coord_str(pos),
                 "candidates": [i for i in game.state["players"]
                                if i != holder],
                 "turn": turn, "placements": counts}, timeout=15)
            elect = el["elect"]
            # the elect must respond within 15 seconds, or the prior
            # ends the test with failure
            t0 = time.monotonic()
            try:
                step = serves[elect].call(
                    {"cmd": "choose", "state_path": game.file,
                     "position": coord_str(pos), "turn": turn}, timeout=15)
                if step.get("op") != "insert":
                    raise ValueError("illegal move: %s" % step.get("op"))
                out_path = os.path.join(game.dir, "tmp", "f1.phext")
                res = serves[elect].call(
                    {"cmd": "apply", "state_path": game.file, "step": step,
                     "state_out_path": out_path}, timeout=15)
                f1 = open(out_path, "rb").read()
                if sha256(f1) != res["state_sha256"]:
                    raise ValueError("apply hash mismatch")
                desc = {"turn": turn, "coordinate": step["coordinate"],
                        "scroll_sha256": sha256(
                            step["text"].encode("latin-1")),
                        "file_sha256": sha256(f1)}
                att = serves[elect].call({"cmd": "attest",
                                          "descriptor": desc}, timeout=15)
                if time.monotonic() - t0 > 15:
                    raise TimeoutError("elect response exceeded 15 seconds")
            except TimeoutError:
                end_test(game, data, serves, "failure",
                         "elect %s did not respond within 15 seconds; "
                         "prior %s ends the test" % (elect, holder))
                return
            # driver check: exactly one scroll added, nothing overwritten
            coord = parse_coord(step["coordinate"])
            before = REF.explode(data)
            after = REF.explode(f1)
            bad = None
            if REF.implode(after) != f1:
                bad = "actor serialization is not canonical"
            elif coord in before:
                bad = "coordinate already occupied (not a legal move)"
            elif after.get(coord) != step["text"].encode("latin-1"):
                bad = "placed scroll missing or altered"
            else:
                for c, text in before.items():
                    if after.get(c) != text:
                        bad = "prior scroll overwritten at %s" % coord_str(c)
                        break
                extra = [c for c in after if c not in before and c != coord]
                if extra:
                    bad = "unexpected extra scrolls"
            if bad:
                end_test(game, data, serves, "failure",
                         "step %d by %s: %s" % (turn, elect, bad))
                return
            # inscribe: index line + event scroll (hashes into the index,
            # the only mutable scroll)
            line = "%d %s %s %s\n" % (turn, step["coordinate"],
                                      desc["scroll_sha256"], elect)
            m = REF.explode(f1)
            m[INDEX] = m[INDEX] + line.encode()
            data = REF.implode(m)
            game.state["pending_consensus"] = {}
            data = game.append_event(data, {
                "type": "placement", "turn": turn, "actor": elect,
                "elect_by": holder, "coord": step["coordinate"],
                "text_sha256": desc["scroll_sha256"],
                "file_sha256": desc["file_sha256"],
                "att": att["signature"],
                "echoes": game.state["pending_echoes"],
                "consensus_prev": game.state.pop("last_consensus", {})})
            game.state["pending_echoes"] = []
            ev_coord = coord_str(EVENT_PREFIX +
                                 (game.state["event_seq"],))
            with open(game.file, "wb") as f:  # validators read the file
                f.write(data)
            # consensus: every node self-validates the file at this step
            verdicts = {}
            for e in players:
                v = serves[e["id"]].call(
                    {"cmd": "validate", "state_path": game.file,
                     "step": step, "event_coord": ev_coord,
                     "index_line": line}, timeout=60)
                verdicts[e["id"]] = v["verdict"]
            game.state["last_consensus"] = verdicts
            game.state["placements"] = turn
            counts[elect] = counts.get(elect, 0) + 1
            game.state["holder"] = elect
            game.state["position"] = list(coord)
            game.save(data)
            steps += 1
            if turn % 500 == 0 or turn <= 3:
                print("placement %d by %s at %s" %
                      (turn, elect, step["coordinate"]), flush=True)
            if any(v != "pass" for v in verdicts.values()):
                end_test(game, data, serves, "failure",
                         "consensus failed at step %d: %s" % (turn, verdicts))
                return
    finally:
        for s in serves.values():
            s.close()
    end_test(game, data, {e["id"]: Serve(e) for e in players}, "success",
             "reached %d scroll placements across the network"
             % game.state["target"])


def cmd_verify(args):
    regs = load_registry()
    game = Game(args.game)
    data = game.load_file()
    m = REF.explode(data)
    keys_text = m.get(KEYS, b"").decode("utf-8", "replace")
    verdicts, reasons = {}, []
    players = game.state["players"]
    for eid, e in sorted(regs.items()):
        if e.get("kind", "port") != "port":
            continue
        if eid not in players or not adapter_path(e):
            verdicts[eid] = {"verdict": "no-adapter"}
            reasons.append("%s: did not participate" % eid)
            continue
        s = Serve(e)
        try:
            v = s.call({"cmd": "verify", "state_path": game.file,
                        "pubkeys": keys_text}, timeout=3600)
        finally:
            s.close()
        verdicts[eid] = v
        if v.get("verdict") != "pass":
            reasons.append("%s: cross-check verdict %s" %
                           (eid, v.get("verdict")))
    counts = game.state.get("placements_by", {})
    for eid in players:
        e = regs.get(eid, {})
        if e.get("kind", "port") == "port" and counts.get(eid, 0) < 1:
            reasons.append("%s: never placed a scroll" % eid)
    full = game.state["target"] >= FULL_TEST and \
        game.state["placements"] >= FULL_TEST
    if not full:
        reasons.append("placements %d of %d (a full test is %d)"
                       % (game.state["placements"], game.state["target"],
                          FULL_TEST))
    if game.state["status"] != "success":
        reasons.append("test status: %s" % game.state["status"])
    result = "PASS" if not reasons else "HOLD"
    cert = {"game": args.game, "stress_sha256": sha256(data),
            "placements": game.state["placements"],
            "participants": players, "placements_by": counts,
            "verdicts": verdicts, "result": result, "reasons": reasons}
    os.makedirs(CERTS, exist_ok=True)
    with open(os.path.join(CERTS, args.game + ".json"), "w") as f:
        json.dump(cert, f, indent=2)
    lines = ["# Exocortical Stress Testing certificate — %s" % args.game, "",
             "- Result: **%s**" % result,
             "- stress.phext sha256: `%s`" % cert["stress_sha256"],
             "- Placements: %d (success unit: %d across the network)"
             % (cert["placements"], FULL_TEST),
             "- Participants: %s" % ", ".join(players),
             "- Placements by participant: %s" %
             json.dumps(counts, sort_keys=True),
             "", "## Cross-check verdicts", ""]
    for eid, v in sorted(verdicts.items()):
        lines.append("- %s: %s%s" % (eid, v.get("verdict"),
                     " (%s placements checked)" % v["placements_checked"]
                     if "placements_checked" in v else ""))
    if reasons:
        lines += ["", "## Hold reasons", ""] + ["- " + r for r in reasons]
    with open(os.path.join(CERTS, args.game + ".md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("certificate: %s (%d placements)" % (result,
                                               cert["placements"]))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("new"); p.add_argument("game")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--target", type=int, default=FULL_TEST)
    p.set_defaults(f=cmd_new)
    p = sub.add_parser("play"); p.add_argument("game")
    p.add_argument("--max-steps", type=int, default=0)
    p.set_defaults(f=cmd_play)
    p = sub.add_parser("verify"); p.add_argument("game")
    p.set_defaults(f=cmd_verify)
    p = sub.add_parser("registry"); p.set_defaults(
        f=lambda a: print(json.dumps(load_registry(), indent=2)))
    args = ap.parse_args()
    args.f(args)


if __name__ == "__main__":
    main()
