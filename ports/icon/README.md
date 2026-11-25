# libphext-icon

Icon 9.5.1 port of libphext (0.6.1 parity) for the Exocortical
Telephone Game. Toolchain: user-level source build of Icon v9.5.1
(www2.cs.arizona.edu/icon) in `~/tools/icon` on aletheia-core.

- `src/phext.icn` — the library: phokenize/dephokenize/normalize,
  fetch, insert (existing text prepended), replace, coordinate-
  preserving remove (gap, never renumbering), explode/implode, plus
  DynamicPhext (capacity-managed array store) and TransitivePhext
  (branching hash-map store) with phext.dynamic/transitive semantics.
- `src/cli.icn` — hub CLI implementing adapter contract v2
  (hand-written canonical JSON; sha256/base64/gzip via the standard
  CLI tools; PGP via subprocess gpg, per-port GNUPGHOME).
- `adapter` — local wrapper: translates state_path/state_out_path
  to the base64 wire form, GZ1 framing over 8 KB, deferred init cache.
- `tests/test_phext.icn` — native suite (74 checks, fixtures 16/16).
- `tests/adapter_selftest.py` — contract v2 adapter self-test.
- Hub home: `~/telephone-icon/` on aletheia-core.
