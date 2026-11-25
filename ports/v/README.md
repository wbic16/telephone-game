# libphext-v

A V port of libphext, 0.6.1 parity with libphext-py semantics.

- `src/phext.v` — Coordinate (9 components as `[9]i64`, lexicographic
  order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (capacity-managed dynamic array) and TransitivePhext
  (string-keyed map). All buffers are `[]u8`, so control bytes are
  never reinterpreted. Newline (0x0A) is ordinary scroll text, never
  a break. Remove is coordinate-preserving: the removed coordinate
  reads "" and neighbours do not shift.
- `src/cli.v` — the telephone-game hub CLI (stdin/stdout JSON lines,
  state as base64, GZ1 wire framing over 8 KB), implementing the full
  contract-v2 game surface. JSON is hand-written (canonical form must
  match the harness exactly); SHA-256 is `crypto.sha256`, base64 is
  `encoding.base64`, gzip is `compress.gzip`; PGP goes through
  subprocess gpg with a per-port GNUPGHOME (`~/telephone-v/gnupg`).
  Build is directory-based (`v` rejects multiple file targets with
  `-o`): `hub/build.sh` copies sources into `.build-cli/` /
  `.build-test/` and builds with `-cc gcc -enable-globals`.
- `tests/` — dependency-free suite (81 checks), run with the fixtures
  dir as argument: 16/16 byte-identical round-trips, 16/16
  normalize-idempotent.
- Toolchain: V 0.4.9 (weekly build 6623ac2), official download,
  user-level on aletheia-core at `~/telephone-v/v` (the zip loses
  exec bits; `chmod +x` on `v/v` and `thirdparty/tcc/*`).

Acceptance (EE 550): native suite green; fixtures 16/16; adapter
self-test PASS; one-shot verify vs `games/smoke-001/stress.phext`
PASS/30; game-scale on a snapshot copy of `games/test-001/stress.phext`:
init 0.09 s (< 30 s), validate 4.13 s (< 60 s), both pass.
