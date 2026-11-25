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
  GitHub — this tree, pushed via git-over-SSH from aletheia-core.
  Landed: commit `226e58f99dac29af461da2b5ef74cd29df64c2a7` on branch
  `exo`, parented on the repo's initial commit `261e80a` (LICENSE only),
  no force; 279 files. Verified from a fresh clone: RULE.md and
  REPORT.md sha256 byte-identical to the local copies; private-key sweep
  of the pushed tree clean. (The local REPORT.md has advanced since that
  commit — the store is refreshed per wave.) Never
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

## Full test — RESUMED 2026-11-24 ~21:11 CST with the full registry (34 serves)

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
adapters passed the full serve audit at smoke scale; test-001's resume
then exposed a game-scale init timeout (dart) — see the addendum under
"Serve-protocol conformance" below. **All gates have since closed
(game-scale audit, full rehearsal, driver spawn hardening, bash
validate fix) and test-001 resumed ~21:11 CST with all 34 registered
serves: init passed across the registry and turn 1001 was inscribed
(stress.phext grew to 2,240,276 B at 21:12 CST; driver alive and
playing). Turns are now minutes-scale — each is validated by every
registered node, per the ruled design — so the remaining ~9,000
placements are a long background walk, resumable after any
interruption (the file remains ground truth). **The walk stalled again
at turn 1001 the same evening: `TimeoutError: erlang did not respond`.
Erlang had been registered "playing" by the wave-5a worker, which then
errored out mid-acceptance — its serve answered init but failed a
later call in turn 1002 (or its hub CLI was rebuilt mid-flight by the
dying worker). Lesson recorded as a standing program rule: a port
under active construction is never registered "playing", and games
resume only against a settled registry. A completion worker is
finishing wave 5a (erlang/elixir/forth/scheme) to the full serve-audit
standard; test-001 resumes when wave 5's registrations are final.**
Note: the walk has drifted to a coordinate with a component of 1004 —
beyond 999, **tolerated** per ruling 7 (a toll gate, not a proof), and
not a failure. Its certificate issues when the walk completes or the
test ends. Until every port is playing, the certificate is a HOLD
regardless of the walk's outcome — which is the rule working.

**Status at 2026-11-25 ~02:52 UTC (20:52 CST 2026-11-24)**: **49 ports
PLAYING** (authoritative registration sweep: 49 playing, 7 blocked —
rs, cs, node, java, kotlin, swift on Will's hub-execution approval and
solidity on its classification question — 1 scale-limited: csh).
Waves 1–5 complete; wave 6b complete (J, Modula-2, REXX); **wave 6a
complete**: Icon (#50) playing (validate 16.54 s), Algol 68 (#54)
playing (validate 40.47 s; ASCII-only file discipline — a68g transput
is not byte-safe), Io (#57) playing (validate 22.88 s), and **C shell
(#59) SCALE-LIMITED** — a functionally complete port (suite 47/0,
fixtures 16/16, smoke PASS/30) whose tcsh token-walk substrate runs
~1,300 tokens/s: game-scale validate ≈3,500 s vs the 60 s gate. The
port is correct; the substrate cannot carry game scale, and it is
registered honestly as such. **Mojo (#77) registered playing** during
wave 7 (Mojo 1.3.0 nightly via pixi, user-level); Smalltalk (#56) and
Hack (#85) still building. test-001: after the CFML performance pass
(validate 40.50 s → 11.85/20.63 s; see wave 5a section) the walk
resumed and advanced past turn ~1,020 (2,339,324 B); the hatch VM was
then replaced (boot 1ef9eedd → e95f151b, ~02:45 UTC) and the driver
died with it — game file intact, no corruption — and the walk resumed
on the new boot with 50 serves (49 playing + reference verifier) and
is advancing. The GitHub store (commit 226e58f) predates waves 5b–7
and refreshes when the wave program completes.

## Wave 7 — COMPLETE: Smalltalk, Mojo, Hack all playing (the wave program is complete)

- **Smalltalk (#56) playing**: Pharo 12, user-level on the hub; the CLI
  runs per invocation from the pristine image (images saved from a
  command-line session silently ignore later handlers in this build).
  Suite 35/0, fixtures 16/16, self-test PASS, smoke PASS/30; game-scale
  init 0.06–0.09 s, choose 8.32 s, apply 8.69–11.42 s, validate
  6.61–7.34 s — all inside the driver windows (a first run under heavy
  hub contention measured choose at 49.67 s; the immediate re-run is
  the steady state, recorded honestly).
- **Mojo (#77) playing**: Mojo 1.3.0.dev2026112405 via pixi 0.84.2,
  user-level; single compiled binary. Suite 53/0, fixtures 16/16,
  self-test PASS, smoke PASS/30; game-scale validate 6.48 s, apply
  15.53 s (just over the 15 s turn window — the ksh/J class). Root
  cause found en route: Mojo String→system() carries stale bytes past
  the logical end, intermittently corrupting subprocess commands;
  fixed with an explicitly NUL-terminated run_system(). (See the
  test-001 failure below — this history is directly relevant.)
- **Hack (#85) playing**: HHVM 4.172.1, user-level via dpkg -x of the
  official bullseye deb plus a 66-deb library closure in a user-level
  apt root and a patchelf'd binary — no sudo, zero libs resolving
  outside the prefix. Suite 38/0, fixtures 16/16, self-test PASS,
  smoke PASS/30; game-scale init 0.07 s, choose 5.89 s, apply 6.16 s,
  validate 7.78 s — **all inside every driver window**.
- **Final registration sweep (2026-11-25 ~03:15 UTC): 50 playing,
  7 blocked (rs, cs, node, java, kotlin, swift — Will's hub-execution
  approval; solidity — classification question), 1 scale-limited
  (csh); 58 registrations.** With py playing and cpp/C held in the
  base registry, every class-(a) and class-(b) language in the top
  100 has now been attempted; the 36 class-(c) languages stand in the
  HELD-FOR-WILL list. The wave program is complete.

## test-001 — ENDED IN FAILURE at step 1017 (the game's own verdict)

At step 1017 the consensus check failed: **mojo returned fail while
the other 49 validators and the reference verifier passed**, and the
driver terminated the test as designed — "test ended: failure —
consensus failed at step 1017 (placements: 1017)". Final state:
1,017 placements, stress.phext 2,351,603 B, preserved read-only as
evidence. Per ruling 3, failure is tracked by consensus; per the hold
rule, the certificate for test-001 is **FAIL/HOLD** regardless of the
49 passes — one dissent ends it, which is the rule working as Will
wrote it. A full `verify test-001` was launched for the formal
per-implementation cross-check record, and a targeted diagnosis is
reproducing mojo's step-1017 validate deterministically (5 runs) and
cross-checking it against the reference and py on identical inputs to
establish which side is wrong — candidates include a residual path
around mojo's run_system() stale-bytes fix. The diagnosis verdict,
the fix (if mojo-side), and the formal certificate land here and in
certs/ when they complete. test-001's outcome stands either way; a
fresh test is a new game, started only on a settled, fully-passing
registry.

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

**Game-scale addendum — root cause found, all 12 hub adapters fixed
(resume attempts 2, audit to ~12:31 CST):** Fortran's init passed, then
the resume died on `TimeoutError: dart did not respond`. Diagnosis: the
load was never slow (dart explodes the 2.2 MB state hub-side in 0.31 s;
local init 0.5 s) — **the channel is**: every hub init ships ~3.0 MB of
base64 state through the SSH proxy at ~72 KB/s aggregate (~24 KB/s
under contention). Pre-fix, EVERY hub adapter exceeded the driver's
30 s init timeout at game scale (go 269 s, r 235 s, php 151 s, perl
126 s, ruby 117 s, julia 52 s, fortran 33 s, dart 25 s solo and over
under contention). Side discovery: lua/nim/ocaml/vb serve() was a pure
relay with no state_path translation — their hub init cached an empty
state and replied pass (a hollow pass; their smoke-scale serve-init
evidence was therefore invalid, now superseded). Fixes, in each port's
own source, hub copies md5-verified, compiled ports rebuilt: (1) GZ1
framing — serve lines >8 KB travel gzip+base64 both directions;
(2) deferred init cache — init caches the exact state bytes + sha256
and replies immediately, materializing through the port's own libphext
at first validate; (3) translating serve() for lua/nim/ocaml/vb.
Regression: init on the 1,000-placement snapshot now **0.06–0.11 s**
per adapter; full serve audit 8/8 for all 12; one-shot verify PASS/30
for all 8 wrapper ports. The driver timeout is NOT miscalibrated (a
legitimate init load is 0.3–0.6 s) and was left untouched. Correction
to the audit's own sweep: awk/bash/fsharp/tcl DO have registration.json
files (status playing) — the audit missed them; their game-scale audit
is a top-up, combined with the recommended **one-turn rehearsal at game
scale** before test-001 resumes (per-turn choose/apply and validate
still ship state over the same channel; framing cuts them ~3–6×, but no
game-scale turn had been rehearsed).

**Rehearsal results (record: `harness/serve-conformance.md`):** the
top-up brought awk/bash/fsharp/tcl to conformance (GZ1 + deferred init;
init 0.06–0.09 s; audit 8/8; their pre-fix inits had breached at
35–80 s). The one-turn rehearsal at game scale (18 adapters — the
pre-wave-3 registry; turn 1001 on a snapshot): init all pass
(0.01–0.47 s); elect→choose→apply→attest 0.83 s against the 15 s
window; post-turn verify PASS / 1001 (awk, reference, py). Validate
passed within 60 s for 17 of 18. Two findings gated the resume:
(1) **bash validate takes 107.06 s** solo (correct verdict, two
pure-bash explodes of 2.2 MB) against the 60 s timeout — an intrinsic
breach unless an algorithmic fix exists; a focused performance pass is
dispatched (the R port's identical-looking breach turned out to be two
O(n²) loops — fixed in-port, differential-tested byte-identical over
6,021 strings, validate now 10.91 s). (2) **Echo legs died under
18-way concurrent serve spawn** (SSH banner-exchange timeouts, victims
varying by run; solo always fine) — a driver transport-robustness
defect.

**Both follow-ups have now landed except bash:** the driver gained
transport-only spawn hardening (staggered launches, bounded retry on
transport failure only — a live error verdict still propagates
immediately and a dead adapter still fails loudly by id; no game
semantics and no timeout value changed). Proof: two consecutive full
26-serve spawns, every init pass within 30 s, zero deaths — run 2
absorbed one real banner timeout live. Wave 3's eight adapters then
passed the validator rehearsal (validate 3.88–17.28 s against the
60 s timeout), so **validator rehearsal coverage is now all 26
registered adapters**. Watch item: wave-3 inits are full loads, not
deferred (3–22 s; scala 19.26 s peak) — within budget, thinner margin
under load. **The sole remaining gate was the bash validate pass —
now closed:** bash validate at game scale is **10.15 s** (was
107.06 s), verdict pass. The cost was algorithmic, as with R:
whole-string substitution passes priced per-replacement (67 s) plus a
per-part function-call walker (38 s) over the state's 1,296,097 break
bytes. Fixed in `ports/bash/src/phext.sh` only (chunked encoding,
run-length break tokens guarded by a load-bearing no-literal-0x02
check, scalar walker); differential-tested identical to the old
implementation (explode maps on both game files, 16 synthetic edge
cases, validate responses byte-identical in pass and every fail mode);
suite green, serve audit 8/8, verify PASS / 30. **All resume gates are
clear; test-001 resumes with the full registry (34 serves).**

Known minor — **resolved**: the four wave-1a ports' selftest fixtures
were stale beyond the flagged keys-hash line: behind it (masked, because
verify checks keys-hash first) sat a non-pinned index (2 fields, no
header), a non-pinned event shape, and a non-pinned descriptor. The
fixtures' build sections were refreshed to the pinned template
(test-side only; no verify or implementation code touched). All four
selftests now PASS (13 checks) and one-shot smoke-001 verify still
passes / 30. Open housekeeping item: the hub copies of
`selftest_adapter.py` in `~/telephone-<slug>/tests/` are different,
v1-era stubs (not copies of the local files) — left untouched rather
than overwritten; retire-or-replace is a coordinator call on a later
pass.

## Wave 2a — COMPLETE: Visual Basic, Lua, OCaml, Nim all playing

All four pass every gate: suite green, fixtures 16/16 byte-identical,
adapter self-test PASS, smoke-001 verify PASS / 30, serve-init PASS.
Toolchains: VB.NET on dotnet 8.0.427; Lua 5.1.5 (the hub's only Lua —
`wire.lua` implements SHA-256 in pure Lua, verified against known
vectors); OCaml 4.14.1 (hand-written SHA-256/base64/JSON in `wire.ml`);
Nim 2.4.2. All four initially lacked serve `init` — the Fortran failure
mode was universal among hub CLIs — and all four now implement it plus
the driver-form `validate`, so they are ready for actual gameplay, not
just the init probe. Their init is so far proven at smoke scale; the
game-scale init audit (see the addendum above) must cover them before
they join a full game.

## Wave 2b — COMPLETE: Awk, Bash, F#, Tcl all playing

All four pass every gate: suite green, fixtures 16/16 byte-identical,
adapter self-test PASS, smoke-001 verify PASS / 30, serve-init PASS
(all four hub CLIs implement `init` from the start — the serve-init
acceptance was in their brief). Idioms honored natively: pure-Tcl
phext+JSON, pure-gawk phext+JSON+base64, pure-bash phext+JSON (coreutils
only for sha256/base64/gpg), full .NET F#. Remove is
coordinate-preserving in all four, explicitly tested. Note: the bash
suite takes 1m48s on the 9.4 MB real-corpora fixture (substitution-bound
in pure bash; stress-size files are fast) — its game-scale init latency
is one to watch in the audit.

## Wave 3a — COMPLETE: Delphi/Object Pascal, COBOL, Ada, Objective-C all playing

All four pass every gate (measured EE 533): suite green (Delphi 46/46,
COBOL 25/25, Ada 41/41, ObjC 41/41), fixtures 16/16, self-test PASS,
smoke-001 verify PASS / 30, serve init + driver-form validate, and
game-scale init within the 30 s timeout — COBOL 6.15 s, Delphi 10.23 s,
Ada 10.58 s, Objective-C 3.70 s. Toolchains, all user-level, no sudo:
GnuCOBOL 3.2 via micromamba (package name is `gnucobol`); Free Pascal
3.2.2 from Ubuntu pool .debs extracted user-level (the port carries a
native FIPS 180-4 SHA-256 unit — Debian's units lack fcl-hash); GNAT
14.2.1 via Alire; and for Objective-C a full GNUstep stack built from
source (libobjc2 2.2.1 + gnustep-make 2.9.2 + gnustep-base 1.30.0,
`--disable-tls`) — the gcc/GNU-runtime route died on the fragile ABI;
libobjc2 was the correct route. GZ1 framing adopted by all four.
Operational hazard recorded for future waves: ~102 stale gpg-agent
processes on the hub silently broke key generation for a recreated
GNUPGHOME; `pkill -u wbic16 gpg-agent` is the reliable reset.

## Wave 3b — COMPLETE: Prolog, D, Lisp, Scala all playing

(The worker died without a final report; the results below are read
from the four ports' registration.json records, which carry the full
acceptance evidence.) All four: suite green (82 checks each), fixtures
16/16 byte-identical + normalize-idempotent, self-test PASS, smoke-001
verify PASS / 30, serve init + driver-form validate implemented, and
**game-scale init measured within the driver's 30 s timeout** —
Prolog 14.08 s, D 3.42 s, Lisp 4.22 s, Scala 5.20 s. Toolchains, all
user-level: SWI-Prolog 10.0.0 and SBCL 2.6.10 via micromamba
conda-forge; LDC 1.40.0 and Scala 3.5.2 via official tarballs. The D
port's note records the transport measurement independently: plain
base64 init measured 56 s over the channel (would fail); their wire
gzip wrapper (~0.7 MB on the wire) brings it to 3.42 s. Note: wave 3's
framing dialect (`{"gz_b64": ...}` payload wrapper) differs from the
audit's `GZ1:` line prefix — framing is per-port, between a port's own
wrapper and its own hub CLI, so both dialects coexist without
interoperability impact.

## Wave 4a — COMPLETE: Haskell, Caml, ML playing; Solidity blocked for classification review

Haskell (GHC 9.6.6 via GHCup), Caml (distinct implementation on the
OCaml toolchain — record coordinates, functorised store, its own
choose/elect rules; not a copy of the OCaml port), and ML (MLton,
Standard ML) all pass every gate: suites green, fixtures 16/16,
self-test PASS, smoke-001 verify PASS / 30, game-scale init 0.10–0.12 s
and validate 4.29–5.58 s — the fastest validators in the program.

**Solidity (#49) — blocked, honestly.** A genuine libphext core in
Solidity itself was built and compiles clean (`Phext.bin` 11,048 B);
no other language was shelled out to for phext logic. It cannot play,
by construction (evidence: `ports/solidity/EVIDENCE.md`): no EVM
runtime exists on the hub; the EVM has no file/process/stream opcodes,
so seek (raw file I/O), keygen/attest (subprocess PGP), and serve
(stdin/stdout) are impossible in-contract; and the 2.2 MB game state as
calldata alone exceeds a block gas limit, so one game-scale validate
cannot fit in a block. The port is registered `blocked` with a
**classification question for Will**: TOP100 classed Solidity (b)
(implementable, toolchain absent), but the evidence says it behaves
like the class-(c) platform-bound entries. Reclassification is Will's
call; the challenge is recorded, not silently applied.

## Wave 4b — COMPLETE: Clojure, Crystal, Groovy, PowerShell all playing

All four pass every gate: suites green (82 checks each), fixtures
16/16, self-test PASS, smoke-001 verify PASS / 30, serve audit 8/8,
game-scale init 0.06–0.16 s and validate within the 60 s timeout —
Crystal 7.05 s, Groovy 6.69 s, PowerShell 22.35 s, Clojure 26.11 s.
Toolchains user-level: Clojure CLI 1.12.3.1577 tarball, Crystal 1.16.3
tarball, Groovy 4.0.24 (from archive.apache.org — dlcdn had rotated
it), PowerShell 7.4.6 tarball. All four carry GZ1 framing + deferred
init from the start.

## Wave 5a — COMPLETE (after re-audit): Erlang, Elixir, Scheme playing; Forth blocked

The original wave-5a worker errored out mid-acceptance; a completion
worker re-ran every claimed gate from scratch. Erlang, Elixir, and
Scheme pass everything: suites green (74 checks each), fixtures 16/16,
self-tests PASS, smoke-001 verify PASS / 30, and full game-scale serve
audits with every leg inside its window (validate 7.15–12.08 s; serve
verify pass/1001 in 23.64–35.01 s). On the erlang live-game death: no
defect reproduced uncontended — the evidence is consistent with hub
contention and/or the dying worker's mid-flight rebuild of the hub CLI
(its timestamp sits minutes before the death); the caveat is recorded
in erlang's registration note. **Forth is honestly blocked**: its hub
CLI was never written (the hub run.sh execs a nonexistent file) and its
library crashes on the hub (gforth "Invalid memory address" in
phokenize/explode during fetch). A full build worker is dispatched;
forth's registration records both defects with measurements.

**test-001 resumed again ~22:05 CST** on the settled registry (39
playing + reference = 40 serves; forth excluded by its blocked
status): driver alive, stress.phext advancing (2,247,779 B at 22:08
CST — turns 1002+ inscribed), no errors in the log. It stalled a third
time at ~22:22 CST (~1,004 placements): `TimeoutError: delphi did not
respond` on a per-turn validate call under live hub contention (Forth
build + two wave-6 workers active; delphi's solo validate is 17.28 s
against the 60 s timeout). A validator timeout is not a ruled test
failure — it is transport fragility, and the driver's die-on-timeout
posture makes the walk stall instead of completing the step's
validation. Driver hardening round 2 is dispatched: bounded retry for
the idempotent per-turn calls (validate, echo) — respawn + re-init +
re-issue on transport failure only, verdicts never retried, exhaustion
still fail-closed; choose/apply/attest stay fail-closed (holder
mutations). No timeout values or game semantics change. **Round 2 has
landed and test-001 is playing again** (~23:49 CST, 44 serves): the
retry wrapper covers validate + echo (transport failures only;
verdicts never retried; exhaustion still fail-closed), proven by a
unit leg (a tampered validate returns fail in exactly one attempt) and
a chaos leg (delphi's hub process killed −9 mid-validate; the wrapper
respawned, re-inited, and completed verdict pass). Full-spawn proof:
44/44 init pass, worst 13.73 s. The walk is advancing (turn ~1005
inscribed 23:51 CST). Recorded finding for later: choose/apply appear
to be pure functions of (prior state, chosen move) with inscription
held by the driver, so their retry safety may be establishable — not
acted on; they remain fail-closed. **The walk stalled again the same
hour, instructively: the retry wrapper exhausted all 3 attempts on
cfml validate** (`TimeoutError: cfml did not respond`, re-raised as
designed, fail-closed, file intact at turn ~1005). CFML's solo
validate is 40.50 s — 68% of the 60 s budget before contention — and
its CLI boots a fresh CommandBox/Lucee per hub call; under wave-build
hub load it cannot answer. A CFML performance pass is dispatched
(profile → in-port fix → differential correctness gate, target ≤30 s
solo); test-001 resumes when it lands and the hub is quieter (waves
6a/7 finishing). The retry system itself worked exactly as specified —
this death is a slow-validator problem, not a driver problem.
**CFML pass landed (EE ~577–583): validate 40.50 s → 11.85/20.63 s
solo.** Root causes: per-byte phokenize over a file that is 57% break
bytes (bulk text-run scanning + arithmetic break-run collapse took
explode 5,408 → ~200 ms), an O(n²) insertion sort (→ merge sort), and
a fresh CommandBox boot per call (→ warm Lucee daemon with a one-shot
fallback). Differential-tested identical verdicts and fail details in
all five modes; suite 80/0; verify PASS / 30 in 3.8 s. **test-001
resumed ~01:59 CST and is advancing** (2,272,075 B at 02:01 CST,
driver alive) with CFML in the roster.

## Wave 5b — COMPLETE: SPARK, V, Vala/Genie, CFML all playing

All four pass every gate (EE 550): suites green (SPARK 41, V 81, Vala
80, CFML 80 checks), fixtures 16/16, self-tests PASS, smoke-001 verify
PASS / 30, game-scale init and validate within timeouts — SPARK init
11.88 s / validate 8.22 s (GNAT via the Ada port's Alire install;
SPARK_Mode compilation is the evidence — no gnatprove binary exists in
that env, recorded honestly), V 0.09 / 4.13 s, Vala 0.11 / 4.34 s
(after two genuine O(n²) fixes), CFML 0.06 / 40.50 s (the registry's
slowest validate, inside the 60 s budget; every hub call is a fresh
CommandBox boot). CFML's engine is Lucee 5.4.8.2 via CommandBox 6.3.5 —
the standalone Lucee jar route was unreachable from the hub; the
deviation is recorded in its registration. The worker also caught its
own stale scale-script (it hardcoded turn 1001 after the live file had
advanced) and replaced it with `scale-test-live.py`, which derives
turn/event-seq from the snapshot itself.

## Wave 6b — PARTIAL: toolchains landed; ksh library done but fixture-blocked; J/Modula-2/REXX unbuilt

All four toolchains landed user-level (J 9.6 tarball; ksh93 v1.0.10
built from source, mksh fallback also built; gm2 13.3.0 via Ubuntu deb
extraction after conda-forge and a GCC source build both failed with
evidence; Regina REXX 3.9.5 via deb extraction after SourceForge and
conda-forge routes failed). The ksh library is complete and correct —
and **ksh93 itself segfaults** on the 9.4 MB real-corpora fixture
(sentinel-split), leaving fixtures at 15/16 despite game scale being
proven fine (explode 6.56 s / implode 2.64 s on the 2.2 MB snapshot).
J, Modula-2, and REXX have toolchains only. All four are registered
`building` with evidence — the settled-registry rule held; nothing was
marked playing early. Completion workers are dispatched for both
halves (ksh segfault route-around + adapter; J/Modula-2/REXX builds).
**Ksh has since completed** (see the port-status table): the crash was
in ksh93's string-equality builtin at ≥3 MB operands inside the test
harness, not in the library or the sentinel-split as first recorded —
the correction stands on staged bisection evidence. Registry note:
the driver merges `ports/*/registration.json` over the base
`harness/registry.json` (9 entries: reference + the original blocked
ports), so per-port registrations are the roster — no separate
registry edit is needed for a port to join at the next resume.

## Wave 6b completion — J, Modula-2, REXX all playing

All three pass every gate: suites green (REXX, Modula-2 68 checks, J
50), fixtures 16/16, self-tests PASS (14 checks), smoke-001 verify
PASS / 30, game-scale init 0.06 s and validate in window (Modula-2
4.62 s, J 8.99 s, REXX 20.19 s). Notable: the three ports independently
chose the **same coordinate** (4.4.4/4.7.4/4.4.4) from the same game
state — cross-implementation determinism evidence. J's choose took
15.60 s, over the 15 s turn window (ksh is the other member of that
class: validate yes, hold a turn not yet). The gm2 toolchain needed
generated jmp-thunk shims for Ubuntu's prefixed RTS symbols —
documented in Modula-2's registration note.

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
| vb, lua, ocaml, nim | **playing** — wave 2a complete (see below); full gate set incl. serve-init PASS (smoke scale) |
| awk, bash, fsharp, tcl | **playing** — wave 2b complete; game-scale top-up done (init 0.06–0.09 s, audit 8/8); **bash validate 107 s vs 60 s timeout — performance fix dispatched**; awk/fsharp/tcl rehearsal-clean |
| prolog, d, lisp, scala | **playing** — wave 3b complete (see below); game-scale init 3.4–14.1 s, within timeout |
| delphi, cobol, ada, objc | **playing** — wave 3a complete (see below); game-scale init 3.7–10.6 s, within timeout |
| haskell, caml, ml | **playing** — wave 4a complete (see below); game-scale validate 4.3–5.6 s |
| solidity | **blocked — classification review for Will**: genuine Solidity core built + compiles; cannot play by construction (no EVM runtime on hub, no file/process/stream opcodes, block gas limit) — evidence in ports/solidity/EVIDENCE.md |
| clojure, crystal, groovy, powershell | **playing** — wave 4b complete (see below); game-scale validate 6.7–26.1 s |
| Xojo (#44) | not waved — proprietary, builds license-gated per TOP100's own flag; surfaces with Will's gated list rather than being silently skipped |
| Common Lisp (band) | covered by the SBCL lisp port (TOP100: one SBCL port serves Lisp #36 and the band entry) |
| erlang, elixir, scheme | **playing** — wave 5a complete after a full re-audit (see below); full game-scale serve audits pass, all legs within windows |
| forth | **playing** — full build complete: ~15 stack-effect defects fixed (headline: phokenize's break branch leaked one stack item per break byte), full Forth CLI written (in-Forth SHA-256/base64/JSON); suite 35/0, fixtures 16/16 incl. 9.4 MB, serve audit all legs in window, validate 5.22 s |
| spark, v, vala, cfml | **playing** — wave 5b complete (see below); game-scale validate 4.1–40.5 s |
| Wave 6a new ports: Algol, C shell, Icon, Io | building — class (b) band entries; briefs carry the settled-registry rule and snapshot-derived scale tests (the live game is running) |
| ksh | **playing** — completion worker found the "segfault" was ksh93's own `[[ == ]]` crashing on ≥3 MB operands in the TEST harness's comparison, not the library; fixed via a slice-comparison helper with negative controls; fixtures 16/16, serve battery 8/8, validate 36.98 s. Caveat: ksh choose/apply (22.8/33.1 s) exceed the 15 s turn window — it can validate at scale but cannot yet HOLD a turn at scale |
| j, modula2, rexx | **playing** — wave 6b complete (see below); validate 4.6–20.2 s. Caveat: J choose 15.60 s exceeds the 15 s turn window (like ksh — can validate at scale, cannot yet hold a turn) |
| Class (b) remainder after wave 6 | Smalltalk, Mojo, Hack (hardest of class b — HHVM is system-oriented) — wave 7 scope; Q (proprietary license) surfaces with Will's list |
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
  languages): the full 36 are listed in TOP100.md; Will decides, the
  list is not trimmed.
- **Solidity classification question** (wave 4a evidence): TOP100
  classed Solidity (b); the built port's evidence
  (`ports/solidity/EVIDENCE.md`) says it behaves like class (c).
  Reclassify, or direct another route (e.g. an EVM runtime on the
  ranch)? Will's call.
- **Xojo (#44)**: proprietary, builds license-gated — pursue, license,
  or hold? Will's call.
- ~~Design-gap rulings~~ — **closed**: Will ruled all 8 on 2026-11-24
  10:37 CST; the design above is built on them.

## Discipline

Branches only where repos already exist; no merges, no tags, no registry
publishes, no new GitHub repos. Workers stop at execution-risk flags and
report; nobody dispatches past a flag. Sudo needs are recorded as
blocked-for-Will, never attempted.

## test-001 step 1017 — mojo dissent diagnosis (EE 595, 2026-11-24)

**Verdict: mojo was wrong; the recorded step is valid. test-001's recorded
outcome (failure at step 1017, 1,017 placements) stands unchanged.**

Step 1017 (from the final file, sha256
`09e6c6b8279ff0adfb129c8e091ebe1cea4d2bcd4168679f0df5e82f35ed8d84`,
2,351,603 B, read-only throughout): index line `1017
900.234.749/1032.61.102/746.872.1274
da59308d75b52f4c33fbaa2b076d16a7b9fc7fe91cecee2eb7e6a14f9ceb4971 py`;
event scroll at 1.1.1/1.1.1/2.1.1018 (placement, actor py, coord as above,
text_sha256 matching the index and the placed scroll `py placement 1017
at 900.234.749/1032.61.102/746.872.1274`).

Cross-checks on identical reconstructed inputs (prior = file after step
1016's inscription; state = file as validators saw it at step 1017):
reference validate PASS (×3), py validate PASS (×3), mojo validate with
prior_state attached PASS 5/5, and mojo's own full verify of the final
file: `{"first_failure": null, "impl": "mojo", "placements_checked":
1017, "verdict": "pass"}`. The concurrent verify-final.log landed only
`certificate: HOLD (1017 placements)` (the expected hold: <10,000
placements and status failure).

Root cause (deterministic, reproduced): the mojo **adapter wrapper's**
deferred-init cache was single-use. `ports/mojo/adapter` cached the init
state in `pending_init`, attached it as `prior_state` on the first
validate, and cleared it (`pending_init = None`). The hub CLI is
stateless and its `do_validate` returns fail `validate called before
init` when no `prior_state` arrives — so every second-and-later validate
in a serve session failed regardless of the step's validity. Reproduced
pre-fix in one serve session: validate #1 PASS, validate #2 (same valid
inputs, no re-init) FAIL `validate called before init`. Earlier steps
passed only when a resume or a transport-retry re-init happened to
precede them. Ruled out: the Mojo core (explode/validate with a correct
prior passes 5/5 at game scale), the run_system stale-bytes class
(validate's driver-form path makes no system() call), and any
size/content threshold (same bytes pass with prior attached).

Fix: the wrapper cache is now **rolling** — on a passing validate the
validated state becomes the prior for the next validate; on fail the
cache does not advance. This mirrors `harness/adapter_base.py`, whose
validate advances its cache on pass. The defect was in the local wrapper
only; the hub copies were verified byte-identical before and after
(src/telephone.mojo sha256 `5b42bf3a…`, bin/run-telephone `c2191a1c…`,
matching local) and needed no change.

Re-gates after the fix (all green, registration stays **playing**):
native suite 53 checks / 0 failures; fixtures 16/16 byte-identical;
adapter self-test PASS; smoke-001 verify PASS / 30; game-scale in-session
validate chain 1016 → 1017 PASS 5/5 (the exact pre-fix failure mode);
tamper negative control still FAILs (`placed scroll missing or
altered`) and a good validate after it still PASSes (cache unadvanced
on fail); mojo full verify of the final test-001 file PASS / 1017.

## test-001 certificate — issued, and how to read it

`certs/test-001.json` / `certs/test-001.md`: **HOLD**, 1,017 of
10,000 placements, stress.phext sha256
`09e6c6b8279ff0adfb129c8e091ebe1cea4d2bcd4168679f0df5e82f35ed8d84`,
test status: failure. Reading it correctly: the certificate's
"participants" are the game's inscribed placement actors from its
genesis keys scroll (py 509 placements, reference 508); the other
ports participated as consensus validators on every turn — their
per-turn verdicts, including the step-1017 consensus failure, are the
play.log record. The verify path's cross-check section lists the
remaining ports as "no-adapter" because the driver's verify command
enumerates only the base registry's adapters (py + reference), not
the merged per-port registrations the play path uses — a recorded
harness gap for the next test, not missing evidence: per-adapter
one-shot verifies exist for every playing port (smoke PASS/30 each,
and mojo's post-fix full verify passes all 1,017). The HOLD stands on
three independent legs, any one sufficient: the test ended in
failure, placements are 1,017 of the 10,000 success unit, and the
actor roster was 2 of the network. **Program state at completion of
the wave plan: 50 ports playing, 7 blocked, 1 scale-limited, 36
class-(c) held for Will; the hold on all libphext updates remains in
force.** A future test-002 should be created with the full playing
roster inscribed as actors at genesis (and the verify path taught
the merged registry); it cannot issue a PASS until the blocked ports
resolve, which is Will's call — the hold is the rule working.
