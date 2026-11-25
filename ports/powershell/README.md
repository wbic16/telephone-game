# libphext-powershell

A PowerShell port of libphext, 0.6.1 parity with libphext-py
semantics.

- `src/Phext.ps1` — Coordinate (9 components as a [long[]],
  lexicographic order, `a.b.c/d.e.f/g.h.i`), Phokenize/Dephokenize,
  Fetch/Insert/Replace/Remove, Normalize, Explode/Implode, plus
  DynamicPhext (capacity-managed dynamic array: double when full,
  shrink only at quarter load, resize events instrumented) and
  TransitivePhext (BranchingMap: one hash map per coordinate
  dimension, 9 layers, leaves holding scroll text). Buffers cross
  the API as [byte[]]; internally the walk runs over a Latin1
  string (System.Text.Encoding.Latin1 is a byte<->char bijection),
  keeping the break search on native .NET string primitives.
  Newline (0x0A) is ordinary scroll text, never a break. Remove is
  coordinate-preserving: the removed coordinate reads "" and
  neighbours do not shift.
- `src/cli.ps1` — the telephone-game hub CLI (stdin/stdout JSON
  lines, state as base64, GZ1 wire framing over 8 KB), implementing
  the full contract-v2 game surface. SHA-256/base64/gzip are
  .NET's; JSON is hand-written (canonical form must match the
  harness exactly); PGP goes through subprocess gpg with a per-port
  GNUPGHOME.
- `tests/Test-Phext.ps1` — dependency-free suite, run with the
  fixtures dir as argument.
- Toolchain: PowerShell 7.4.6 official Linux tarball (user-level on
  aletheia-core at `~/telephone-powershell/`).
