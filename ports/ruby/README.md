# libphext-ruby

A Ruby port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/phext.rb` — Coordinate (9 components, lexicographic order,
  `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize, fetch/insert/replace/
  remove, normalize, explode/implode. All buffers are `String` with
  `Encoding::BINARY`, so control bytes are never reinterpreted; the
  text layer uses latin-1 codepoints (byte == codepoint). Newline
  (0x0A) is ordinary scroll text, never a break.
- `src/cli.rb` — the telephone-game hub CLI (stdin/stdout JSON, state
  as base64), using only the Ruby stdlib (json, base64, digest). See
  its header for this port's choose rule.
- `test/test_phext.rb` — dependency-free suite:
  `ruby test/test_phext.rb [fixtures_dir]`.
