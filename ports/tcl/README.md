# libphext — Tcl port (Exocortical Stress Testing)

Tcl implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE 51–100 band.

- `src/phext.tcl` — the library: Coordinate (9 components,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  `phext::DynamicPhext` (dynamic array: capacity doubles when full,
  halves at quarter-full) and `phext::TransitivePhext` (branching
  hash map, one dict layer per dimension, depth 9) as TclOO classes.
  Byte-level throughout; dimension breaks 0x01,0x1F,0x1E,0x1D,0x1C,
  0x1A,0x19,0x18,0x17; newline is ordinary text. Remove is
  coordinate-preserving (later scrolls do not shift).
- `src/json.tcl` — pure-Tcl JSON parser + canonical serializer
  (sorted keys, Python ensure_ascii escaping, number literals kept
  verbatim so floats round-trip).
- `src/telephone.tcl` — the telephone-game CLI (contract v2): one
  JSON request on stdin / one response out; `serve` loops over JSON
  lines. Commands: id, echo, elect, choose (insert-only at a
  verified-unused coordinate), apply, keygen, attest, validate,
  init, verify. PGP via gpg, key home `~/telephone-tcl/gnupg` on the
  hub; sha256 via sha256sum (tcllib's sha2 is not installed; hashing
  is a crypto utility, not phext logic).
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub CLI (`tclsh ~/telephone-tcl/src/telephone.tcl`);
  `seek` runs locally by raw file I/O. The relay translates the
  driver's state_path/state_out_path forms to the base64 wire form.
- Tests on the hub: `PHEXT_FIXTURES=~/telephone-tcl/fixtures tclsh tests/test_phext.tcl`
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: tclsh 8.6.14, system install on aletheia-core.
