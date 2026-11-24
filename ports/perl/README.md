# libphext — Perl port (Exocortical Stress Testing)

Perl implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE #15.

- `src/Phext.pm` — the library: coordinates as 9-int arrayrefs,
  phokenize/dephokenize, fetch/insert/replace/remove, normalize,
  explode/implode, all on byte strings. Dimension breaks 0x01,0x1F,
  0x1E,0x1D,0x1C,0x1A,0x19,0x18,0x17; newline is ordinary text. Core
  modules only (JSON::PP, Digest::SHA, MIME::Base64 for the CLI).
- `src/telephone.pl` — the telephone-game CLI (contract v2): one JSON
  request on stdin / one response out; `serve` argument loops over
  JSON lines (stdout autoflush is load-bearing there). Commands: id,
  echo, elect, choose (insert-only at a verified-unused coordinate),
  apply, keygen, attest, validate, verify. PGP via gpg, key home
  `~/telephone-perl/gnupg` on the hub.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub CLI; `seek` runs locally by raw file I/O.
- Tests on the hub: `cd ~/telephone-perl && PHEXT_FIXTURES=<fixtures> perl tests/test_phext.pl`
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: Perl 5.38.2 (system) on aletheia-core.
