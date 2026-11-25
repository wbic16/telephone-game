# libphext-ksh — Korn shell (ksh93) port

Status: **playing** (see registration.json for the full gate evidence).

Toolchain: ksh93 v1.0.10 (93u+m/1.0.10, 2024-08-01) built from the
ksh93/ksh v1.0.10 source tarball, user-level at
`~/telephone-ksh/ksh93/ksh` on aletheia-core (build: `bin/package make`;
the `-j` flag is not accepted by bin/package). mksh R59c was also built
from source as a fallback (`~/telephone-ksh/bin/mksh`) but was NOT
needed: no dialect change was required (see the segfault root cause
below).

Layout:
- `src/phext.ksh` — libphext 0.6.1 parity in native ksh93: Phext
  (phokenize/dephokenize/normalize/fetch/insert/replace/remove,
  explode/implode), DynamicPhext (dyn_*), TransitivePhext (trn_*).
  Remove is coordinate-preserving (replace with "" then normalize;
  later scrolls keep their coordinates — explicitly tested).
  Implementation notes: coordinates travel as comma-joined strings;
  byte strings return through globals because command substitution
  strips trailing newlines and newline is ordinary scroll text;
  phokenize escapes sentinel 0x02 and splits at C speed; arrays must
  be declared `typeset -a` before reset/append in ksh93 (a plain
  `arr=()` + `arr+=(...)` silently appends an empty element — found
  and fixed during this build). All functions use the `function name`
  definition style: ksh93 POSIX-style `name()` functions leak
  `typeset` locals across calls.
- `src/json.ksh` + `src/telephone.ksh` — the contract-v2 hub CLI
  (wire protocol: one JSON object per line, state as base64; GZ1
  framing for lines > 8 KB; `init` cache + driver-form `validate`;
  PGP via subprocess gpg, GNUPGHOME `~/telephone-ksh/gnupg`).
  Ported from the bash port's wire CLI with documented dialect
  changes: `.sh.match` for BASH_REMATCH, `read -A` for `read -a`,
  an iterative (non-recursive) canonical serializer — ksh93
  clobbers recursive function locals — and `bytes_eq` for every
  scroll-text equality.
- `adapter` — local python3 wrapper (fleet-ssh relay to
  `~/telephone-ksh/telephone` on the hub; translates driver
  `state_path`/`state_out_path` forms to the wire form; GZ1 framing;
  deferred init cache flushed before the first validate; seek by
  raw file I/O only).
- `tests/test_phext.ksh` + `tests/run_tests.sh` — native suite;
  `tests/selftest_adapter.py` — adapter self-test (pinned formats).

The wave-6b "segfault", root-caused (2026-11-24): ksh93 itself was
never crashing in the sentinel-split. Staged reproduction on the
9,405,538 B `chains/real-corpora-chain` fixture showed read, encode
and split all fine, and explode (10,547 scrolls) / implode /
normalize byte-identical — once the result was compared safely.
The crash is ksh93 1.0.10's `[[ $a == "$b" ]]` on multi-MB operands
(measured: passes at 2,800,000 B, kills the shell with exit 255 and
no diagnostic at 3,000,000 B); the test harness's own round-trip
comparison was the crashing call. Fix: `bytes_eq` in phext.ksh —
length check plus 64 KB slice comparisons — now used for every
large-text equality in the suite and the adapter. Negative controls:
bytes_eq detects a single flipped byte at offset 5,000,000 and at
the final byte of the fixture. Fixtures: **16/16** byte-identical
round-trips, native suite PASS.

Acceptance (2026-11-24, hub): adapter self-test PASS (13/13);
one-shot `adapter verify games/smoke-001/stress.phext` PASS / 30
placements; driver-form serve battery 8/8 PASS; game scale on a
snapshot copy of the live test-001 file (2,260,772 B, 1,004
placements): INIT 0.06 s (30 s budget), VALIDATE 36.98 s pass
(60 s budget). Choose 22.82 s / apply 33.07 s complete correctly
but exceed the driver's 15 s per-turn window (channel-bound; the
cross-port risk flagged in harness/serve-conformance.md).
