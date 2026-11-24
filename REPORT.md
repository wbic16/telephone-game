# Exocortical Stress Testing — program report

**Exocortical Stress Testing** is the discipline (Will, 2026-11-24: "let's
call this exocortical stress testing"). Its instrument for libphext interop
is the **Exocortical Telephone Game**. This report is updated per wave.

- The rule: [RULE.md](sandbox://workspace/libphext-telephone/RULE.md) —
  instituted 2026-11-24, governing all libphext updates across all
  languages from 2026-11-24 forward, including the in-flight v0.7.0
  program's landing.
- Adapter contract: `harness/ADAPTER-CONTRACT.md`. Driver:
  `harness/telephone.py`. Registry: `harness/registry.json` merged with
  `ports/*/registration.json`.
- Public store (Will, 2026-11-24 11:47 CST): **wbic16/telephone-game** on
  GitHub — this tree, pushed via git-over-SSH from aletheia-core. Never
  pushed: `harness/keys/` (PGP **private** keys live there; public keys
  are already inscribed in the game files' keys scrolls), `__pycache__`,
  `harness/reconcile-scratch/`, per-game `tmp/`, and game-001's `states/`
  snapshots (182 MB of near-identical full-corpus copies from the
  superseded v1 game; its transcript and genesis are stored).

## Design status — all 8 gaps RULED by Will (2026-11-24 10:37 CST)

The 8 design gaps (the draw, legal moves, failure definition, echolocation
collisions/silence, game end/success, state under the position, 999^9
edges, identity/immutability) are **closed**. RULE.md carries the rulings
verbatim and the harness was rebuilt to match exactly:

- **Draw** = race to find the Test of Will in CYOA by raw file I/O only
  (found at 13.13.13/13.13.13/13.13.13 in choose-your-own-adventure.phext;
  seekers must still find it by reading; the driver verifies by raw read).
- **Legal move** = inserting content at an unused coordinate only; the
  game is tracked in **stress.phext**.
- **Failure** = overwriting an immutable scroll from the prior step,
  tracked by consensus (every node self-validates the file at each step).
- **Echolocation** = echoes on 5-second intervals spanning current and
  next round; **popcorn election** — the prior winner chooses the next;
  an elect silent for 15 seconds ends the test with failure.
- **Success** = **10,000 scroll placements across the network** — the
  certificate unit the hold gates on.
- **State** = write-once placements; hashes of generated scrolls in the
  index at 1.1.1/1.1.1/1.1.1, the only mutable scroll.
- **Edges** = out-of-range coordinates tolerated (a toll gate, not a
  proof), never a failure.
- **Identity** = a PGP key per participant; public keys at
  1.1.1/1.1.1/1.1.2 at the start; that scroll's hash at 1.1.1/1.1.1/1.1.3;
  signed attestations for the scroll walk.

Harness v2: `harness/telephone.py` + `harness/adapter_base.py` (contract
v2 in `harness/ADAPTER-CONTRACT.md`). The v1 game (game-001, 12 scripted
turns) is superseded history — its certificate stands as a smoke artifact
of the pre-rulings design.

## Ruled-design smoke test — passed

**smoke-001** (target 30): draw won by the reference seeker; PGP keys
inscribed; popcorn elections alternated placements 15/15 between py and
reference; every step consensus-validated; the final walk verified all 30
placements **including every PGP attestation** — py verdict PASS.
Certificate HOLD, as designed (30 < 10,000 and other ports not playing):
[certs/smoke-001.md](sandbox://workspace/libphext-telephone/certs/smoke-001.md)

## Full test — STALLED at 1,000 placements; resume blocked on a serve gap

**test-001** (seed 20261124, target 10,000 placements) launched 2026-11-24
~10:45 CST with py + reference playing; log at `games/test-001/play.log`,
state in `games/test-001/stress.phext` (the file is ground truth; the
driver reconciles from it, so the run resumes after interruption by
re-running `play`). The walk reached **1,000 placements** (py 500 /
reference 499 per driver state, plus the in-flight step), then the driver
process died silently (~11:19 CST, no error in the log; cause unknown).
The file itself is intact — all four wave-1a adapters independently
verified a snapshot of it PASS at 1,000 placements (see wave 1a).
A resume attempt (~11:40 CST) crashed at startup: `cmd_play` sends
`{"cmd": "init", ...}` to **every registered adapter's** serve process,
and the Fortran adapter's serve loop did not implement `init`
("unknown cmd"). The serve-conformance pass that followed (record:
`harness/serve-conformance.md`) found the gap was deeper — see
"Serve-protocol conformance" below — and fixed it. **All 10 playing
adapters now pass the full serve audit; test-001 is cleared to resume.**
Note: the walk has drifted to a coordinate with a component of 1004 —
beyond 999, **tolerated** per ruling 7 (a toll gate, not a proof), and
not a failure. Its certificate issues when the walk completes or the
test ends. Until every port is playing, the certificate is a HOLD
regardless of the walk's outcome — which is the rule working.

## Wave 1a — COMPLETE: Go, PHP, Fortran, Perl all playing

Built in the program tree (`ports/<slug>/`), suites green, fixtures 16/16
byte-identical round-trips, adapters registered **playing** under
contract v2. Toolchains: Go 1.23.4 and gfortran 13.3 installed user-level
on the hub (no sudo); PHP 8.3.6 and Perl 5.38.2 already present; gpg
2.4.4 present on the hub. Cross-port evidence: a stress.phext built and
PGP-signed by the **Go** port was verified **pass** by the PHP, Perl, and
Fortran adapters — four independent canonical-JSON + phext stacks agreeing
on hashes and a signature.

- **Divergence verdict (recorded):** the in-progress ruby port's test
  expected `remove` to shift later scrolls down. Verified against
  libphext-py itself: remove is **coordinate-preserving** (the removed
  coordinate reads "", neighbours do not move). The ruby expectation is
  the wrong side; wave 1b has been told to fix it to the reference
  semantics.
- **Format reconciliation — COMPLETE** (record:
  `harness/reconcile-wave1a.md`): all four CLIs' verify paths speak the
  pinned formats; hub CLIs are md5-identical to local sources (9 files);
  the compiled Go/Fortran hub binaries were rebuilt after their sources.
  Battery, all verbatim PASS: smoke-001 verify **PASS / 30** from each of
  Go, PHP, Perl, Fortran; a snapshot of the live test-001 file (copied
  ~11:32 CST, 2,236,326 B) verified **PASS / 1000** from each of the four.
  No adjudication was needed — no port failed a driver-produced file.
  One gap the battery did not cover: the serve protocol (see Full test —
  the Fortran serve loop lacks `init`; a serve-conformance pass is now
  dispatched).

## Wave 1b — COMPLETE: R, Dart, Julia, Ruby all playing

Built in the program tree (`ports/<slug>/`), hub work in
`~/telephone-<slug>/` on aletheia-core. Suites green (Dart 44 checks,
Julia 39, Ruby 43, R 43); fixtures 16/16 byte-identical round-trips;
adapter self-tests PASS (18 checks each); **smoke-001 verify PASS / 30
from all four**. Toolchains, all user-level, no sudo: Dart SDK 3.14.1
(`~/tools/dart-sdk`), Julia 1.11.3 (`~/tools`), Ruby 4.0.10 and R 4.6.2
via micromamba/conda-forge envs in their hub dirs (the portable Ruby
tarball was not a valid gzip; conda-forge was the working path).

- **Ruby remove verdict — closed from both sides:** the ruby
  implementation was already coordinate-preserving, and its suite encodes
  the gap expectation and runs green against it. The reference semantics
  (libphext-py) govern; all wave-1 suites now encode the same
  expectation.
- All four adapters found the Test of Will by raw file I/O at offset
  980248, coordinate 13.13.13/13.13.13/13.13.13 (in-process seek — the
  shared base seeker is untenable over SSH; the walk logic is identical).

## Serve-protocol conformance — FIXED (all 10 playing adapters)

The one-shot `verify` batteries exercised only the CLI path. The serve
path — the one the driver actually plays over — had two defects in all
four wave-1a hub ports (Go, PHP, Perl, Fortran):

1. No hub CLI implemented `init` (all answered "unknown cmd").
2. The local wrapper relayed driver JSON verbatim, but the driver sends
   `state_path` (a local path) while the hub wire protocol speaks base64
   `state` — so serve-mode choose/apply ran against a **zero-byte
   state**, and validate/verify failed on the empty state.

Fixes, in each port's own source: the wrapper now translates at the
boundary (`state_path` → base64 `state`; apply writes the returned state
to `state_out_path`); each hub CLI gained `init` and a driver-form
`validate`. Local sources and hub CLIs are md5-identical; Go/Fortran
binaries rebuilt on the hub. Regression, all four fixed ports: one-shot
smoke-001 verify PASS / 30 **and** full serve audit 8/8 (init, echo,
elect, choose, apply hash-match, attest, validate, verify). The other
six playing adapters (reference, py, dart, julia, ruby, r) audited 8/8
with no changes. Lesson recorded: a port is not "playing" until it has
passed the **serve** audit, not just one-shot verify — wave-2 briefs now
carry the serve-init check, and full serve audit is the gate going
forward.

Known minor: the four wave-1a ports' `selftest_adapter.py` fixtures fail
one stale check (keys-hash computed over `pubkey.rstrip()` in the
fixture vs the pinned exact-inscription hashing). The verify code is
correct; the fixtures are stale. Fixture refresh is a separate small
task, not yet dispatched.

## Top 100

Snapshot + classification: **landed** — TOP100.md (all 100 enumerated,
none skipped). Counts: 9 existing ports; 1 covered by an existing port
(TypeScript #41 → node); 14 class (a) implementable now (toolchain present
on aletheia-core); 40 class (b) implementable, toolchain absent (user-level
install named per language); 36 class (c) HELD-FOR-WILL, each with a
one-line reason in TOP100.md. The 9 existing ports map to TIOBE November
2026 as: Python #1 (py), C #2 (c), Java #3 (java), C++ #4 (cpp), C# #5
(cs), JavaScript #6 (node), Rust #11 (rs), Swift #18 (swift), Kotlin #33
(kotlin).

Caveat (recorded in TOP100.md): ranks 1–50 are cross-verified across four
independent sources. The 51–100 band is PROVISIONAL — tiobe.com was
unreachable from this environment (two fetch attempts, both failed) and
the band was reconstructed from the most recent complete TIOBE band in
source data plus documented members, each flagged inline. Follow-up owed:
a direct TIOBE fetch by an agent with a working browser route to swap in
the true band; classifications are per-language and carry over.

## Port status

| Port | Status |
|---|---|
| py | playing — adapter local, in game-001, cross-check PASS |
| reference (verifier, not a port) | playing — in game-001, cross-check PASS |
| rs, cs, node, java, kotlin, swift | **blocked** — hub clones verified clean on emise/v070-perf (rs dfbd8072, cs 0e7dbb45, java 63343d85, kotlin 0f052694, swift d2600d7a, node 5bd5bab4), then the worker was stopped by an execution-risk security flag before building or running anything; adapters not written |
| cpp, C | registered, not playing; hub work overlaps the execution approval already before Will from v0.7.0 (not re-asked) |
| go, php, fortran, perl | **playing** — wave 1a complete; format reconciliation complete (smoke-001 PASS/30 ×4, test-001 snapshot PASS/1000 ×4); Fortran serve `init` gap found on test-001 resume — serve-conformance fix dispatched |
| r, dart, julia, ruby | **playing** — wave 1b complete (see below); smoke-001 verify PASS/30 ×4 |
| Wave 2 new ports: Visual Basic, Lua, OCaml, Nim, Awk, Bash, F#, Tcl | building — all class (a), toolchains census-verified present on the hub; adapters briefed on pinned formats + smoke-001 verify acceptance gate |
| Class (b) languages (40) | classified in TOP100.md with the user-level install each needs; waves proceed after class (a) is exhausted |
| Class (c) languages (36) | HELD-FOR-WILL in TOP100.md — Will decides; not trimmed, not skipped |

## Will-gated

- **Repo creation** for every new port (wbic16/libphext-<lang>) — ports are
  built to full readiness in the program tree; creating the GitHub repos is
  Will's step, per port.
- **Hub-execution approval** — already before Will from the v0.7.0 program
  (py/cpp/C). The same execution-risk flag has now also stopped the
  telephone-game adapter work for rs, cs, node, java, kotlin, swift (hub
  clones of Will's own wbic16 repos, verified clean, nothing built or run).
  One approval from Will — to build, test, and run these clones on
  aletheia-core — unblocks both programs. Not re-asked here; scope noted so
  the existing item carries it.
- **HELD-FOR-WILL languages** (classification class c — not library
  languages): listed in TOP100.md when the snapshot lands; Will decides,
  the list is not trimmed.
- ~~Design-gap rulings~~ — **closed**: Will ruled all 8 on 2026-11-24
  10:37 CST; the design above is built on them.

## Discipline

Branches only where repos already exist; no merges, no tags, no registry
publishes, no new GitHub repos. Workers stop at execution-risk flags and
report; nobody dispatches past a flag. Sudo needs are recorded as
blocked-for-Will, never attempted.
