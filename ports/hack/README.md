# libphext-hack — Hack port

Status: **playing**. HHVM 4.172.1 (official Debian bullseye build)
installed user-level on aletheia-core — no sudo anywhere:

- `hhvm_4.172.1-1~bullseye_amd64.deb` from dl.hhvm.com (the repo's
  HTTPS certificate is expired and there are no noble packages; the
  bullseye deb is the newest usable official build), extracted with
  `dpkg -x` into `~/telephone-hack/prefix`.
- A full bullseye library closure (66 debs: libc6 2.31, libicu67,
  libssl1.1, boost 1.74, libcurl4 and its transitive deps) resolved
  with a user-level apt root (`~/telephone-hack/apt`) and extracted
  into the same prefix, so every library resolves inside the prefix.
- The runnable binary `~/telephone-hack/bin/hhvm-real` is a copy of
  the official binary with patchelf-rewritten PT_INTERP (the
  extracted bullseye `ld-2.31.so`) and DT_RPATH (prefix lib dirs,
  `--force-rpath`). Two routes failed first: running through the
  loader explicitly breaks HHVM's embedded-systemlib lookup
  (/proc/self/exe points at the loader), and LD_LIBRARY_PATH leaks
  into child processes, where the system shell dies against the
  bullseye libc. RPATH has neither problem. `~/telephone-hack/bin/hhvm`
  is a thin wrapper that execs hhvm-real.

Layout:

- `src/telephone.hack` — everything in one `// partial` Hack file:
  libphext core at 0.6.1 parity (explode/implode/fetch/insert/
  replace/remove — remove is coordinate-preserving — plus
  normalize), own JSON parser + canonical writer, DynamicPhext
  (CLRS quarter-full dynamic array, capacity from 1) and
  TransitivePhext (nested hash maps, one layer per dimension), and
  the contract-v2 game logic (echo/elect/choose/apply/init/validate/
  verify, PGP attest/verify via subprocess gpg).
- `hub/run-telephone.sh` — hub runner (installed at
  `~/telephone-hack/bin/run-telephone`): bridges stdin/stdout JSON
  lines to the script's per-request (reqfile, respfile) invocation,
  owns the port GNUPGHOME (`~/telephone-hack/gnupg`, UID
  `telephone-hack`), and does the GZ1 wire framing (>8 KB) — the CLI
  itself is framing-free and stateless.
- `adapter` — local Python wrapper (fleet-ssh relay, deferred init
  cache, GZ1 framing, state_path/state_out_path ↔ base64 translation,
  raw-I/O seek; driver-form validate attaches the deferred-init state
  as `prior_state`).
- `tests/selftest_adapter.py` — adapter self-test (PASS).

Acceptance (2026-11-24): suite green (38 checks); fixtures 16/16;
self-test PASS; smoke-001 one-shot verify PASS/30 verbatim; game
scale on a snapshot of live test-001 (1,015 placements,
2,339,324 B): init 0.07 s, choose 5.89 s, apply 6.16 s, driver-form
validate 7.78 s PASS — all inside the driver windows, including the
15 s turn window for choose/apply.

Hack notes (hard-won): `foreach` key/value uses `=>` (`==>` is
lambda-only, and `==>` lambdas capture by value); `exec()` out
parameters need explicit `inout` at the call site; `isset()` is
false for null values (key-existence checks use
`array_key_exists`); `as` is a type assertion, not a conversion
(an int ping round needs an explicit stringify); HH\Lib (the HSL)
is not bundled in the deb — the port uses core builtins only
(`hash`, `base64_*`, `exec`, `shell_exec`, file I/O).
