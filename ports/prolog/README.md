# libphext-prolog

A SWI-Prolog port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/phext.pl` — Coordinate (9 components as a list of integers,
  lexicographic order = standard term order, `a.b.c/d.e.f/g.h.i`),
  phokenize/dephokenize, fetch/insert/replace/remove, normalize,
  explode/implode (rb-tree map form), plus DynamicPhext (capacity-
  managed dynamic array over a mutable `slots/N` compound: double when
  full, shrink only at quarter load) and TransitivePhext (BranchingMap:
  one rb-tree hash map per coordinate dimension, 9 layers, leaves
  holding scroll text). Buffers and scroll text are lists of byte
  codes, so control bytes are never reinterpreted. Newline (0x0A) is
  ordinary scroll text, never a break. Remove is coordinate-
  preserving: the removed coordinate reads "" and neighbours do not
  shift.
- `src/cli.pl` — the telephone-game hub CLI (stdin/stdout JSON lines,
  state as base64), serving the adapter hooks explode/implode/insert/
  fetch using SWI built-ins only (library(http/json),
  library(base64), library(sha)).
- `tests/test_phext.pl` — dependency-free suite:
  `swipl --stack_limit=4g -q -s tests/test_phext.pl -g main -- [fixtures_dir]`
  (the 9.4 MB real-corpora fixture needs the raised stack limit:
  several live copies of a 9.35 M-cell code list approach SWI's
  default 1 GB stack).
- Toolchain: SWI-Prolog 10.0.0, user-level on aletheia-core via
  micromamba (conda-forge) at `~/telephone-prolog/swi-env`.
