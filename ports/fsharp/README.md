# libphext — F# port (Exocortical Stress Testing)

F# implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE 51–100 band.

- `src/lib/Phext.fs` — the library: Coordinate (9 components,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode, plus
  DynamicPhext (dynamic array: capacity doubles when full, halves
  at quarter-full) and TransitivePhext (branching hash map, one
  Dictionary layer per dimension, depth 9). Byte-level throughout;
  dimension breaks 0x01,0x1F,0x1E,0x1D,0x1C,0x1A,0x19,0x18,0x17;
  newline is ordinary text. Remove is coordinate-preserving
  (later scrolls do not shift).
- `src/cli/Program.fs` — the telephone-game CLI (contract v2):
  one JSON request on stdin / one response out; `serve` loops over
  JSON lines. Commands: id, echo, elect, choose (insert-only at a
  verified-unused coordinate), apply, keygen, attest, validate,
  init, verify. Canonical JSON is the port's own writer (sorted
  keys, Python ensure_ascii escaping, number literals kept
  verbatim). PGP via gpg, key home `~/telephone-fsharp/gnupg` on
  the hub.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub launcher (`~/telephone-fsharp/telephone`,
  a shell wrapper over the built Telephone.dll); `seek` runs
  locally by raw file I/O. The relay translates the driver's
  state_path/state_out_path forms to the base64 wire form.
- Tests on the hub: `PHEXT_FIXTURES=~/telephone-fsharp/fixtures ~/.dotnet/dotnet run --project tests/tests.fsproj -c Release`
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: dotnet 8.0.427 (F#), user-level install at `~/.dotnet`
on aletheia-core (official tarball; no sudo).
