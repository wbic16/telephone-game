# libphext-mojo — Mojo port

Status: **playing**. Mojo 1.3.0.dev2026112405 (Modular max-nightly,
installed user-level with pixi 0.84.2) at `~/telephone-mojo/pixi-home`
on aletheia-core; the adapter CLI is the single compiled binary
`~/telephone-mojo/bin/telephone`.

Layout:

- `src/telephone.mojo` — everything in one Mojo file: libphext core
  at 0.6.1 parity (explode/implode/fetch/insert/replace/remove —
  remove is coordinate-preserving — plus normalize), own SHA-256 and
  base64, a JSON arena DOM parser + canonical writer, DynamicPhext
  (CLRS quarter-full dynamic array, capacity from 1) and
  TransitivePhext (nested hash maps, one layer per dimension), and
  the contract-v2 game logic (echo/elect/choose/apply/init/validate/
  verify, PGP attest/verify via subprocess gpg).
- `hub/run-telephone.sh` — hub runner (installed at
  `~/telephone-mojo/bin/run-telephone`): bridges stdin/stdout JSON
  lines to the binary's per-request (reqfile, respfile) invocation,
  owns the port GNUPGHOME (`~/telephone-mojo/gnupg`, UID
  `telephone-mojo`), and does the GZ1 wire framing (>8 KB) — the CLI
  itself is framing-free and stateless.
- `adapter` — local Python wrapper (fleet-ssh relay, deferred init
  cache, GZ1 framing, state_path/state_out_path ↔ base64 translation,
  raw-I/O seek; driver-form validate attaches the deferred-init state
  as `prior_state`).
- `tests/selftest_adapter.py` — adapter self-test (PASS).
- `tests/run_tests.sh` — native suite on the hub: 53 checks,
  fixtures 16/16 byte-identical round-trips.

Acceptance (2026-11-24): suite green; fixtures 16/16; self-test
PASS; smoke-001 one-shot verify PASS/30 verbatim; game scale on a
snapshot of live test-001 (1,011 placements, 2,310,650 B): init
0.06 s, choose 5.24 s, apply 15.53 s (over the 15 s turn window —
the scale-limited class also recorded for ksh and J), driver-form
validate 6.48 s PASS.

Mojo quirks (hard-won):

- Every subprocess call goes through `run_system()`, which passes
  `system()` an explicitly NUL-terminated copy of the command in a
  fresh byte buffer. A concatenated Mojo String's backing store can
  carry stale bytes past its logical end; C's `system()` reads to
  NUL, so commands intermittently reached /bin/sh corrupted (a path
  segment duplicated) — the root cause of weeks of flaky-looking
  gpg/mkdir failures. With the fresh buffer, delivery is byte-exact.
- In-process `system()` pipelines are unreliable in this build
  (dash "Bad fd number"), so GZ1 gzip framing lives in the bash
  runner, not the CLI; gpg import/verify run with stdout/stderr
  redirected to files and a bounded retry.
- `shell_out()` callers must not embed their own redirections or
  `||` compounds in the command (the appended redirect binds to the
  last compound element and dumps output into the protocol stream).

Diagnosis (2026-11-24, EE 595): mojo's lone dissent at test-001 step
1017 was a wrapper defect, not a step defect — the deferred-init cache
was single-use, so later validates in a serve session reached the
stateless CLI with no prior_state and failed "validate called before
init". Fixed with a rolling cache (advances on pass only); all gates
re-pass, step-1017 chain validate 5/5. Full verdict in REPORT.md.
