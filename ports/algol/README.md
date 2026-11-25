# libphext — Algol 68 port (Exocortical Telephone, wave 6a)

Algol 68 Genie (a68g) 3.14.0, user-level source build in
`~/tools/a68g` on aletheia-core. Status: **playing** (all gates
green 2026-11-24; see registration.json for the evidence).

## Layout

- `src/phext.decl.a68` — libphext 0.6.1 parity: phokenize
  (two-pass, exact-size rows), dephokenize (merge sort),
  normalize, fetch, insert/replace/remove (remove is
  coordinate-preserving), DynamicPhext (capacity-managed),
  TransitivePhext (sorted scroll-list store).
- `src/b64.decl.a68` — hand-written base64; sha256/gzip/gunzip
  via the standard CLI tools over base64 text files.
- `src/json.decl.a68` — canonical JSON (index-based nodes;
  sorted keys, `(",", ":")` separators), parser with a slice
  fast path for escape-free strings.
- `src/game.decl.a68` — adapter contract v2 logic (echo, elect,
  choose, apply, attest, keygen, init, validate, verify),
  mirroring harness/adapter_base.py; PGP via subprocess gpg
  with per-port GNUPGHOME `~/telephone-algol/gnupg`.
- `src/cli-serve.main.a68`, `src/cli-oneshot.main.a68` — entry
  points; `hub/build.sh` assembles the programs (a68g takes no
  extra source args, so fragments are concatenated between
  BEGIN/END) and installs `~/telephone-algol/run.sh`.
- `adapter` — local python3 wrapper (fleet-ssh relay, GZ1
  framing over 8 KB, deferred serve init, state_path ↔ base64
  translation), same pattern as the wave-4/5 ports.
- `tests/` — native suite (74 checks + 16 fixtures),
  adapter self-test.

## Why files carry ASCII only

a68g's text transput is not byte-safe (bytes are UTF-8-decoded
on text `get`; disk channels report `bin possible = F`), so
every file this port touches holds ASCII: JSON, base64, PGP
armor, hex. Phext bytes live only in in-memory STRINGs and
cross process boundaries as base64, produced/consumed by the
standard CLI tools where the language lacks them (the contract
permits this; prior waves did the same).

## a68g 3.14 quirks found empirically (all worked around)

- `IS NIL` / `ISNT NIL` are unreliable (a name set to NIL does
  not test IS NIL; identity of REF values is inconsistent
  across proc boundaries). No REF linked structures anywhere:
  stores are index/row based (SLT rows, JSON node indices).
- `AND`/`OR` evaluate both operands — guards with side effects
  or index risk are nested, never compounded.
- `STRING +:=` copies the whole string — per-char accumulation
  is quadratic. Hot paths use pre-sized buffers with index
  assignment, chunk flushing, and pairwise joins.
- Insertion sort is quadratic on adversarial key orders —
  dephokenize and the JSON writer merge-sort.
- Comments are `# ... #` (enclosed); a lone `#` line swallows
  code. Field tags shadow same-named parameters — parameters
  avoid field names.
- File-end handlers: returning TRUE retries the read forever
  on unterminated final lines; every file the reader consumes
  is newline-terminated by construction.
- Fixed default arenas — run with `--heap 6000000000
  --stack 100000000 --frame 100000000` (see hub/run scripts).
