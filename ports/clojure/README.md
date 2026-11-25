# libphext-clojure

A Clojure port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/phext.clj` — Coordinate (9 components as a vector of longs,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (capacity-managed dynamic array: double when full,
  shrink only at quarter load, resize events instrumented) and
  TransitivePhext (BranchingMap: one hash map per coordinate
  dimension, 9 layers, leaves holding scroll text). All buffers are
  byte arrays, so control bytes are never reinterpreted. Newline
  (0x0A) is ordinary scroll text, never a break. Remove is
  coordinate-preserving: the removed coordinate reads "" and
  neighbours do not shift.
- `src/cli.clj` — the telephone-game hub CLI (stdin/stdout JSON
  lines, state as base64, GZ1 wire framing over 8 KB), implementing
  the full contract-v2 game surface (id/keygen/echo/elect/choose/
  apply/attest/init/validate/verify). Base64 and SHA-256 are the
  JDK's (java.util.Base64, java.security.MessageDigest); JSON is
  hand-written (no third-party deps); PGP goes through subprocess
  gpg with a per-port GNUPGHOME.
- `tests/test.clj` — dependency-free suite, run as
  `telephone.test [fixtures_dir]` on the port classpath.
- Toolchain: Clojure CLI tools 1.12.3.1577 (user-level on
  aletheia-core at `~/telephone-clojure/`) on the hub's OpenJDK 21.
