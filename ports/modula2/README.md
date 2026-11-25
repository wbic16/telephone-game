# libphext-modula2 — Modula-2 port

Status: **playing**. libphext 0.6.1 parity in Modula-2 (PIM
dialect) for GNU Modula-2 13.3.0, user-level on aletheia-core via
Ubuntu package extraction into `~/telephone-modula2/gm2deb`
(gm2-13-x86-64-linux-gnu + libgm2-13-dev + libgm2-18 runtime).
Run through `~/telephone-modula2/bin/run-telephone` (sets
LD_LIBRARY_PATH to the extracted runtime).

Layout: `src/BStr.def/.mod` (growable byte strings),
`src/Phext.def/.mod` (buffer API + DynamicPhext + TransitivePhext),
`src/Json.def/.mod` (JSON parser + canonical serializer),
`src/Telephone.mod` (telephone CLI), `tests/TestPhext.mod` (suite).
Build with `./build.sh` on the hub (it compiles the library modules
with `-c`, generates jmp-thunk aliases for gm2's unprefixed library
symbols, and links the program module one-shot — see build.sh).

Semantics: insert concatenates, replace overwrites, remove is
coordinate-preserving (replace "" + normalize; later scrolls do not
shift). sha256/base64/gzip via the standard CLI tools on temp
files; PGP via subprocess gpg with key home
`~/telephone-modula2/gnupg`.

Evidence (2026-11-24, aletheia-core): suite PASS (unit + store
equivalence + fixtures 16/16 byte-identical round-trips, 0.61 s);
adapter self-test PASS; smoke-001 verify PASS / 30 placements;
game-scale snapshot of live test-001 (1005 placements): init
0.06 s, choose 4.67 s, apply 3.86 s, validate 4.62 s PASS.
