# libphext-vala

A Vala port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/phext.vala` — Coordinate (`PhextCoord`, 9 components,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (capacity-managed dynamic array) and TransitivePhext
  (GLib HashTable keyed by coordinate string; values wrapped in a
  `Bytes` class because Vala arrays cannot be generic type
  arguments). All buffers are `uint8[]`, so control bytes are never
  reinterpreted. Newline (0x0A) is ordinary scroll text, never a
  break. Remove is coordinate-preserving: the removed coordinate
  reads "" and neighbours do not shift.
- `src/cli.vala` — the telephone-game hub CLI (stdin/stdout JSON
  lines, state as base64, GZ1 wire framing over 8 KB), implementing
  the full contract-v2 game surface. JSON is hand-written (canonical
  form must match the harness exactly); SHA-256 is GLib `GChecksum`,
  base64 is GLib `Base64`; gzip and PGP go through `/bin/sh -c`
  subprocesses on temp files with a per-port GNUPGHOME
  (`~/telephone-vala/gnupg`). Note: `Process.spawn_command_line_sync`
  runs no shell, so anything needing env vars or redirection must go
  through `spawn_sync` with `/bin/sh -c`.
- Scale notes (learned at 2.2 MB): dephokenize emits through
  `GLib.ByteArray` — per-byte `uint8[] +=` appends are O(n²) — and
  the JSON parser caches the input length once, because Vala's
  `string.length` is a strlen and is O(n) per call.
- `tests/` — dependency-free suite (80 checks), run with the fixtures
  dir as argument: 16/16 byte-identical round-trips, 16/16
  normalize-idempotent.
- Toolchain: valac 0.56.17 via micromamba, user-level env at
  `~/telephone-vala/env` on aletheia-core; build with
  `--pkg gio-2.0 --pkg posix`, run with
  `LD_LIBRARY_PATH=$HOME/telephone-vala/env/lib`.

Acceptance (EE 550): native suite green; fixtures 16/16; adapter
self-test PASS; one-shot verify vs `games/smoke-001/stress.phext`
PASS/30; game-scale on a snapshot copy of `games/test-001/stress.phext`:
init 0.11 s (< 30 s), validate 4.34 s (< 60 s), both pass.
