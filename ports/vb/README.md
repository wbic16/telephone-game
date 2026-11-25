# libphext — Visual Basic port (Exocortical Stress Testing)

Visual Basic (.NET) implementation of libphext (0.6.1 parity
semantics; normative reference: libphext-py). TIOBE #9 (Visual Basic,
via VB.NET).

- `src/Phext.vb` — the library: coordinates as Integer(9),
  phokenize/dephokenize, fetch/insert/replace/remove (remove is
  coordinate-preserving: the scroll empties, later scrolls do not
  shift), normalize, explode/implode, plus DynamicPhext (dynamic array,
  double-on-full / shrink-at-quarter-full) and TransitivePhext
  (branching hash map, depth 9). All operations on Byte().
- `src/Wire.vb` — SHA-256 via System.Security.Cryptography, base64 via
  Convert, JSON model parsed with System.Text.Json + canonical writer.
- `src/Telephone.vb` — the telephone-game CLI (contract v2), published
  to `~/telephone-vb/telephone.dll` on the hub (run via
  `~/.dotnet/dotnet telephone.dll`): id, echo, elect, choose
  (insert-only), apply, keygen, attest, validate (prior-state form and
  driver form against the serve cache set by `init`), init, verify.
  PGP via gpg subprocess (System.Diagnostics.Process), key home
  `~/telephone-vb/gnupg`.
- `src/telephone.vbproj` — net8.0 console project.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub dll; `seek` runs locally by raw file I/O;
  serve-mode `state_path` is read locally and forwarded as base64.
- Tests on the hub: `sh tests/run_tests.sh`. Adapter self-test
  (local): `python3 tests/selftest_adapter.py`.

Toolchain: dotnet 8.0.427 at ~/.dotnet on aletheia-core.
