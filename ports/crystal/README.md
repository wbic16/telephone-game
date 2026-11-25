# libphext-crystal

A Crystal port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/phext.cr` — Coordinate (9 components as an Array(Int64),
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (capacity-managed dynamic array: double when full,
  shrink only at quarter load, resize events instrumented) and
  TransitivePhext (BranchingMap: one hash map per coordinate
  dimension, 9 layers, leaves holding scroll text). All buffers are
  Bytes (Slice(UInt8)), so control bytes are never reinterpreted.
  Newline (0x0A) is ordinary scroll text, never a break. Remove is
  coordinate-preserving: the removed coordinate reads "" and
  neighbours do not shift.
- `src/cli.cr` — the telephone-game hub CLI (stdin/stdout JSON
  lines, state as base64, GZ1 wire framing over 8 KB), implementing
  the full contract-v2 game surface. SHA-256/base64/gzip are the
  Crystal standard library's; JSON is hand-written (canonical form
  must match the harness exactly); PGP goes through subprocess gpg
  with a per-port GNUPGHOME.
- `tests/test_phext.cr` — dependency-free suite, compiled and run
  with the fixtures dir as argument.
- Toolchain: Crystal official tarball (user-level on aletheia-core
  at `~/telephone-crystal/`).
