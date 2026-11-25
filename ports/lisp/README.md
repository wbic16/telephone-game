# libphext-lisp

A Common Lisp (SBCL) port of libphext, 0.6.1 parity with
libphext-py semantics. This port serves TIOBE's "Lisp" entry (#36);
the same SBCL toolchain is the named route for the band's Common
Lisp entry.

- `src/phext.lisp` — Coordinate (9 components as a list of integers,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (capacity-managed dynamic array: double when full,
  shrink only at quarter load, resize events instrumented) and
  TransitivePhext (BranchingMap: one hash map per coordinate
  dimension, 9 layers, leaves holding scroll text). All buffers are
  `(vector (unsigned-byte 8))`, so control bytes are never
  reinterpreted. Newline (0x0A) is ordinary scroll text, never a
  break. Remove is coordinate-preserving: the removed coordinate
  reads "" and neighbours do not shift.
- `src/cli.lisp` — the telephone-game hub CLI (stdin/stdout JSON
  lines, state as base64), serving the adapter hooks explode/
  implode/insert/fetch. JSON and Base64 are hand-written (the Lisp
  standard has neither); SHA-256 shells out to `sha256sum(1)`, as
  earlier waves did where the language lacks it.
- `tests/test_phext.lisp` — dependency-free suite:
  `sbcl --script tests/test_phext.lisp [fixtures_dir]`.
- Toolchain: SBCL, user-level on aletheia-core via micromamba
  (conda-forge) at `~/telephone-lisp/sbcl-env`.
