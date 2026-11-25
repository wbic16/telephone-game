# libphext-cobol

COBOL (GnuCOBOL) port of libphext, 0.6.1 parity, for the Exocortical
Telephone Game (contract v2). Semantics normative from libphext-py:
`src/phext.cpy` (COPY book) implements the buffer API over byte arenas
with a (coordinate, offset, length) scroll table, plus
`src/stores.cpy` with DynamicPhext (dynamic array, double on full /
shrink at quarter-full) and TransitivePhext (9-level branching map as
a node table). REMOVE is coordinate-preserving. `src/cli.cob` is the
hub-side CLI wrapping only this port's libphext: native Base64 codec
and targeted JSON extraction for the fixed wire schema; sha256sum for
SHA-256 (COBOL has none); PGP via subprocess gpg (GNUPGHOME
~/telephone-cobol/keys). Toolchain: GnuCOBOL 3.2 via micromamba
(conda-forge gnucobol) in ~/telephone-cobol/env on aletheia-core,
user-level only.
