# libphext — Awk port (Exocortical Stress Testing)

GNU Awk implementation of libphext (0.6.1 parity semantics;
normative reference: libphext-py). TIOBE 51–100 band.

- `src/phext.awk` — the library: Coordinate (9 components,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (`dyn_*`: capacity doubles when full, halves at
  quarter-full) and TransitivePhext (`trn_*`: branching hash map,
  one prefix level per dimension, depth 9). Byte-level throughout
  (LC_ALL=C); dimension breaks 0x01,0x1F,0x1E,0x1D,0x1C,0x1A,0x19,
  0x18,0x17; newline is ordinary text. Remove is
  coordinate-preserving (later scrolls do not shift).
- `src/json.awk` — pure-gawk JSON parser (node heap) + canonical
  serializer (sorted keys, Python ensure_ascii escaping, number
  literals kept verbatim so floats round-trip).
- `src/telephone.awk` — the telephone-game CLI (contract v2): one
  JSON request on stdin / one response out; `serve` loops over JSON
  lines. Commands: id, echo, elect, choose (insert-only at a
  verified-unused coordinate), apply, keygen, attest, validate,
  init, verify. PGP via gpg, key home `~/telephone-awk/gnupg` on the
  hub; sha256 via sha256sum; base64 implemented in awk.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub launcher (`~/telephone-awk/telephone`, which
  sets LC_ALL=C and runs gawk with the three sources); `seek` runs
  locally by raw file I/O. The relay translates the driver's
  state_path/state_out_path forms to the base64 wire form.
- Tests on the hub: `~/telephone-awk/tests/run_tests.sh`
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: GNU Awk 5.2.1, system install on aletheia-core.
