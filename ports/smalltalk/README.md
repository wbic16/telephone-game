# libphext-smalltalk — Smalltalk port

Status: **playing**. Pharo 12 (image `Pharo12.0-SNAPSHOT-64bit`,
VM reports Pharo v10.3.13) installed user-level on aletheia-core —
no sudo anywhere:

- `pharoImage-x86_64.zip` and `pharo-vm-Linux-x86_64-stable.zip` from
  `https://files.pharo.org/get-files/120/`, unpacked at
  `~/telephone-smalltalk/pharo12/`.
- The CLI runs per invocation from the **pristine** image:
  `~/telephone-smalltalk/run.st` files in the three sources and calls
  `TelephoneCli run`. An image saved from a command-line session
  silently ignores later command-line handlers in this Pharo build
  (eval/st produce no output, exit 0), so no pre-saved image is used;
  file-in costs ~0.3 s of the ~0.5 s per-call total.

Layout:

- `src/phext.st` — libphext core at 0.6.1 parity: `PhextLib`
  (explode/implode/fetch/insert/replace/remove on raw bytes — remove
  is coordinate-preserving — plus normalize), `DynPhext` (CLRS
  quarter-full dynamic array, capacity from 1) and `TrnPhext`
  (nested hash maps, one layer per dimension). SHA-256 and base64
  are image builtins (`SHA256`, `ZnBase64Encoder`).
- `src/json.st` — own JSON parser (`JsonRdr`) + canonical writer
  (`JsonWtr`: sorted keys, minimal escaping, Python `ensure_ascii`
  parity).
- `src/telephone.st` — the stateless contract-v2 CLI (`TelephoneCli`:
  echo/elect/choose/apply/init/validate/verify, PGP keygen/attest/
  verify via subprocess gpg through `LibC system:`) plus the
  in-image test suite (`TelSuite`).
- `hub/run-telephone.sh` — hub runner (installed at
  `~/telephone-smalltalk/bin/run-telephone`): dual mode like the
  other ports (`serve` = persistent line loop; no arg = one-shot,
  all of stdin is one request), owns the port GNUPGHOME
  (`~/telephone-smalltalk/gnupg`, UID `telephone-smalltalk`), and
  does the GZ1 wire framing (>8 KB) — the CLI itself is
  framing-free and stateless.
- `adapter` — local Python wrapper (fleet-ssh relay, deferred init
  cache; driver-form validate attaches `prior_state`).
- `tests/selftest_adapter.py` — contract-v2 adapter self-test.
- `tests/run_tests.sh` — suite (hub runner test command) + self-test.

Pharo quirks found and handled:

- This Pharo compiles a script/`st` file as one unit, so filed-in
  sources bind just-created classes to script temporaries
  (`PhextLib := Object subclass: #PhextLib …`); method bodies are
  attached with `compile:` and resolve globals at runtime.
- The chunk-format reader treats `!` as a chunk terminator — the
  sources contain no `!` at all (the verify failure message reads
  "index lines differ from placements", not "!=").
- `FileStream binaryWriteStream` does not truncate an existing
  file: a short response written over a longer previous one left a
  stale tail that the runner's `cat` emitted as a phantom extra
  serve line. The CLI deletes the response file before writing.
- Method parameters are read-only (assignments need a temp).
- The VM does not exit after an `st` script unless the script ends
  with `Smalltalk snapshot: false andQuit: true.`
- `OSSUnixSubprocess` is not loaded; `LibC system:` is the
  subprocess route (children inherit GNUPGHOME).

Gates (2026-11-24): suite 35 checks, 0 failures; fixtures 16/16
byte-identical round-trips, 16/16 normalize-idempotent; adapter
self-test PASS; smoke-001 one-shot verify
`{"first_failure": null, "impl": "smalltalk", "placements_checked": 30, "verdict": "pass"}`.
Game scale on a snapshot of live test-001 (1017 placements,
2,351,603 bytes, sha256 09e6c6b8…), two runs: serve init
0.06–0.09 s, choose 8.32 s → 4.4.4/4.4.4/4.7.4 (a first run under
heavy multi-wave hub contention measured 49.67 s; the second run is
the steady state), apply 8.69–11.42 s (sha match), driver-form
validate 6.61–7.34 s PASS — all inside the driver windows.
