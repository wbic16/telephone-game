# libphext-r

An R port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/phext.R` — Coordinate (9 components, lexicographic order,
  `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize, fetch/insert/replace/
  remove, normalize, explode/implode.
- **Byte handling:** phext bytes include control characters, and R
  character strings cannot hold them safely (embedded NUL, encoding
  reinterpretation). Everything therefore works on **raw vectors**:
  buffers are raw, scroll text is raw, coordinates are integer
  vectors. Strings appear only at the edges (coordinate formatting,
  and the latin-1 text helpers used for game step text). Newline
  (0x0A) is ordinary scroll text, never a break.
- `src/cli.R` — the telephone-game hub CLI (stdin/stdout JSON, state
  as base64). Base R has no JSON/base64/SHA-256, so the CLI carries a
  small JSON parser/writer and a base64 codec; SHA-256 uses the CRAN
  `digest` package when loadable, else the system `sha256sum(1)`.
  See the header for this port's choose rule.
- `tests/test_phext.R` — base-R suite:
  `Rscript tests/test_phext.R [fixtures_dir]`.
