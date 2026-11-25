# libphext — Bash port (Exocortical Stress Testing)

Bash implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE 51–100 band.

- `src/phext.sh` — the library: Coordinate (9 components,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (`dyn_*`: capacity doubles when full, halves at
  quarter-full) and TransitivePhext (`trn_*`: branching hash map
  over assoc arrays, one prefix level per dimension, depth 9).
  Byte-level throughout (LC_ALL=C, set by the hub launcher);
  dimension breaks 0x01,0x1F,0x1E,0x1D,0x1C,0x1A,0x19,0x18,0x17;
  newline is ordinary text. Remove is coordinate-preserving
  (later scrolls do not shift). Byte strings are returned through
  globals, never stdout (command substitution strips trailing
  newlines, and newline is scroll text). phokenize escapes a
  sentinel byte and encodes breaks as sentinel+digit so the split
  runs at C speed; dephokenize joins pieces in one expansion;
  coordinate sorts use fixed-width padded keys through `sort`.
- `src/json.sh` — pure-bash JSON parser (node heap in assoc
  arrays) + canonical serializer (sorted keys, Python ensure_ascii
  escaping, number literals kept verbatim so floats round-trip).
- `src/telephone.sh` — the telephone-game CLI (contract v2): one
  JSON request on stdin / one response out; `serve` loops over
  JSON lines. Commands: id, echo, elect, choose (insert-only at a
  verified-unused coordinate), apply, keygen, attest, validate,
  init, verify. PGP via gpg, key home `~/telephone-bash/gnupg` on
  the hub; sha256/base64 via coreutils subprocesses.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub launcher (`~/telephone-bash/telephone`);
  `seek` runs locally by raw file I/O. The relay translates the
  driver's state_path/state_out_path forms to the base64 wire form.
- Tests on the hub: `~/telephone-bash/tests/run_tests.sh`
  (allow ~2 minutes — the 9.4 MB real-corpora fixture is
  substitution-bound in pure bash).
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: bash 5.2.21, system install on aletheia-core.
