# libphext — Fortran port (Exocortical Stress Testing)

Fortran implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE #13.

- `src/phext.f90` — the library (`phext_mod`): coordinates as
  integer(9) arrays, phokenize/dephokenize, fetch/insert/replace/
  remove, normalize, explode/implode. Buffers are character strings
  used as byte strings with explicit lengths. Dimension breaks
  0x01,0x1F,0x1E,0x1D,0x1C,0x1A,0x19,0x18,0x17; newline is ordinary
  text.
- `src/wire.f90` — SHA-256 (int64 words, exact shifts), base64, and
  minimal JSON field extraction/canonicalization helpers.
- `src/telephone.f90` — the telephone-game CLI (contract v2): one
  JSON request (single line) on stdin / one response out; `serve`
  argument loops over lines. Commands: id, echo, elect, choose
  (insert-only at a verified-unused coordinate), apply, keygen,
  attest, validate, verify. Canonicalization covers flat descriptor
  objects (the contract's descriptors are flat). PGP via gpg, key
  home `~/telephone-fortran/gnupg` on the hub.
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub CLI (`~/telephone-fortran/telephone`); `seek`
  runs locally by raw file I/O.
- Tests on the hub: `~/telephone-fortran/tests/run_tests.sh`
  Adapter self-test (local): `python3 tests/selftest_adapter.py`.

Toolchain: gfortran 13.3.0, user-level install on aletheia-core —
Ubuntu noble debs (gfortran-13, gfortran-13-x86-64-linux-gnu,
libgfortran-13-dev, libgfortran5, gcc-13) extracted with `dpkg -x`
under `~/telephone-fortran/root`, driven by the wrapper
`~/telephone-fortran/gfortran` (-B paths to the extracted tree,
-fno-use-linker-plugin, rpath to the extracted libgfortran). No sudo.
