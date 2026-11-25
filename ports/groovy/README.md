# libphext-groovy

A Groovy port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/Phext.groovy` — Coord (9 longs, lexicographic order,
  `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize, fetch/insert/
  replace/remove, normalize, explode/implode, plus DynamicPhext
  (capacity-managed dynamic array: double when full, shrink only at
  quarter load, resize events instrumented) and TransitivePhext
  (BranchingMap: one hash map per coordinate dimension, 9 layers,
  leaves holding scroll text). All buffers are byte[], so control
  bytes are never reinterpreted. Newline (0x0A) is ordinary scroll
  text, never a break. Remove is coordinate-preserving: the removed
  coordinate reads "" and neighbours do not shift.
- `src/Cli.groovy` — the telephone-game hub CLI (stdin/stdout JSON
  lines, state as base64, GZ1 wire framing over 8 KB), implementing
  the full contract-v2 game surface. Base64 and SHA-256 are the
  JDK's; JSON is hand-written; PGP goes through subprocess gpg with
  a per-port GNUPGHOME.
- `tests/TestPhext.groovy` — dependency-free suite, run as
  `phext.TestPhext [fixtures_dir]` on the compiled classes.
- Toolchain: Apache Groovy 4.0.24 binary zip (user-level on
  aletheia-core at `~/telephone-groovy/`) on the hub's OpenJDK 21;
  compiled with groovyc, run on the JVM.
