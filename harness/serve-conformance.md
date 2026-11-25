# Serve-protocol conformance — audit + fixes (in progress)

Started 2026-11-24 ~11:37 CST. Trigger: resumed game crashed in
`harness/telephone.py` `cmd_play` — it sends `{"cmd":"init",
"state_path": ...}` to every registered adapter's serve process at
play startup, and the Fortran adapter answered `unknown cmd`.

## Required serve command set (contract v2 + driver, together)

Driver (`telephone.py`) serve calls, verbatim forms:

| cmd | request fields | used in |
|---|---|---|
| init | `state_path` | cmd_new, cmd_play (re-init on resume) |
| echo | `ping` {game, round, nonce} | cmd_play, 5 s intervals |
| elect | `position`, `candidates`, `turn`, `placements` | cmd_play |
| choose | `state_path`, `position`, `turn` | cmd_play (15 s limit) |
| apply | `state_path`, `step`, `state_out_path` | cmd_play |
| attest | `descriptor` {turn, coordinate, scroll_sha256, file_sha256} | cmd_play |
| validate | `state_path`, `step`, `event_coord`, `index_line` | cmd_play |
| verify | `state_path`, `pubkeys` | cmd_verify |

Contract v2 names the same subcommands with state as base64
(`state`); `adapter_base._state_bytes` accepts either form locally.
Hub ports' wire protocol is base64-only, so their local wrappers must
translate `state_path` → `state` (and `state_out_path` on apply).

## Static audit (source reading)

- py, reference: subclass `harness/adapter_base.py`, whose `handle()`
  implements id/keygen/seek/echo/elect/choose/apply/attest/**init**/
  validate/verify incl. `state_path`. Expected conformant.
- dart, julia: also subclass adapter_base (hub CLI used only for the
  explode/implode/insert/fetch hooks). Expected conformant at the
  serve layer. Owned by wave-1b worker — audit read-only, no edits.
- go, php, perl, fortran: local wrapper `serve()` relays driver JSON
  lines **verbatim** over fleet-ssh to the hub CLI serve loop.
  Hub CLI dispatch (go main.go, php telephone.php, perl telephone.pl,
  fortran telephone.f90) implements id/echo/elect/choose/apply/keygen/
  attest/validate/verify — **no `init` in any of the four** — and
  expects state as base64 `state`/`state_b64`, never `state_path`.
  Consequences in driver form: init → unknown cmd; choose/apply/
  validate/verify → empty state. Hub `validate` also has selftest
  semantics (prior_state, count +1, all prior byte-intact incl.
  index), which do not match driver validate (file already carries
  the placement + event scroll + appended index line; prior state is
  the init/validate cache, cf. adapter_base.validate).

## Live audit

Method: `/tmp/audit_serve.py` spawns each adapter's `serve`, sends
the driver-form requests above against a scratch copy of
`games/smoke-001/stress.phext` (original never touched), in driver
order: init → echo → elect → choose → apply → attest → validate
(against a driver-inscribed file: placement + index line + event
scroll added via the reference implementation) → verify (smoke file,
30 placements). Performed 2026-11-24 ~11:40–11:50 CST.

| adapter | init | echo | elect | choose | apply | attest | validate | verify |
|---|---|---|---|---|---|---|---|---|
| reference | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| py | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| dart | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| julia | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| go | **unknown cmd** | OK | OK | **empty state** | **empty state** | OK | **fail** | **fail** |
| php | **unknown cmd** | OK | OK | **empty state** | **empty state** | OK | **fail** | **fail** |
| perl | **unknown cmd** | OK | OK | **empty state** | **empty state** | OK | **fail** | **fail** |
| fortran | **unknown cmd** | OK | OK | **empty state** | **empty state** | OK | **fail** | **fail** |

"empty state": the hub CLI received no `state` (driver sent
`state_path`, wrapper relayed verbatim), so choose/apply ran against
a zero-byte state — apply returned a phext containing only the new
placement, and never wrote `state_out_path`; validate/verify then
failed on the empty state ("placed scroll absent…", "no public-keys
scroll at 1.1.1/1.1.1/1.1.2"). Verbatim init errors: go
`unknown cmd "init"`, php `unknown cmd init`, perl `unknown cmd
init`, fortran `unknown cmd`.

dart/julia (wave-1b-owned at audit time): **no gaps** — nothing to
report upstream beyond this table; their files were not touched.

## Fixes

For go/php/perl/fortran (wave-1a, unowned — fixed here):

1. Local wrapper `serve()` (ports/<p>/adapter): translate at the
   boundary — `state_path` → base64 `state` (read the file locally);
   on apply, pop `state_out_path`, write the returned `state_b64`
   there, answer `{"state_sha256": ...}`. All other commands relay
   unchanged. (Mirrors adapter_base: path locally, base64 over SSH.)
2. Hub CLI (ports/<p>/src, synced byte-identical to hub): implement
   `init` — cache the state in the serve process, reply
   `{"impl": id, "verdict": "pass"}`; extend `validate` with the
   driver form (request carries `event_coord`/`index_line`): prior
   state = the init/validate cache (explicit `prior_state` still
   wins), checks per adapter_base.validate — placed scroll present
   with step text, every prior scroll except the index byte-intact,
   new scrolls only at the placement and event coordinates, index
   ends with `index_line`; on pass the cache advances to the new
   state. Legacy wire validate (selftest form) unchanged.
3. Rebuild compiled hub binaries (go, fortran); re-run one-shot
   verify (expect PASS/30) + full serve audit per port.

## Fix results (2026-11-24 ~11:43–12:05 CST)

Implemented exactly as designed above:

- Wrapper `serve()` translation added to ports/{go,php,perl,fortran}/
  adapter (identical template in all four).
- Hub CLI `init` + driver-form `validate` added to:
  go `src/cmd/telephone/main.go`, php `src/telephone.php`,
  perl `src/telephone.pl`, fortran `src/telephone.f90`.
- Synced to hub; md5 local == hub for every changed file:
  go main.go `b127fede4553b652140365548a107c39`,
  php telephone.php `67b3d60f6709fcfe7f1a0895a64d4451`,
  perl telephone.pl `1f911aa8b545a8d273cffaa74d2132f9`,
  fortran telephone.f90 `4d25a8bd5184a556723b6b5ed0d39fac`.
- Rebuilt on hub: `telephone-go/telephone` (3,337,827 B, 11:43 CST,
  `go build ./cmd/telephone` with ~/tools/go) and
  `telephone-fortran/telephone` (147,936 B, 11:43 CST, hub gfortran
  wrapper over src/phext.f90 + src/wire.f90 + src/telephone.f90).
  php/perl are interpreted — no rebuild.

Regression per fixed port — BOTH gates pass for all four:

- One-shot `adapter verify games/smoke-001/stress.phext`:
  go/php/perl/fortran all `verdict pass, placements_checked 30`.
- Serve audit (same driver-form battery as the live audit):
  all four now 8/8 OK — init `{"impl":…,"verdict":"pass"}`,
  choose on the real state, apply hash-match with `state_out_path`
  written, driver-form validate `pass` ("placed at unused
  coordinate; all prior scrolls intact"), verify pass/30.

Legacy wire path intact: each port's own `tests/selftest_adapter.py`
passes every check except one **pre-existing** failure, identical in
all four ports and unrelated to this fix (no verify/keys-hash code
was touched): the selftest's one-placement fixture hashes
`pubkey.rstrip()` for the keys-hash scroll, while the wave-1a pinned
verify hashes the keys scroll text exactly as inscribed —
`FAIL verify one-placement stress.phext: keys-hash scroll does not
match the keys scroll`. Flagged here; fixing the stale selftest
fixtures is a separate task.

## Extended audit — wave-1b ports (completed, unowned)

Scope extended after wave-1b finished (dart, julia, ruby, r all
registered `playing`). Same driver-form battery, 2026-11-24
~11:44–11:52 CST:

| adapter | init | echo | elect | choose | apply | attest | validate | verify |
|---|---|---|---|---|---|---|---|---|
| dart | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| julia | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| ruby | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| r | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |

No gaps in any of the four (all subclass adapter_base); no files
changed, no fixes required.

## Final registry sweep (2026-11-24 ~12:05 CST)

`playing`: reference, py, go, php, fortran, perl, dart, julia, ruby,
r — **all 10 audited; all conformant** (4 fixed here, 6 already
conformant). `blocked` (execution-risk flag; not run): rs, cs, node,
java, kotlin, swift. `registered` with no adapter: cpp, c. Wave-2
ports (vb, lua, ocaml, nim, awk, bash, fsharp, tcl) have local
adapter files but **no registration.json yet** — not registered,
still building per the coordinator; report-only, not audited, not
touched.

No game was started or resumed. All serve processes spawned by this
audit were closed; nothing belonging to other workers was killed.

## Game-scale init audit (2026-11-24 ~11:56 CST +, in progress)

Trigger: test-001 resume attempt 2 (games/test-001/play.log lines
15–27) got past the fixed Fortran `unknown cmd`, then died with
`TimeoutError: dart did not respond` at telephone.py line 326 —
`cmd_play` sends `{"cmd":"init","state_path":...}` to every serve.

### Contract / driver facts

- ADAPTER-CONTRACT.md does not define `init` at all; the operative
  definition is `harness/adapter_base.py::init_cache`: explode the
  state once, cache the map + sha256, reply
  `{"impl": id, "verdict": "pass"}`. No verification walk — the total
  walk is `verify` (separate command, 3600 s driver timeout). Hub
  CLIs mirror this (go caches raw bytes; lua/nim/ocaml/vb explode
  into a cache map).
- Driver timeout for init: `Serve.call` default **30 s** (cmd_play /
  cmd_new pass no override). Validate gets 60 s; choose/apply/attest
  15 s; verify 3600 s.

### Reproduction (dart, snapshot copy of test-001, never the original)

Snapshot: `~/workspace/scale-audit-scratch/test-001-snapshot.phext`
(2,236,326 B, 1,000 placements, 2,004 scrolls); smoke comparison
copy 53,615 B / 30 placements.

- dart serve init, smoke snapshot, solo: **8.58 s** (pass).
- dart serve init, test snapshot, solo: **25.14 s** (pass) — answers,
  but at 84% of the driver budget before any contention.
- Hub-side dart explode of the same state (direct on aletheia-core):
  **0.31 s cold / 0.07 s warm** — the Dart load is NOT slow.
- Local adapter explode (through fleet-ssh): smoke 2.29 s; test
  12.99 s cold / ~10.5 s warm process.
- Raw channel probe: `cat` of 2,981,768 B through fleet-ssh
  (up + down) took **82.69 s ≈ 72 KB/s aggregate**; during another
  worker's hub install the observed upload rate fell to ~24 KB/s.
  **The fleet-ssh / egress-proxy channel is the bottleneck.** Every
  hub adapter's init ships the full state as base64 (~3.0 MB) over
  it; adapter_base subclass ports (dart/julia/ruby/r) also ship the
  exploded map (~1.3 MB) back. At game scale that is minutes, not
  the sub-second local explode (reference init 0.52 s, py 0.59 s on
  the same snapshot). In the failed game run, contention pushed
  dart past 30 s. Not a hang, not CPU, not re-verification.

### Per-adapter init at game scale (timed, 300 s cap, contended channel)

| adapter | init latency (1,000-placement snapshot) | vs 30 s driver timeout |
|---|---|---|
| reference | 0.52 s OK | within |
| py | 0.59 s OK | within |
| dart | 25.14 s OK (solo); timed out in game under contention | at risk / exceeds in practice |
| go | 269.17 s OK (slow) | exceeds |
| php | 150.96 s OK (slow) | exceeds |
| perl | pending | |
| fortran | pending | |
| julia | pending | |
| ruby | pending | |
| r | pending | |
| lua | pending (see hollow-init note) | |
| nim | pending (see hollow-init note) | |
| ocaml | pending (see hollow-init note) | |
| vb | pending (see hollow-init note) | |

awk/bash/fsharp/tcl: adapters exist locally but have **no
registration.json** — not registered, not audited (per task scope).

### Side discovery: hollow init in lua/nim/ocaml/vb

These four adapters' `serve()` was a pure relay with **no
state_path → state translation**. Driver-form init therefore reached
the hub CLI with no state at all: hub `init_cache` cached an EMPTY
state and replied pass; driver-form `validate` could never pass
against that cache. Their registration self-tests used the wire form
(state as base64), so the gap was invisible until this audit. Fix:
same translating serve() as go/php/perl/fortran (below).

### Fix (in progress)

Lossless wire framing in each port's own source (local adapter +
hub CLI, md5-synced): serve lines over 8 KB travel as
`GZ1:` + base64(gzip(line)) in both directions; small lines stay
plain (one-shot mode and selftests unaffected). The snapshot
gzips 2,236,326 B → 345,597 B (6.5×). No bytes skipped, no
cross-process caching: the hub still receives, decompresses and
explodes/loads the complete state at init, exactly as before —
only the channel encoding changed. Driver untouched; its 30 s
timeout is NOT miscalibrated for a legitimate load (local load is
0.5 s; hub load 0.3 s) — it was the uncompressed transfer that
did not fit.

### Game-scale audit — final results (supersedes the interim table above)

Pre-fix timed init on the 1,000-placement snapshot (driver timeout
30 s; channel contended by another worker's hub install for part of
the sweep — noted where it bit). Re-runs for fortran/julia/ruby/r/lua
used byte-reconstructed pre-fix adapters (the first sweep's later
rows were contaminated by this worker's own mid-sweep edits and are
discarded):

| adapter | pre-fix init | class |
|---|---|---|
| reference | 0.52 s pass | within |
| py | 0.59 s pass | within |
| dart | 25.14 s pass solo; **timeout in game** | exceeds in practice |
| go | 269.17 s pass | exceeds (9×) |
| php | 150.96 s pass | exceeds |
| perl | 125.55 s pass | exceeds |
| fortran | 32.82 s pass | exceeds |
| julia | 52.10 s pass | exceeds |
| ruby | 116.70 s pass | exceeds |
| r | 234.82 s pass (first attempt died on an SSH banner-exchange timeout) | exceeds |
| lua | 7.26 s **hollow pass** (empty-state cache; see side discovery) | broken, not slow |
| nim, ocaml, vb | not cleanly measurable post-contamination; `serve()` byte-identical to lua's pure relay and hub `state_bytes` takes only `state`/`state_b64` — hollow by construction, same as lua | broken, not slow |

### Fix as built (all in each port's own source; hub copies md5-synced)

1. **GZ1 wire framing** (local adapter + hub CLI serve loops, all
   12 hub ports): serve lines over 8 KB travel as
   `GZ1:` + base64(gzip(line)) both directions; small lines and
   one-shot mode stay plain. Native gzip where the language has it
   (dart `dart:io`, go `compress/gzip`, php `gzencode`, perl
   `IO::Compress::Gzip`, ruby `zlib`, vb `GZipStream`); system
   `gzip(1)` on temp files where it does not (julia, lua, nim,
   ocaml, fortran). R hub emits zlib streams from
   `memCompress(type="gzip")` (magic `78 9c`, not a gzip member);
   r's local adapter falls back to `zlib.decompress` for framed
   replies. Compiled ports rebuilt on the hub: go (3,527,587 B),
   fortran (148,144 B), nim `-d:release` (415,088 B), ocaml
   (1,624,544 B), vb (Release dll installed to
   `~/telephone-vb/telephone.dll`).
2. **Deferred init cache** (the init-specific fix): init now caches
   the exact state bytes + sha256 in the serve process and replies
   immediately — no state crosses the channel inside the 30 s init
   budget. The cache is materialized where it is consumed:
   adapter_base ports (dart/julia/ruby/r) override `init_cache` /
   `validate` to explode the cached bytes through their own hooks
   at first validate; wrapper ports (go/php/perl/fortran/lua/nim/
   ocaml/vb) flush the cached bytes to the hub CLI as a framed real
   `init` immediately before the first `validate` (the only hub
   command that reads the cache). Every byte is still loaded and
   exploded by the port's own libphext before any verdict; nothing
   is cached across processes. `_cache_hash` is write-only in
   adapter_base, so the byte-cache is semantically identical.
3. **lua/nim/ocaml/vb serve() translation**: replaced the pure
   relay with the translating serve() (state_path → state,
   state_out_path on apply), closing the hollow-init gap.

Hub md5 == local for every changed file, incl.: dart cli
`7da3ca33…`, go main.go `2687fe72…`, php `0e1417c1…`, perl
`351bd022…`, fortran telephone.f90 `a5f458a1…`, lua `2038671c…`,
nim telephone.nim `40b903f2…`, ocaml `2f5f3525…`, vb `d6523e83…`,
julia cli.jl `c87034c7…`, ruby cli.rb `c68faa15…`, r cli.R
`aa179bb5…`, r adapter `6e0b99f6…`.

### Regression (per fixed adapter, all 12)

- Serve init on the 1,000-placement snapshot: **0.06–0.11 s** each
  (dart 0.10, julia 0.08, ruby 0.07, r 0.11, go 0.08, php 0.08,
  perl 0.06, fortran 0.06, lua 0.06, nim 0.06, ocaml 0.07, vb 0.06).
- Full driver-form serve audit on the smoke snapshot
  (init→echo→elect→choose→apply→attest→validate→verify):
  **8/8 PASS for all 12**, verify pass/30 in every case (validate
  passing for lua/nim/ocaml/vb also proves the hollow-init fix;
  passing validate everywhere proves the deferred caches
  materialize correctly).
- One-shot `adapter verify` on the smoke snapshot: PASS/30 for
  go, php, perl, fortran, lua, nim, ocaml, vb (subclass ports'
  verify covered via the serve audit).

### Verdicts and remaining risks

- **Driver timeout NOT miscalibrated; driver untouched.** A
  legitimate init load is 0.3–0.6 s (hub explode / local explode);
  30 s is generous. The failures were uncompressed multi-MB
  transfers over a ~25–70 KB/s channel, plus one hollow-cache bug.
- Still at scale risk (out of this task's init scope, flagged for
  the coordinator): per-turn `choose`/`apply` (15 s driver timeout)
  and `validate` (60 s) ship state over the same channel. Framing
  cuts those transfers ~3–6× and the deferred-init flush adds one
  framed init (~460 KB) to the first validate only, but no
  game-scale turn was rehearsed here. Recommend a one-turn
  rehearsal at the test-001 snapshot before resuming the game.
- Under heavy third-party hub load, SSH banner exchange itself
  timed out twice during this audit (r, lua pre-fix attempts) —
  a channel property, not an adapter property.
- games/test-001 and games/smoke-001 untouched (md5 identical to
  the pre-audit snapshots: test-001 `15e28196…`, smoke-001
  `5166f0dc…`). No game started or resumed. All serve processes
  spawned by this audit were closed.

## Top-up audit — awk/bash/fsharp/tcl (2026-11-24 ~12:33 CST +, in progress)

The final registry sweep above wrongly reported these four as
unregistered: all four have `ports/<slug>/registration.json` with
status `playing`. They were built after the wave-1a four but before
the game-scale fix, so this audit checks them against the same three
known defects.

### Static defect check (source reading, local == hub md5 for every src file)

| adapter | state_path→base64 translation | hub init + driver-form validate | GZ1 framing | deferred init cache |
|---|---|---|---|---|
| awk | present (adapter translate_request) | present (telephone.awk init + do_validate driver form) | **absent both sides** | **absent** |
| bash | present | present (telephone.sh) | **absent both sides** | **absent** |
| fsharp | present | present (Program.fs) | **absent both sides** | **absent** |
| tcl | present | present (telephone.tcl) | **absent both sides** | **absent** |

So no hollow-init class bug here (their wave brief required
translation + init); the missing pieces are exactly the two
game-scale fixes that postdate their build: GZ1 framing and the
deferred init cache.

### Pre-fix timed serve init, 1,000-placement snapshot (driver timeout 30 s)

Snapshot copy `~/workspace/scale-audit-scratch/test-001-snapshot.phext`
(2,236,326 B, md5 `15e28196…`, byte-identical to games/test-001).
Hub load average ~3.0–3.4 during the sweep (wave-3 toolchain
installs running concurrently — realistic load, recorded not avoided).

| adapter | pre-fix init | vs 30 s |
|---|---|---|
| awk | 34.97 s pass | exceeds |
| bash | 79.67 s pass | exceeds (2.7×) |
| fsharp | 34.82 s pass | exceeds |
| tcl | 42.10 s pass | exceeds |

All four are the channel-bound class (raw ~3 MB base64 line over
fleet-ssh), none hollow. Fix: same kit as the 12 — GZ1 framing in
adapter + hub CLI serve loops, deferred init cache in the adapter.

### Fix as built (all four; same kit as the 12)

1. **GZ1 wire framing**: local adapter `serve()` + hub CLI serve
   loop. Native/system gzip per port: awk shells to base64(1)/gzip(1)
   on temp files (gawk has no gzip; mirrors lua/fortran), bash uses
   base64/gzip in the serve loop, tcl shells to base64(1)/gzip(1) on
   temp files, fsharp uses `System.IO.Compression.GZipStream`
   (mirrors vb). One-shot mode and selftests unaffected.
2. **Deferred init cache** in the local adapter `serve()`: init
   caches the exact state bytes locally and replies at once; the
   bytes flush to the hub CLI as a framed real `init` immediately
   before the first `validate`. Attest armored→base64 translation
   (already in these adapters' one-shot path) preserved in serve.
3. Hub copies md5 == local after sync: telephone.awk `06141c36…`,
   telephone.sh `4872dd2b…`, telephone.tcl `1b152392…`,
   Program.fs `1b12d877…`. F# rebuilt on the hub:
   `telephone-fsharp/bin/Telephone.dll` (51,712 B, dotnet build
   -c Release, 0 errors).

### Regression (per adapter, all four)

- Serve init on the 1,000-placement snapshot: awk 0.06 s, bash
  0.06 s, fsharp 0.06 s, tcl 0.09 s — all well within the 30 s
  driver timeout (pre-fix 34.97 / 79.67 / 34.82 / 42.10 s).
- Full driver-form serve audit on the smoke snapshot: **8/8 PASS
  for all four**, verify pass/30 in every case (validate passing
  proves the deferred caches materialize correctly — including
  bash, whose hub-side explode of the smoke state is fast; the
  game-scale load question for bash is answered by the Part B
  rehearsal below, not by init).
- One-shot `adapter verify games/smoke-001/stress.phext`:
  PASS / 30 placements for all four.

**Part A verdict: awk, bash, fsharp, tcl all conformant at game
scale for init; all 18 registered adapters (reference, py + 16 hub
ports) now carry the framing + deferred-init fix.**

## Part B — one-turn rehearsal at game scale (2026-11-24 ~12:40–14:20 CST)

**Coverage statement (read first):** this rehearsal ran with the
registry as it stood when the sweep started — **18 adapters:
reference, py, and 16 hub ports (awk, bash, dart, fortran, fsharp,
go, julia, lua, nim, ocaml, perl, php, r, ruby, tcl, vb)**. Wave 3
completed during the run and registered 8 more `playing` ports
(delphi, cobol, ada, objc, prolog, d, lisp, scala; 24 hub ports
total); they were **not** in this rehearsal. A wave-3 top-up leg is
the coordinator's call.

Method: `scale-audit-scratch/rehearsal.py` mirrors `cmd_play`
exactly — all 18 serves spawned at once, init (30 s), one echo
round, holder `elect` (15 s), elect's choose+apply+attest (15 s),
driver inscription (index line + hash-chained event via the
reference implementation), validate by every adapter (60 s),
against a scratch copy of the test-001 snapshot
(`rehearsal-state.phext`; games/ never written — test-001 md5
`15e28196…` and smoke-001 `5166f0dc…` re-verified identical at the
end). Turn 1001; holder for the elect = awk (alphabetically first
hub port). Hub contention: wave-3 toolchain installs running
concurrently throughout; hub load average 3.83 / 3.58 / 3.16 at
spawn time — recorded, not waited out.

### Per-step latencies (seconds; driver timeout in brackets)

| adapter | init [30] | echo [30] | validate [60] |
|---|---|---|---|
| reference | 0.36 | 0.00 | 0.38 pass |
| py | 0.44 | 0.00 | 0.37 pass |
| awk | 0.47 | 6.82 | 19.72 pass |
| bash | 0.11 | 0.17 | **timeout** → 107.06 pass solo (see below) |
| dart | 0.10 | 0.00 | 27.74 pass |
| fortran | 0.03 | 0.22 | 11.23 pass |
| fsharp | 0.07 | 1.46 | 43.82 pass |
| go | 0.02 | 0.54 | 16.54 pass |
| julia | 0.02 | 0.00 | 29.80 pass |
| lua | 0.02 | **serve died** | 16.73 pass (correct leg, see below) |
| nim | 0.02 | 0.37 | 15.49 pass |
| ocaml | 0.02 | 0.16 | 11.09 pass |
| perl | 0.01 | **serve died** | 17.79 pass (correct leg, see below) |
| php | 0.03 | 0.49 | 13.10 pass |
| r | 0.02 | 0.00 | **timeout** → fixed in-port → 10.91 pass (see below) |
| ruby | 0.02 | 0.00 | 45.36 pass |
| tcl | 0.02 | 1.02 | 36.68 pass |
| vb | 0.02 | 0.60 | 6.10 pass |

Turn steps: elect (holder awk) → **py** in 0.64 s [15]; py choose
0.36 s (insert at 899.234.748/1031.60.101/745.871.1265), apply
0.44 s (hash match), attest 0.02 s — trio total 0.83 s against the
driver's 15 s combined window. Driver check clean (exactly one
scroll added, nothing overwritten, canonical serialization).
Post-turn snapshot: 2,238,632 B, 1,001 placements.

Post-turn one-shot verify (driver `cmd_verify` form): **awk
(holder) PASS / 1001 in 38.3 s; reference PASS / 1001 in 21.6 s;
py PASS / 1001 in 20.8 s.**

### Breaches and dispositions

1. **Echo deaths (lua, perl) — channel, not adapters.** Both serve
   processes died between init and echo. Solo re-runs: echo fine
   (lua 4.40 s, perl 2.81 s). A concurrency probe (18 simultaneous
   spawns, stderr captured) reproduced the class with different
   victims (lua, php): `Connection timed out during banner
   exchange` — the fleet-ssh/egress-proxy channel under 18-way
   concurrent connect, the same channel property noted in the
   first audit. Wrapper ports surface it at first hub call because
   their init is deferred/local. Not fixable in-port; flagged for
   the coordinator (in a real game this kills the run at the first
   echo round; spawn staggering or connect retry would be a
   harness/driver matter — the driver was not touched).
2. **perl validate "fail" in the rehearsal table was a rehearsal
   artifact**: my respawn leg re-init'd the replacement serve with
   the *post-turn* file, so perl's cache legitimately already
   contained the placement ("coordinate was not unused in the
   prior state" is the correct verdict against that cache).
   Correct leg (fresh serve, init on the pre-turn snapshot):
   **17.79 s pass**. lua's correct leg likewise: **16.73 s pass**.
3. **bash validate — intrinsic breach, reported plainly.** Timed
   out at 60 s in the rehearsal; solo correct leg completes in
   **107.06 s with verdict pass**. The framing + deferred-init kit
   is in (bash init: 0.06–0.11 s); the remaining cost is two
   hub-side explodes of the 2.2 MB state in pure bash (deferred
   flush + validate). Not a framing/translation/deferred defect
   and not fixable within that kit: **bash validate does not meet
   the driver's 60 s timeout at game scale** — in a real game the
   driver's validate call to bash would time out on turn 1001.
   Bash is not marked passing for game-scale validate.
4. **r validate — root-caused and fixed in-port.** Timed out at
   60 s in the rehearsal and at 600 s solo. Bisected on the hub:
   one-shot (unframed) explode = 30.8 s; serve-mode explode =
   607 s at 100 % CPU hub-local. The gap was two O(n²) loops in
   r's own code: `text_to_raw` (phext.R) accumulates a raw vector
   codepoint-by-codepoint with `c()` — ~560 s on the 1.3 MB reply,
   sitting inside the framing expression (which is why the first
   bisect blamed `memCompress`); and `.jstr_escape` (cli.R) loops
   per codepoint — 28.5 s per explode reply in `jwrite`. Fixes,
   all in r's own source, hub md5 == local (cli.R `c228cf87…`,
   phext.R `3c60beed…`): framing now shells to system gzip(1) via
   a `gz_frame` helper (as lua/fortran/awk/tcl); `text_to_raw`
   vectorized with identical semantics; `.jstr_escape` gained a
   vectorized path for canonical = FALSE only (the canonical path
   used by `canon()` on attest/event structures is untouched).
   Differential test: old vs new byte-identical over 6,021 corpus
   strings (every key, value, and raw scroll text of the
   1,000-placement map + edge cases) — 0 mismatches. Post-fix hub
   numbers: explode dispatch 0.52 s, jwrite 0.17 s, gz_frame
   0.04 s. Re-run legs: **validate 10.91 s pass**; smoke serve
   audit **8/8 PASS** (r's adapter has no one-shot verify mode;
   serve verify pass/30 covers it, as for the other subclass
   ports).

### Part B verdict

One full turn at game scale works end to end: all 18 inits within
0.5 s, election/choose/apply/attest in 0.83 s combined, driver
check clean, post-turn verify PASS/1001 by three independent
adapters. Validate passes within the 60 s driver timeout for
17 of 18 adapters under realistic hub contention. Two flags for
the coordinator before resuming test-001: **(a) bash validate is
intrinsically ~107 s at this scale and will breach the 60 s
driver timeout in a real game; (b) 18-way simultaneous serve
spawn can lose 1–2 SSH connections to banner-exchange timeouts**
(channel property, victims vary per run). Wave-3's 8 new ports
were not rehearsed (see coverage statement).

No game was started or resumed. games/ untouched (md5s above).
All serve processes spawned by this audit were closed; nothing
belonging to other workers was killed (one stale Rscript from my
own hub-local timing probe was confirmed already exited).

## Bash validate at game scale — fixed in-port (2026-11-24 ~14:11–15:10 CST, EE ~528–542)

Follow-up to Part B breach 3 (bash validate 107.06 s solo vs the
60 s driver timeout). Verdict: **fixed, honestly, in the port's
own source** — bash validate now passes at game scale in 10.15 s
solo. Only `ports/bash/src/phext.sh` changed (hub copy md5 ==
local `618ed30affcfa2c59dd24225d48f12a7`); `telephone.sh`,
`json.sh`, and the adapter are untouched, and `telephone.sh`'s
validate logic is byte-identical to before — every check
(placed scroll present with step text, prior scrolls byte-intact
except the mutable index, no unexpected new scrolls, index line
recorded) runs exactly as before over the same explode maps.

### Profile (where the 107 s went)

Per-phase timing of one explode of the 2,236,326 B snapshot
(local VM, shared CPU; hub baseline explode measured separately
at 44.80 s, so two hub explodes ≈ the 107 s validate):

- The state holds **1,296,097 break bytes** for 2,004 scrolls
  (dim8 439,715 · dim7 328,575 · dim6 239,145 · dim3 168,475 ·
  dim2 80,584 · …): canonical serialization emits long break
  runs to reach large coordinates.
- Sentinel-escape encoding (9 whole-string `${var//pat/rep}`
  passes): **~67 s**. Cost is per-replacement × whole-string
  (dim8 pass alone 15.2 s; dim0, 898 replacements, 0.09 s).
- Walker loop over the 1,296,097 split parts: **~38 s** (per-part
  function calls `_apply_break`/`_walker_str`, array indexing,
  substring copies). Loop+case floor alone measured 9.6 s.
- Everything else (coord_str, assoc copies, comparisons,
  JSON/base64 handling): ~1 s combined. Not the problem.

### Fix (all inside `phokenize`/`_encode_breaks` in phext.sh)

1. **Chunked encoding**: the sentinel-escape substitutions run
   in 16 KB chunks joined in one expansion (the idiom
   `dephokenize` already used). All patterns are single bytes, so
   no match can straddle a chunk boundary; output byte-identical.
   67 s → ~1.9 s.
2. **Run-length break tokens**: when the data contains **no
   literal 0x02 byte**, extra chunked passes collapse runs of
   ten consecutive break markers into single token markers
   (a–i = ×10, j–r = ×100, A–I = ×1000, letter offset =
   dimension), cutting ~1.3 M walker parts to tens of thousands.
   The 0x02 guard is load-bearing: with a literal 0x02 in scroll
   text, an escape pair followed by digit text could masquerade
   as a marker run, so for such data the tiers stay off and the
   original encoding is used unchanged. A tier pattern straddling
   a chunk boundary merely fails to collapse there — the
   uncollapsed markers remain valid single breaks.
3. **Scalar walker**: coordinate components live in scalars
   w1..w9; pure-break parts apply via unrolled `case` arms
   (increment + resets inline, no function calls, no array
   indexing, no substring copies). Text-bearing parts decode
   digit/token markers through the same arms.

Hub explode of the snapshot: **44.80 s → 1.48 s** (map hash and
implode hash identical before/after on the hub itself).

### Correctness gate (differential, old vs new implementation)

- Explode maps compared per scroll (coordinate → sha256 of
  text): **identical** on smoke-001 (65 scrolls) and the
  test-001 snapshot (2,004 scrolls); implodes byte-identical;
  rehearsal-state implode sha256 still `fb7faab3…` (the recorded
  post-turn hash).
- 16 synthetic edge cases (literal 0x02 in text, 0x02+digit
  traps, alternating break dimensions, 5,000-long break runs,
  0x03 in text, leading/trailing breaks, empty input/scrolls):
  maps + implodes identical, all 16.
- Validate responses old vs new, byte-identical in every case
  run: wire-form pass ("placed at unused coordinate; all prior
  scrolls intact"), wire-form prior-scroll-overwritten fail,
  placed-scroll-tampered fail, count-mismatch fail, and the
  game-scale wire case. Driver-form game-scale verdict: pass
  (solo leg below), matching the old code's 107.06 s pass on the
  same pre/post-turn pair.
- Native suite on the hub (`tests/run_tests.sh`): **PASS**,
  fixtures 16/16 round-trip.
- Smoke serve audit (driver-form battery): **8/8 PASS**;
  one-shot `adapter verify` on smoke-001: **PASS/30**.

### Success measurement

Solo correct leg through the real adapter + fleet-ssh + hub
(fresh serve, init on the pre-turn snapshot, validate on the
rehearsal post-turn state, turn 1001 step/event/index line):
init 0.06 s, **validate 10.15 s, verdict pass** — inside the
60 s driver timeout with ~6× margin (was 107.06 s). The residual
10 s is two hub explodes (~1.5 s each), two 3 MB JSON parses,
base64/GZ1 channel transfers — no single dominant term left.
Bash is no longer scale-limited for validate. (The Part B flag
(b), SSH banner-exchange timeouts under 18-way concurrent spawn,
is a channel property and remains open for the coordinator.)

No game was started or resumed. games/ untouched (test-001 md5
`15e28196…`, smoke-001 `5166f0dc…`, re-verified after all runs).
Scratch + profiling/differential scripts kept at
`~/workspace/bash-validate-opt/`. Hub scratch files created by
this task were removed; all serve processes spawned were closed;
nothing belonging to other workers was killed.

## Part A — driver spawn hardening (2026-11-24 ~13:55–14:05 CST, EE ~531–533)

Fix for Part B flag (b) above, in `harness/telephone.py` **only**,
transport behavior only:

- `spawn_serves(players)` replaces the dict-comprehension mass spawn
  in `cmd_new` and `cmd_play` (incl. the final `end_test` spawn):
  serves are started one at a time, staggered by
  `SPAWN_STAGGER_S = 0.25` s between launches.
- `init_serve(serves, entry, state_path)` replaces the bare init
  calls in `cmd_new`/`cmd_play`: on a **transport** failure only —
  the serve process died, the call timed out, or no first response
  arrived (the banner-exchange class) — the serve is closed,
  respawned, and init retried, up to `INIT_ATTEMPTS = 3` with
  backoff `INIT_BACKOFF_S = 2.0` s × attempt. An error verdict from
  a live serve is a genuine adapter answer and propagates
  immediately, unretried. After the 3rd attempt the last failure is
  re-raised, so a genuinely dead adapter still fails loudly, naming
  its id (`TimeoutError: <id> did not respond` / the death error).
- `cmd_verify`'s spawns are sequential one-at-a-time already; left
  as-is. **No game semantics touched**: draw, seek, echo timing
  (5 s), elect window (15 s), move legality, failure definition,
  consensus and certificate logic unchanged; no timeout values
  changed (init 30 s default, validate 60 s, verify 3600 s verified
  in the diff). The only edited file is `harness/telephone.py`.

### Proof — two consecutive full 26-serve spawns through the driver path

`scale-audit-scratch/spawn_proof.py` imports the driver itself and
uses `spawn_serves` + `init_serve` (the exact helpers `cmd_play`
now calls) against a fresh snapshot copy of
`games/test-001/stress.phext` (`spawn-proof-state.phext`, md5
`15e28196…` == the game file; games/ read-only, never written).
Registry at proof time: **26 playing** (reference + py local, 24 hub
via SSH). Spawn wall time 6.79 s / 6.57 s (the stagger).

Per-adapter init latency, seconds (driver timeout 30 s):

| adapter | run 1 | run 2 | | adapter | run 1 | run 2 |
|---|---|---|---|---|---|---|
| ada | 8.85 | 22.10 | | nim | 0.02 | 0.02 |
| awk | 0.04 | 0.02 | | objc | 5.41 | 3.05 |
| bash | 0.03 | 0.02 | | ocaml | 0.06 | 0.02 |
| cobol | 4.24 | 6.24 | | perl | 0.06 | 0.02 |
| d | 4.89 | 13.55 | | php | 0.04 | 0.02 |
| dart | 0.02 | 0.02 | | prolog | 17.73 | 13.53 |
| delphi | 9.59 | 16.60 | | py | 0.55 | 0.51 |
| fortran | 0.02 | 0.02 | | r | 0.02 | 0.04 |
| fsharp | 0.04 | 0.02 | | reference | 0.62 | 0.44 |
| go | 0.03 | 0.02 | | ruby | 0.05 | 0.02 |
| julia | 0.07 | 0.09 | | scala | 19.26 | 12.69 |
| lisp | 10.52 | 12.63 | | tcl | 0.03 | 0.03 |
| lua | 0.02 | 0.07 | | vb | 0.02 | 0.04 |

**Both runs: all 26 init `pass`, within the 30 s timeout, no serve
lost.** Honest notes:

- Run 2's stderr shows one real `Connection timed out during banner
  exchange` — the defect class occurred live during the proof and
  no init failed: the affected leg recovered inside its init call
  (adapter-internal SSH respawn and/or the new driver retry; the
  layers cannot be attributed from outside, and ada's 22.10 s —
  the slowest run-2 init — is consistent with a ~20 s connect
  timeout absorbed and retried). Zero deaths is the outcome; the
  channel still produces the failure, the spawn path now survives
  it.
- The eight wave-3 ports are the slow inits (3–22 s): unlike the
  wave-1/2 wrapper ports they do not defer init — their
  adapter_base init ships and loads the full state inside the
  init call. All within budget in both runs, but scala (19.26 s)
  and prolog (17.73 s) sat at ~60 % of the 30 s budget uncontended-
  by-installs; under heavier hub load they are the inits to watch.
  The bounded retry covers a timeout death by respawn; it does not
  make a slow-but-live init faster, and is not claimed to.

## Part B top-up — wave-3 validator rehearsal (2026-11-24 ~14:11–14:20 CST, EE ~534–535)

The eight wave-3 ports registered after the first rehearsal —
**delphi, cobol, ada, objc, prolog, d, lisp, scala** — rehearsed as
validators by the first rehearsal's post-turn snapshot method
(`scale-audit-scratch/wave3_validate.py`): the post-turn file is
the first rehearsal's own `rehearsal-state.phext` (turn 1001,
placement by py at 899.234.748/1031.60.101/745.871.1265, event
1.1.1/1.1.1/2.1.1002; step/event_coord/index_line re-derived from
the pre/post files and matching the rehearsal record). Per
adapter: fresh serve, init on the **pre-turn** snapshot copy
(`test-001-snapshot.phext`, cache = prior state — the "correct
leg" method), then `validate` of the post-turn state over serve,
driver validate timeout 60 s, solo per adapter.

| adapter | init [30 s] | validate [60 s] | verdict |
|---|---|---|---|
| delphi | 19.26 pass | 17.28 | **pass** |
| cobol | 8.00 pass | 6.06 | **pass** |
| ada | 18.38 pass | 13.73 | **pass** |
| objc | 8.41 pass | 3.88 | **pass** |
| prolog | 11.41 pass | 12.10 | **pass** |
| d | 9.86 pass | 4.64 | **pass** |
| lisp | 10.26 pass | 6.99 | **pass** |
| scala | 10.77 pass | 6.06 | **pass** |

**All eight wave-3 adapters validate the game-scale post-turn
state with verdict `pass`, worst latency 17.28 s (delphi) — 29 %
of the 60 s driver timeout. No breaches, no in-port fixes needed**
(their GZ framing carried the state transfer as expected). With
this top-up, validator rehearsal coverage is all 26 registered
adapters: the 18 of the first rehearsal plus wave 3's eight.
Remaining pre-resume flags from the first rehearsal stand
unchanged: **bash validate is intrinsically ~107 s at game scale
and will breach the 60 s driver timeout in a real game** (Part A
above closes the spawn/banner flag).

No game was started or resumed. games/ untouched (test-001 md5
`15e28196…`, smoke-001 `5166f0dc…`, re-verified at the end). All
serve processes spawned by these runs were closed; nothing
belonging to other workers was killed.

## Part A round 2 — driver per-turn transport retry (2026-11-24 ~17:41–17:48 CST, EE ~564–565)

Fix for test-001's third death (`games/test-001/play.log`: traceback
at `harness/telephone.py` line 482 in `cmd_play` → `TimeoutError:
delphi did not respond`, during the per-turn **validate** leg under
live hub contention; delphi's solo validate is 17.28 s against the
60 s timeout). Round 1 covered init only; the per-turn calls were
fail-on-first-timeout. Transport behavior only, in
`harness/telephone.py` only:

- **Call map (cmd_play, pre-edit line numbers)**: echo — list
  comprehension over all players, `Serve.call` default timeout
  (30 s; the 5 s in the rules is the echo *interval*); elect —
  holder serve, 15 s; choose / apply / attest — elect serve, 15 s
  each, inside the 15 s elect-response window; validate — every
  player, 60 s (the line-482 call). Line 482 confirmed as validate.
- **`call_with_retry(serves, entry, state_path, req, timeout)`** now
  wraps the **validate** and **echo** calls only. On a transport
  failure ONLY — `TimeoutError`, broken pipe / connection error /
  EOF / `OSError`, or a `RuntimeError` where the serve process has
  exited / reports "adapter died" (`_is_transport`) — the serve is
  closed, respawned, re-inited with the CURRENT game file via the
  round-1 `init_serve` helper, and the same call re-issued: up to
  `TURN_ATTEMPTS = 3` attempts total, backoff
  `TURN_BACKOFF_S = INIT_BACKOFF_S` (2.0 s × attempt, the init
  style). A returned verdict — pass OR fail — is never retried and
  propagates exactly as before; an error reply from a live serve
  also propagates unretried. Exhaustion re-raises the FIRST
  failure (fail-closed, resumable), naming the adapter.
- **Not covered, deliberately**: elect / choose / apply / attest
  stay fail-closed on first transport failure (code comment at the
  wrapper and at the mutation leg). choose/apply/attest are the
  holder-mutation leg and retry safety after an ambiguous
  transport death (request may or may not have been acted on) is
  not established. Finding, recorded without acting on it: from
  the driver + `adapter_base` reading, choose/apply *appear* to
  be pure functions of (prior state, chosen move) — choose reads
  state and returns a step, apply's only write is the
  driver-designated tmp out-path, and inscription (index + event
  + game file) is held entirely by the driver — so retry safety
  may be establishable later; per-adapter determinism of choose
  across all 44 ports was NOT audited here, and attest (signing)
  was not analysed. The retry was still not extended to them.
- **Hard limits held**: no timeout changed (init/call default
  30 s, echo 30 s — now explicit, same value — elect/choose/apply/
  attest 15 s, validate 60 s, verify 3600 s; verified in the final
  file); no game semantics touched (draw, legality, failure
  definition, consensus counting, certificates untouched); a
  consensus FAIL cannot be retried into anything else (fail
  verdicts return through the wrapper unretried — unit-proven
  below). One nuance, stated plainly: a retried validate re-inits
  the validator's cache with the current (post-turn) file, as
  specified — the original serve's pre-turn cache is unrecoverable
  once it dies, and the driver's own local prior-scroll check
  (exactly-one-scroll-added, nothing overwritten, canonical
  serialisation) has already run before consensus in `cmd_play`.

### Proof

Scripts + logs in `~/workspace/scale-audit-scratch/round2/`.
Snapshot copies only; `games/` never written (test-001
`stress.phext` md5 `6fa31c1f…`, 2,260,772 B / 1,004 placements,
identical before and after all legs).

- **(a) Compile / dry paths**: `py_compile` OK; `--help`,
  `play --help`, and `registry` behave as before.
- **Unit leg** (`unit_wrapper.py`, local reference serve):
  tampered validate → verdict `fail` returned in exactly 1
  attempt; unknown-cmd error reply from a live serve →
  `RuntimeError` propagated in exactly 1 attempt; synthetic
  `TimeoutError` on echo → respawn + re-init + retry returned the
  echo (3 counted calls: echo, init, echo). **UNIT-PASS**.
- **(b) Chaos leg** (`chaos_delphi.py`, log `chaos3.log`): delphi
  serve spawned through the driver machinery (`spawn_serves` +
  `init_serve`, init pass in 16.89 s on the snapshot copy);
  driver-form validate for the file's own last turn (1004, by
  reference at 899.234.748/1032.60.102/745.871.1266, event
  1.1.1/1.1.1/2.1.1005) issued through `call_with_retry`; hub-side
  process (pid 211115, `/home/wbic16/telephone-delphi/cli serve`,
  pid-set differenced against a pre-spawn pgrep — no delphi hub
  processes existed before, none left after) killed with -9 as
  the validate went on the wire. First attempt died (local adapter
  `BrokenPipeError` writing to the dead hub CLI); the wrapper
  respawned (local pid 7983 → 8127), re-inited via `init_serve`
  call #2 on the snapshot, re-issued the validate, and completed
  with **verdict pass**; validate attempts = 2, total 26.48 s.
  **CHAOS-PASS**. Two earlier runs are recorded honestly in
  `chaos.log` / `chaos2.log`: the verdict beat the kill both times
  (attempt count stayed 1) because a fresh fleet-ssh leg takes
  ~9 s to connect under current hub load (load avg ~9–12) while
  delphi's validate completed in ~9–10 s; the passing run used a
  pre-opened fleet-ssh control shell to deliver the kill.
- **(c) Full-spawn proof** (`spawn_proof_r2.py`, log `spawn.log`):
  all currently-registered playing serves — **44** (registry has
  grown since round 1's 26) — spawned through `spawn_serves`
  (11.13 s) and init'd via `init_serve` against a fresh snapshot
  copy: **44/44 init `pass`**, worst delphi 13.07 s, prolog
  13.73 s, scala 7.69 s, spark 9.00 s, ada 10.02 s — all inside
  the 30 s timeout. No regression.

No game was started or resumed. All serves spawned by these runs
were closed; the only hub process killed was the chaos leg's own
delphi serve (pid 211115). `~/telephone-game-repo` and
`~/telephone-game-verify` untouched; no sudo, no GitHub.

## CFML validate at game scale — fixed in-port (2026-11-24 ~19:26–20:05 CST, EE ~577–583)

Fix for test-001's fourth death (`games/test-001/play.log`: the
round-2 retry wrapper exhausted all 3 attempts on cfml validate,
`TimeoutError: cfml did not respond`, fail-closed, file intact at
turn ~1005). CFML's solo validate was 40.50 s — 68 % of the 60 s
budget before contention. All work confined to `ports/cfml/` +
`~/telephone-cfml/`; `games/` never written (test-001 md5
`a2a648a7…`, smoke-001 `5166f0dc…`, identical before and after).

### Profile — where the ~40 s went (solo, hub, snapshot copy of
the current `games/test-001/stress.phext`: 2,265,624 B, 2,014
scrolls, 1,005 placements, turn/event-seq derived by
`scale-test-live.py`)

Per-phase, inside one CommandBox run (`ports/cfml/perf-scratch/
profile.cfm`, getTickCount deltas; wall 18.91 s for the run):

| phase | ms |
|---|---|
| CommandBox/JVM boot + CFM compile (wall − in-process) | ~8,100 |
| `phextExplode(prior)` | 5,408 |
| `phextExplode(placed)` | 5,257 |
| base64 decode ×2 + cache file reads | ~80 |
| JSON parse of the 3 MB request | 25 |
| validate comparison loops (2,014 scrolls) | 8 |

Two structural facts: (1) serve validate made **two** hub calls
(deferred-init flush + validate), each paying the ~8 s boot;
(2) the snapshot is **1,302,022 break bytes in 2,265,624** — text
is only 963,602 B — so `phokenize`'s per-byte CFML walk
(`mid()`/`asc()` per byte, 2.27 M iterations per explode) was
99 % of in-process time. Everything else (JSON, base64, the
comparisons themselves) is noise. A first `find()`-per-segment
prototype was *slower* (7.0–7.7 s: rare break chars make each
`find()` scan to end-of-buffer per segment); a per-break regex
Matcher would still iterate 1.30 M times.

### Fixes (in-port only; validate semantics untouched)

- **`phext.cfm` — bulk `phokenize`.** A Java regex Matcher scans
  maximal *text* runs only (2,014 iterations); the break run
  before each run is collapsed arithmetically by
  `coordApplyBreakRun`: a break at dim *k* resets dims > *k*, so
  per dim *d* the run's effect is `coord[d] + count(d)` or, when
  a lower-dim break exists, `1 + count(d after the last
  lower-dim break)` — counts from Java `lastIndexOf` and a
  replace-all length difference. (Lucee pitfall found by brute
  force: member `.replace()` is CFML `replace()` with default
  scope **"one"**, not Java replace-all; the `"all"` scope
  argument is load-bearing.) Explode 5,408 → ~200 ms.
- **`phext.cfm` — merge sort** replaces the O(n²) insertion
  `scrollSort`: implode 3,191 → ~700 ms (choose/apply path).
- **`src/daemon.cfm` + `hub/run-cli.sh` — warm Lucee context.**
  A long-lived CommandBox process on the hub serves request
  files from `cache/queue` one at a time; run-cli.sh queues the
  request and waits, and **falls back to the original one-shot
  box run** whenever the daemon cannot be started or does not
  answer (cold-boot wait 120 s; a live pid with a stale
  heartbeat is treated as busy, never killed). The daemon
  caches no verdicts, re-reads the on-disk init cache on every
  validate, heartbeats at request start and while idle, and
  exits when the port sources' hash changes. `cli.cfm`'s main
  was factored into `processRequestFile()` (guarded entry) so
  the daemon can include it; dispatch is byte-identical.
- **`adapter` — GZ1 send + asynchronous init flush.** `wire()`
  GZ1-frames requests over 8 KB (game-scale request 3.02 MB →
  ~0.60 MB on the wire; run-cli.sh already decoded GZ1). Serve
  init still replies at once, but the flush to the hub now runs
  on a background thread started at init; validate **joins**
  the flush (re-flushing synchronously on failure) before its
  own call, so the hub cache provably holds the prior state
  before any comparison — only the flush timing moved.

### Correctness gate

- **Differential old vs new** (hub-local; old = reconstructed
  pre-pass `phext.cfm` one-shot, new = daemon path; snapshot
  copy): verdicts **and fail details identical** on pass,
  placed-tampered ("placed scroll missing or altered"),
  prior-overwritten ("prior scroll overwritten at
  1.1.1/1.1.1/1.1.2"), unexpected-scroll ("unexpected new
  scroll at 9.9.9/9.9.9/9.9.9"), index-mismatch ("index does
  not record the placement"). Old 28.0–28.4 s vs new 1.1 s per
  init+validate pair. Explode equivalence additionally proven
  on the snapshot and 60 randomized buffers before landing.
- **Native suite**: 80 checks, 0 failures; fixtures 16/16
  byte-identical + 16/16 normalize-idempotent.
- **Adapter self-test**: PASS (incl. validate pass and
  validate-fail-on-overwritten-prior over serve).
- **One-shot verify** vs `games/smoke-001/stress.phext`:
  PASS/30 verbatim, 3.8 s.

### Timings after (scale-test-live.py, snapshot copy, solo)

| leg | before (wave 5b) | intermediate (lib fix only) | final |
|---|---|---|---|
| init (deferred) | 0.06 s | 0.08 s | 0.10 s |
| choose | — | 20.42 s (GZ1+async: 70.26 s pre-GZ1 run) | 7.41 s |
| apply | — | 23.21 s | 13.64 s |
| **validate** | **40.50 s** | 45.97 s (boots+transfers dominant) | **11.85 s** (second run 20.63 s) |

**Success criterion met: serve validate pass in ≤ 30 s solo**
(two runs, 11.85 / 20.63 s — the scale-test number is the
pessimistic bound, since it joins the re-init flush inside
validate; in a live game the flush lands at spawn). Remaining
validate cost is SSH connect + ~0.6 MB GZ1 transfer per call
under hub load (load avg ~8 during measurement), not hub CPU:
in-daemon processing is ~1 s. Honest residuals: a *cold*
daemon restart (daemon killed/stopped, or first call after a
source sync) costs one JVM/Lucee boot — measured 11.8 s once,
and once ~112 s when the old 40 s ensure-wait fell back to a
competing one-shot boot (the pathology the 120 s wait + busy
pid check now remove); the daemon otherwise persists on the
hub across games. Hub copies of all port files verified
md5-identical to `ports/cfml/`.

No game was started or resumed. All hub scratch from this pass
(profilers, oldsrc differential tree, snapshot b64s) was
removed from `~/telephone-cfml/`; the warm daemon (pid 1324078
at record time) was left running. `~/telephone-game-repo` and
`~/telephone-game-verify` untouched; no sudo, no GitHub.
