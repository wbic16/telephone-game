# libphext — Io port (Exocortical Telephone, wave 6a)

Io 2017.09.06, user-level source build in `~/tools/dl/io-src`
on aletheia-core (core targets only; addons not built). Status:
**playing** (all gates green 2026-11-24; see registration.json).

## Layout

- `src/phext.io` — libphext 0.6.1 parity: phokenize,
  dephokenize (own bottom-up merge sort over precomputed
  coordinate keys), normalize, fetch, insert/replace/remove
  (remove is coordinate-preserving), DynamicPhext
  (capacity-managed), TransitivePhext (snapshot-persistent).
- `src/cli.io` — adapter contract v2: hand-written canonical
  JSON (JVal objects), echo/elect/choose/apply/attest/keygen/
  init/validate/verify mirroring harness/adapter_base.py;
  sha256/gzip via the standard CLI tools over temp files;
  base64 via Sequence `asBase64`/`fromBase64`; PGP via
  subprocess gpg with per-port GNUPGHOME `~/telephone-io/gnupg`.
- `hub/build.sh` — installs `~/telephone-io/run.sh` (cds to
  the port dir so `doFile("src/phext.io")` resolves).
- `adapter` — local python3 wrapper (fleet-ssh relay, GZ1
  framing over 8 KB, deferred serve init, state_path ↔ base64
  translation), same pattern as the wave-4/5 ports.
- `tests/` — native suite (48 checks + 16 fixtures),
  adapter self-test.

## Io quirks found empirically (all worked around)

- `List sortBy` takes a **boolean** less-than predicate, not
  -1/0/1 — and degrades to O(n²) on already-sorted input
  (naive pivot). dephokenize/TransitivePhext use an explicit
  merge sort over decorated [key, entry] pairs.
- `Map atPut` requires Sequence keys in this build — maps are
  keyed by strings only; per-byte tables are Lists.
- `Sequence setSize` fills with nil, not the given value.
- `try(...)` returns nil on success and the Exception object
  on failure; the protected value is captured by assignment.
- No `File openForWriting` — `openForUpdating` is used for
  (unique-named) temp files.
- String literals have no `\xHH` escape (a backslash before an
  ordinary char yields the char); byte strings are built with
  `Sequence append(byte)`.
- `Directory directories` does not mean what it says here;
  the suite takes its fixture list from the driver instead.
