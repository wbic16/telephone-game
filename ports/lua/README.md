# libphext — Lua port (Exocortical Stress Testing)

Lua implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE #32.

- `src/phext.lua` — the library: coordinates as 9-int tables,
  phokenize/dephokenize, fetch/insert/replace/remove (remove is
  coordinate-preserving: the scroll empties, later scrolls do not
  shift), normalize, explode/implode, plus DynamicPhext (dynamic array,
  double-on-full / shrink-at-quarter-full) and TransitivePhext
  (branching hash map, depth 9). Byte strings throughout.
- `src/wire.lua` — pure-Lua SHA-256 (byte-table bitwise ops, Lua 5.1
  compatible), base64, JSON, canonical JSON.
- `src/telephone.lua` — the telephone-game CLI (contract v2): id, echo,
  elect, choose (insert-only), apply, keygen, attest, validate (both
  prior-state form and driver form against the serve cache set by
  `init`), init, verify. PGP via gpg subprocess, key home
  `~/telephone-lua/gnupg` on the hub.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub CLI; `seek` runs locally by raw file I/O;
  serve-mode `state_path` is read locally and forwarded as base64.
- Tests on the hub: `cd ~/telephone-lua && PHEXT_FIXTURES=<fixtures> lua tests/test_phext.lua`
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: Lua 5.1.5 (system) on aletheia-core.
