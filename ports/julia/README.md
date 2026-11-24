# libphext-julia

A Julia port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/Phext.jl` — Coordinate (9 components, lexicographic order,
  `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize, fetch/insert/replace/
  remove, normalize, explode/implode. Byte work is on `Vector{UInt8}`;
  the string layer uses latin-1 codepoints (byte == codepoint), and
  newline (0x0A) is ordinary scroll text, never a break.
- `src/cli.jl` — the telephone-game hub CLI (stdin/stdout JSON, state
  as base64). SHA/Base64/Tar come from the Julia stdlib; JSON is a
  small built-in parser/writer (JSON.jl is not a stdlib), so the port
  has no external package dependencies. See the header for this port's
  choose rule.
- `test/runtests.jl` — suite (stdlib Test):
  `julia test/runtests.jl [fixtures_dir]`.
