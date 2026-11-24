# libphext-dart

A Dart port of libphext, 0.6.1 parity with libphext-py semantics.

- `lib/phext.dart` — Coordinate (9 components, lexicographic order,
  `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize, fetch/insert/replace/
  remove, normalize, explode/implode, and a pure-Dart SHA-256.
- Byte handling: everything is `Uint8List`. Scroll text is raw bytes;
  the string convenience layer uses latin-1 (byte == codepoint) so no
  byte can be corrupted by text handling. Newline (0x0A) is ordinary
  scroll text, never a break.
- `bin/phext_cli.dart` — the telephone-game hub CLI (stdin/stdout JSON,
  state as base64). See its header for this port's choose rule.
- `test/phext_test.dart` — dependency-free test suite:
  `dart run test/phext_test.dart [fixtures_dir]`.
