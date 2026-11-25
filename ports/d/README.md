# libphext-d

A D port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/phext.d` — Coordinate (9 components, lexicographic order,
  `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize, fetch/insert/replace/
  remove, normalize, explode/implode, plus DynamicPhext (capacity-
  managed dynamic array: double when full, shrink only at quarter
  load, resize events instrumented) and TransitivePhext (BranchingMap:
  one hash map per coordinate dimension, 9 layers, leaves holding
  scroll text). All buffers are `ubyte[]`, so control bytes are never
  reinterpreted. Newline (0x0A) is ordinary scroll text, never a
  break. Remove is coordinate-preserving: the removed coordinate
  reads "" and neighbours do not shift.
- `src/cli.d` — the telephone-game hub CLI (stdin/stdout JSON lines,
  state as base64), serving the adapter hooks explode/implode/insert/
  fetch. JSON, Base64 and SHA-256 are D stdlib (std.json, std.base64,
  std.digest.sha).
- `tests/test_phext.d` — dependency-free suite:
  build with the port compiler and run `./test_phext [fixtures_dir]`.
- Toolchain: LDC (official tarball), user-level on aletheia-core at
  `~/telephone-d/`.
