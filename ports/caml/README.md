# libphext — Caml port (Exocortical Stress Testing)

Caml implementation of libphext (0.6.1 parity semantics; normative
reference: libphext-py). TIOBE #40. Per TOP100.md, the Caml lineage
toolchain is OCaml 4.14.1 (Caml Light itself is legacy); this port is
a DISTINCT implementation from ports/ocaml, written in the Caml
idiom, not a copy: coordinates are records, the scroll store is a
functorised `Map.Make` over a coordinate ordering module, the walker
is a tail-recursive byte fold, and the telephone CLI has its own
choose/elect rules (hash-stride successor walk / deterministic
hash rotation).

- `src/phext_caml.ml` — the library: phokenize/dephokenize,
  fetch/insert/replace/remove (remove is coordinate-preserving: the
  scroll empties, later scrolls do not shift), normalize,
  explode/implode over ScrollMap, plus DynamicPhext (capacity-managed
  array, double-on-full / shrink-at-quarter-full) and TransitivePhext
  (branching hash map, depth 9). Strings are bytes.
- `src/wire_caml.ml` — SHA-256 (Int32 arithmetic, written from
  FIPS 180-4; stdlib Digest is MD5 only), base64, minimal JSON parser
  (scanner record) + canonical printer.
- `src/telephone_caml.ml` — the telephone-game CLI (contract v2),
  compiled with ocamlopt to `~/telephone-caml/telephone` on the hub:
  id, echo, elect, choose (insert-only), apply, keygen, attest,
  validate (prior-state form and driver form against the serve cache
  set by `init`), init, verify. PGP via gpg subprocess, key home
  `~/telephone-caml/gnupg`. GZ1 gzip framing on serve lines over
  8 KB (shells to gzip(1)).
- `adapter` — local python3 wrapper speaking the contract over
  fleet-ssh to the hub binary; `seek` runs locally by raw file I/O;
  serve-mode `state_path` is read locally and forwarded as base64,
  and serve `init` uses the deferred-cache pattern (exact bytes
  cached locally, flushed to the hub as a framed real init
  immediately before the first validate).
- Tests on the hub: `sh tests/run_tests.sh`. Adapter self-test
  (local): `python3 tests/selftest_adapter.py`.

Toolchain: OCaml 4.14.1 (ocamlopt) on aletheia-core — already present
as the Caml lineage toolchain; nothing installed.

Acceptance (2026-11-24): native suite PASS; fixtures 16/16
byte-identical round-trips; adapter self-test PASS; one-shot verify
vs games/smoke-001/stress.phext PASS / 30 placements; game-scale
rehearsal on a snapshot copy of games/test-001/stress.phext — serve
init 0.12 s (driver timeout 30 s), driver-form validate 4.29 s
(driver timeout 60 s), both PASS.
