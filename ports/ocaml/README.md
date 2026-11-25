# libphext — OCaml port (Exocortical Stress Testing)

OCaml implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE #34.

- `src/phext.ml` — the library: coordinates as int array of 9,
  phokenize/dephokenize, fetch/insert/replace/remove (remove is
  coordinate-preserving: the scroll empties, later scrolls do not
  shift), normalize, explode/implode, plus DynamicPhext (dynamic array,
  double-on-full / shrink-at-quarter-full) and TransitivePhext
  (branching hash map, depth 9). Strings are bytes.
- `src/wire.ml` — SHA-256 (Int32 arithmetic; stdlib Digest is MD5
  only), base64, minimal JSON parser + canonical printer.
- `src/telephone.ml` — the telephone-game CLI (contract v2), compiled
  with ocamlopt to `~/telephone-ocaml/telephone` on the hub: id, echo,
  elect, choose (insert-only), apply, keygen, attest, validate
  (prior-state form and driver form against the serve cache set by
  `init`), init, verify. PGP via gpg subprocess, key home
  `~/telephone-ocaml/gnupg`.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub binary; `seek` runs locally by raw file I/O;
  serve-mode `state_path` is read locally and forwarded as base64.
- Tests on the hub: `sh tests/run_tests.sh`. Adapter self-test
  (local): `python3 tests/selftest_adapter.py`.

Toolchain: OCaml 4.14.1 (ocamlopt) on aletheia-core.
