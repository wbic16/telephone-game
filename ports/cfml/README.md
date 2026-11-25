# libphext-cfml

A CFML port of libphext, 0.6.1 parity with libphext-py semantics,
running on Lucee via CommandBox.

- `src/phext.cfm` — Coordinate (9-component array, lexicographic
  order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext and TransitivePhext (structs). Buffers are Lucee
  strings decoded ISO-8859-1, so char position == byte position and
  control bytes are never reinterpreted. Newline (0x0A) is ordinary
  scroll text, never a break. Remove is coordinate-preserving: the
  removed coordinate reads "" and neighbours do not shift.
- `src/cli.cfm` — the telephone-game hub CLI, implementing the full
  contract-v2 game surface. The serve init cache lives on disk
  (`~/telephone-cfml/cache/state.b64`); the local adapter relays each
  serve line through its own `wire()` call, with deferred init and
  GZ1 framing (> 8 KB, both directions) in the adapter and
  `hub/run-cli.sh`. JSON is
  hand-written canonical form; SHA-256 is `hash(..., "SHA-256")`;
  base64 is `binaryEncode`/`binaryDecode`; PGP goes through
  subprocess gpg (Java `ProcessBuilder`, `/bin/sh -c`) with a
  per-port GNUPGHOME (`~/telephone-cfml/gnupg`).
- Performance pass (EE 583, after test-001 died at turn ~1005 when
  serve validate's 40.50 s solo time left no margin under hub
  load): profile on the game-scale snapshot showed one explode at
  5.4 s (per-byte CFML walk in `phokenize`; the snapshot is
  1.30 MB of break bytes in 2.27 MB) and ~8 s of CommandBox boot
  per hub call, validate needing two calls. Fixes, all in-port:
  `phokenize` now scans maximal text runs with a Java regex
  Matcher and collapses each break run arithmetically
  (`coordApplyBreakRun`: per-dimension counts after the last
  lower-dimension break, via Java `lastIndexOf` and a
  replace-**all** length difference — Lucee's member `replace()`
  defaults to scope "one"); `scrollSort` is a merge sort (implode
  3.19 s → 0.70 s); `src/daemon.cfm` keeps one warm Lucee context
  on the hub serving a queue directory, with `hub/run-cli.sh`
  falling back to the one-shot CommandBox run whenever the
  daemon does not answer (the daemon caches no verdicts and
  re-reads the on-disk init cache per validate, and exits when
  the port sources change); the adapter GZ1-frames large
  requests (3.02 MB → ~0.60 MB on the wire) and flushes the
  deferred init on a background thread that validate joins
  before its own call. Result: serve validate on the snapshot
  11.85–20.63 s (was 40.50 s), hub-local init+validate pair
  1.1 s (was 28.4 s), differential vs the pre-pass code
  identical on pass + four fail modes.
- Lucee pitfalls recorded: byte conversion uses Java
  `String.getBytes("ISO-8859-1")` / `String.init(bytes, ...)`
  because Lucee's `charsetEncode` does not return a binary;
  `chr(0)` is the empty string in Lucee, so NUL-bearing test data is
  built from binary; struct literals uppercase their keys, so
  JSON-bound structs are built by bracket assignment; canonJSON
  tests `isNumeric` before `isBoolean` because `isBoolean(0)` is
  true in Lucee.
- `tests/` — dependency-free suite (80 checks): 16/16 byte-identical
  round-trips, 16/16 normalize-idempotent.
- Toolchain: CommandBox 6.3.5 (embedded Lucee 5.4.8.2), user-level
  on aletheia-core at `~/telephone-cfml`. Direct Lucee jar downloads
  failed (cdn.lucee.org returned S3 `NoSuchKey`), so CommandBox is
  the install route; `box <file>.cfm` runs CFML directly.

Acceptance (EE 550): native suite green; fixtures 16/16; adapter
self-test PASS; one-shot verify vs `games/smoke-001/stress.phext`
PASS/30; game-scale on a snapshot copy of `games/test-001/stress.phext`:
init 0.06 s deferred (< 30 s), validate 40.50 s (< 60 s, including
the deferred-init flush — every hub call is a fresh CommandBox
boot), both pass.

Re-acceptance (EE 583, performance pass): native suite green
(80 checks, fixtures 16/16); adapter self-test PASS; one-shot
verify vs smoke-001 PASS/30 in 3.8 s; game-scale on a snapshot
copy of the current `games/test-001/stress.phext` (2,265,624 B,
1,005 placements, turn 1006 derived by `scale-test-live.py`):
init 0.10 s deferred, validate 11.85 s and 20.63 s in two runs
(≤ 30 s target), choose 7.41 s, apply 13.64 s, all pass.
