# libphext-j — J port

Status: **playing**. Jsoftware J 9.6.3 (official j9.6_linux64.tar.gz)
at `~/telephone-j/j` on aletheia-core; the adapter CLI runs via
`~/telephone-j/bin/run-telephone` (jconsole on the concatenated build).

Layout:

- `src/phext.ijs` — libphext core at 0.6.1 parity: buffer API
  (explode/implode/fetch/insert/replace/remove, remove is
  coordinate-preserving), DynamicPhext (CLRS quarter-full dynamic
  array), TransitivePhext (boxed trie, depth 9).
- `src/json.ijs` — minimal JSON parser + canonical serializer
  (Python `json.dumps(sort_keys=True, separators=(",",":"))` parity).
- `src/telephone.ijs` — contract-v2 adapter CLI: cmd wire protocol
  (id/echo/elect/choose/apply/keygen/attest/init/validate/verify),
  one-shot and serve modes, GZ1 framing for lines over 8 KB, PGP via
  subprocess gpg (GNUPGHOME `~/telephone-j/gnupg`, UID
  `libphext telephone j`, ed25519).
- `build.sh` — concatenates the parts into `build/telephone.ijs` and
  `build/test_phext.ijs` (J scripts have no module system here).
- `tests/test_phext.ijs` — suite: unit semantics, buffer/dynamic/
  transitive equivalence, dynamic counters, fixture round-trips.
- `adapter` — local Python wrapper (fleet-ssh relay, deferred init,
  GZ1 framing, raw-I/O seek).
- `tests/selftest_adapter.py` — adapter self-test.

J notes (hard-won): build multi-box structures with `,` of single
`<` boxes — the `;` link verb flattens boxed-array components.
Monadic verbs destructure `y`; mentioning `x` makes a `{{ }}`
definition dyad-only, and locals named `m`/`n`/`u`/`v` reclassify it
as an adverb/conjunction. `echo` truncates output at 256 chars per
line (9!:36), so responses are written raw to `/dev/stdout`. This
build's memory foreigns (15!:6/15!:7) are unusable; the serve loop
reads stdin in chunks via `dd` under `2!:0`, which is byte-exact.
String equality is `-:` (match); `~:` is element-wise. Boxed-list
membership is `(list i. <key) < #list`; `e.` is per-character.
