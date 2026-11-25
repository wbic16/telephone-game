# libphext-spark

A SPARK/Ada port of libphext, 0.6.1 parity with libphext-py semantics.
Distinct from `ports/ada`: the phext core here is written in the SPARK
subset (`SPARK_Mode => On`).

- `src/phext.ads` / `src/phext.adb` — the SPARK core: Coordinate
  (9 components, lexicographic order, `a.b.c/d.e.f/g.h.i`),
  phokenize/dephokenize, fetch/insert/replace/remove, normalize,
  explode/implode, plus DynamicPhext (over `Ada.Containers.Vectors`
  with explicit capacity discipline; no access types) and
  TransitivePhext (hashed map keyed by coordinate, FNV-1a hash).
  Buffers are byte strings, so control bytes are never reinterpreted.
  Newline (0x0A) is ordinary scroll text, never a break. Remove is
  coordinate-preserving: the removed coordinate reads "" and
  neighbours do not shift.
- `src/wire.ads` / `src/wire.adb`, `src/cli.adb` — the telephone-game
  hub CLI (stdin/stdout JSON lines, state as base64, GZ1 wire framing
  over 8 KB), implementing the full contract-v2 game surface, adapted
  from the Ada port. SHA-256/base64 via the standard CLI tools where
  Ada lacks them; PGP goes through subprocess gpg with a per-port
  GNUPGHOME (`~/telephone-spark/gnupg`).
- `tests/` — dependency-free suite (41 checks), run with the fixtures
  dir as argument: 16/16 byte-identical round-trips, 16/16
  normalize-idempotent.
- Toolchain: GNAT 14.2.0 from the Alire install the Ada port made
  (`~/telephone-ada/env` on aletheia-core), user-level. No `gnatprove`
  binary is present in that env (probed EE 550), so the SPARK evidence
  is `SPARK_Mode` compilation, not a proof run.

Acceptance (EE 550): native suite green; fixtures 16/16; adapter
self-test PASS; one-shot verify vs `games/smoke-001/stress.phext`
PASS/30; game-scale on a snapshot copy of `games/test-001/stress.phext`:
init 11.88 s (< 30 s), validate 8.22 s (< 60 s), both pass.
