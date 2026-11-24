# libphext — PHP port (Exocortical Stress Testing)

PHP implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE #12.

- `src/phext.php` — the library (static class `Phext`): coordinates as
  9-int arrays, phokenize/dephokenize, fetch/insert/replace/remove,
  normalize, explode/implode. PHP strings are byte strings; all
  operations are byte-level. Dimension breaks 0x01,0x1F,0x1E,0x1D,
  0x1C,0x1A,0x19,0x18,0x17; newline is ordinary text.
- `src/telephone.php` — the telephone-game CLI (contract v2): one
  JSON request on stdin / one response out; `serve` argument loops
  over JSON lines. Commands: id, echo, elect, choose (insert-only at
  a verified-unused coordinate), apply, keygen, attest, validate,
  verify. PGP via gpg, key home `~/telephone-php/gnupg` on the hub.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub CLI; `seek` runs locally by raw file I/O.
- Tests on the hub: `cd ~/telephone-php && PHEXT_FIXTURES=<fixtures> php tests/test_phext.php`
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: PHP 8.3.6 (system) on aletheia-core.
