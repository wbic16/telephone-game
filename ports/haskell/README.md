# libphext — Haskell port (Exocortical Stress Testing)

Haskell implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE #39.

- `src/Phext.hs` — the library: coordinates as 9-tuples,
  phokenize/dephokenize, fetch/insert/replace/remove (remove is
  coordinate-preserving: the scroll empties, later scrolls do not
  shift), normalize, explode/implode (Data.Map), plus DynamicPhext
  (capacity-managed array store, double-on-full /
  shrink-at-quarter-full, with resize bookkeeping) and TransitivePhext
  (branching map, depth 9). Buffers are strict ByteStrings.
- `src/Wire.hs` — SHA-256 (pure Haskell, Data.Word32; the GHC boot
  libraries ship no SHA-256), base64, minimal JSON parser + canonical
  printer (sorted keys, compact separators, ensure_ascii escaping).
- `src/Main.hs` — the telephone-game CLI (contract v2), compiled with
  GHC to `~/telephone-haskell/telephone` on the hub: id, echo, elect,
  choose (insert-only), apply, keygen, attest, validate (prior-state
  form and driver form against the serve cache set by `init`), init,
  verify. PGP via gpg subprocess, key home `~/telephone-haskell/gnupg`.
  GZ1 gzip framing on serve lines over 8 KB (shells to gzip(1); the
  boot libraries have no zlib).
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub binary; `seek` runs locally by raw file I/O;
  serve-mode `state_path` is read locally and forwarded as base64,
  and serve `init` uses the deferred-cache pattern (exact bytes cached
  locally, flushed to the hub as a framed real init immediately
  before the first validate).
- Tests on the hub: `sh tests/run_tests.sh`. Adapter self-test
  (local): `python3 tests/selftest_adapter.py`.

Toolchain: GHCup user-level install on aletheia-core — GHC 9.6.6 +
cabal 3.10.3.0 in `~/.ghcup` (no sudo). Only GHC boot libraries are
used (base, bytestring, containers, directory, process).

Acceptance (2026-11-24): native suite PASS; fixtures 16/16
byte-identical round-trips; adapter self-test PASS; one-shot verify
vs games/smoke-001/stress.phext PASS / 30 placements; game-scale
rehearsal on a snapshot copy of games/test-001/stress.phext — serve
init 0.10 s (driver timeout 30 s), driver-form validate 5.58 s
(driver timeout 60 s), both PASS.
