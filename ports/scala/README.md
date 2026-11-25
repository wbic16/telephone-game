# libphext-scala

A Scala 3 port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/Phext.scala` — Coordinate (9 components as a `Vector[Int]`,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (capacity-managed dynamic array: double when full,
  shrink only at quarter load, resize events instrumented) and
  TransitivePhext (BranchingMap: one hash map per coordinate
  dimension, 9 layers, leaves holding scroll text). All buffers are
  `Array[Byte]`, so control bytes are never reinterpreted. Newline
  (0x0A) is ordinary scroll text, never a break. Remove is
  coordinate-preserving: the removed coordinate reads "" and
  neighbours do not shift.
- `src/Cli.scala` — the telephone-game hub CLI (stdin/stdout JSON
  lines, state as base64), serving the adapter hooks explode/
  implode/insert/fetch. Base64 and SHA-256 are the JDK's
  (java.util.Base64, java.security.MessageDigest); JSON is
  hand-written (the Scala standard library has none).
- `tests/TestPhext.scala` — dependency-free suite, run as
  `phext.TestPhext [fixtures_dir]` on the compiled classes.
- Toolchain: Scala 3.5.2 distribution (user-level on aletheia-core
  at `~/telephone-scala/`) on the hub's OpenJDK 21.
