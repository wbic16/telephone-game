# libphext — ML port (Exocortical Stress Testing)

Standard ML implementation of libphext (0.6.1 parity semantics;
normative reference: libphext-py). TIOBE #43.

- `src/phext.sml` — the library: coordinates as int lists of 9,
  phokenize/dephokenize, fetch/insert/replace/remove (remove is
  coordinate-preserving: the scroll empties, later scrolls do not
  shift), normalize, explode/implode over a hand-rolled hash table
  (the Basis Library has no Map structure), plus DynamicPhext
  (capacity-managed array, double-on-full / shrink-at-quarter-full)
  and TransitivePhext (branching map, depth 9). Strings are bytes.
- `src/wire.sml` — SHA-256 (Word32 arithmetic, from FIPS 180-4; the
  Basis has no SHA-256), base64, minimal JSON parser + canonical
  printer (sorted keys, compact separators, ensure_ascii escaping).
- `src/telephone.sml` — the telephone-game CLI (contract v2),
  compiled with MLton to `~/telephone-ml/telephone` on the hub: id,
  echo, elect, choose (insert-only), apply, keygen, attest, validate
  (prior-state form and driver form against the serve cache set by
  `init`), init, verify. PGP via gpg subprocess, key home
  `~/telephone-ml/gnupg`. GZ1 gzip framing on serve lines over 8 KB
  (shells to gzip(1); the Basis has no zlib).
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub binary; `seek` runs locally by raw file I/O;
  serve-mode `state_path` is read locally and forwarded as base64,
  and serve `init` uses the deferred-cache pattern (exact bytes
  cached locally, flushed to the hub as a framed real init
  immediately before the first validate).
- Tests on the hub: `sh tests/run_tests.sh`. Adapter self-test
  (local): `python3 tests/selftest_adapter.py`.

Toolchain: MLton 20241230, user-level official tarball in
`~/tools/mlton` on aletheia-core (Ubuntu 24.04 glibc2.39 build; no
sudo). Basis Library only.

Acceptance (2026-11-24): native suite PASS; fixtures 16/16
byte-identical round-trips; adapter self-test PASS; one-shot verify
vs games/smoke-001/stress.phext PASS / 30 placements; game-scale
rehearsal on a snapshot copy of games/test-001/stress.phext — serve
init 0.12 s (driver timeout 30 s), driver-form validate 5.20 s
(driver timeout 60 s), both PASS.
