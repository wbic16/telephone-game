# libphext — Nim port (Exocortical Stress Testing)

Nim implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE 51–100 band.

- `src/phext.nim` — the library: coordinates as array[9, int],
  phokenize/dephokenize, fetch/insert/replace/remove (remove is
  coordinate-preserving: the scroll empties, later scrolls do not
  shift), normalize, explode/implode, plus DynamicPhext (dynamic array,
  double-on-full / shrink-at-quarter-full) and TransitivePhext
  (branching hash map, depth 9).
- `src/wire.nim` — SHA-256 (hand-written; the Nim stdlib ships SHA-1
  only) and canonical JSON over std/json.
- `src/telephone.nim` — the telephone-game CLI (contract v2), compiled
  to `~/telephone-nim/telephone` on the hub: id, echo, elect, choose
  (insert-only), apply, keygen, attest, validate (prior-state form and
  driver form against the serve cache set by `init`), init, verify.
  PGP via gpg subprocess (osproc), key home `~/telephone-nim/gnupg`.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub binary; `seek` runs locally by raw file I/O;
  serve-mode `state_path` is read locally and forwarded as base64.
- Tests on the hub: `sh tests/run_tests.sh` (compiles and runs
  tests/test_phext.nim with PHEXT_FIXTURES=~/telephone-nim/fixtures).
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: Nim 2.4.2 at ~/.nimble/bin on aletheia-core.
