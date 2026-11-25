# libphext-rexx — REXX port

Status: **playing**. libphext 0.6.1 parity in classic REXX for
Regina REXX 3.9.5 (user-level on aletheia-core via Ubuntu package
extraction into `~/telephone-rexx/regina`; run through
`~/telephone-rexx/bin/run-telephone`, which sets LD_LIBRARY_PATH).

Layout: `src/phext.rexx` (buffer API + DynamicPhext + TransitivePhext
part-file), `src/json.rexx` (JSON parser + canonical serializer
part-file), `src/telephone-main.rexx` + `src/telephone-main2.rexx`
(telephone CLI main parts), `src/test-main.rexx` (test main part).
Classic REXX has no modules, so programs are built by concatenation
(main first, routines after): `./build.sh` produces
`src/telephone.rexx` and `tests/test_phext.rexx`.

Semantics: insert concatenates, replace overwrites, remove is
coordinate-preserving (replace "" + normalize; later scrolls do not
shift). sha256/base64/gzip via the standard CLI tools on temp files;
PGP via subprocess gpg with key home `~/telephone-rexx/gnupg`.

Evidence (2026-11-24, aletheia-core): suite PASS (unit + store
equivalence + fixtures 16/16 byte-identical round-trips); adapter
self-test PASS; smoke-001 verify PASS / 30 placements; game-scale
snapshot of live test-001 (1004 placements): init 0.06 s, choose
10.01 s, apply 11.45 s, validate 20.19 s PASS.
