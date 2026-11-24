# libphext — Go port (Exocortical Stress Testing)

Go implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE #10.

- `src/phext/phext.go` — the library: Coordinate (9 components,
  lexicographic order, `a.b.c/d.e.f/g.h.i`), phokenize/dephokenize,
  fetch/insert/replace/remove, normalize, explode/implode. Byte-level
  throughout; dimension breaks 0x01,0x1F,0x1E,0x1D,0x1C,0x1A,0x19,0x18,
  0x17; newline is ordinary text.
- `src/cmd/telephone/` — the telephone-game CLI (contract v2): one
  JSON request on stdin / one response out; `serve` argument loops
  over JSON lines. Commands: id, echo, elect, choose (insert-only at
  a verified-unused coordinate), apply, keygen, attest, validate,
  verify. PGP via gpg, key home `~/telephone-go/gnupg` on the hub.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub CLI (`~/telephone-go/telephone`); `seek` runs
  locally by raw file I/O.
- Tests on the hub: `cd ~/telephone-go/src && PHEXT_FIXTURES=<fixtures> ~/tools/go/bin/go test ./...`
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: Go 1.23.4, user-level install at `~/tools/go` on
aletheia-core (official tarball; no sudo).
