# libphext — C shell (tcsh) port

Wave 6a, class (b). Implementation language: **tcsh 6.24.16**
(micromamba env `csh` on aletheia-core, user-level, no sudo).

## Status

Scale-limited (see "Measured limits" below): the port is
functionally complete at self-test / smoke scale — native suite
green, fixtures byte-identical, adapter self-test and smoke
verify pass — but the token-domain walk is far too slow for the
game-scale state, so gates (f)/(g) fail and the port is **not**
registered `playing`.

## Design: the token domain

tcsh cannot hold phext bytes in variables (no NULs, line-based
input that *parses* what it reads) and has no substring
operations, no functions, and no data structures beyond word
lists. The port therefore works in the **token domain**:

- A state file is exploded by `od -An -v -tu1 -w1` into a byte
  token stream (one decimal byte per line). `src/phext.tcsh`
  walks the stream with `$<` reads, maintaining the 9-component
  coordinate; scroll text is accumulated as 3-digit **octal**
  escapes (od reports decimal — each byte is converted
  `b = 64*o1 + 8*o2 + o3`) and materialized byte-exactly with
  `/usr/bin/printf '%b'`, flushed in 8192-char chunks (a single
  argv is capped at 128 KB, so a large scroll cannot be
  materialized in one call).
- The exploded form is a directory: `keys` (sorted zero-padded
  coordinate keys, lexical order == coordinate order) and one
  file per scroll under `s/`. Implode streams scroll files back
  with `cat` — only break bytes and the coordinate walk pass
  through tcsh there. Remove is coordinate-preserving (the
  suite tests the gap explicitly).
- JSON (`src/json.tcsh`) is processed over the same token
  domain: `spans` records top-level member spans (byte offsets
  into the request file), `spantext` decodes a string span,
  `spanraw` extracts a span with `dd`, `escape` produces
  canonical JSON string escaping (short escapes `\n \t \r \b
  \f`, `\"`, `\\`, `\u00XX` otherwise — matching Python
  `json.dumps(..., ensure_ascii=True)` for ASCII). Canonical
  objects are built by construction (sorted keys) in the CLI;
  the one re-serialization the contract needs, the attestation
  descriptor, is a flat object handled by `flat-canon`.
- `src/cli.tcsh` implements the full contract v2: id, keygen,
  echo, elect, choose, apply, attest, init, validate, verify —
  game logic mirroring `harness/adapter_base.py`, sha256 /
  base64 / gzip via the standard CLI tools, PGP via subprocess
  gpg under `~/telephone-csh/gnupg`.

## tcsh hazards found (all empirically verified)

- `$<` **parses** each input line (quotes stripped, braces
  grouped): JSON request lines can never enter through tcsh's
  stdin. `hub/build.sh`'s `run.sh` (POSIX sh) owns the intake
  loop and stages each line to a file; all logic is tcsh.
- Backquote output is re-parsed too: capturing anything
  containing `{` (a JSON object, the head of a request) breaks
  with `Missing '}'`. Such values travel only through files.
- `\"` next to a subscript (`"$x\"$w[1]..."`) is a parse error
  (`Unmatched '"'`); a quote character is carried in a variable
  (`$Q`) instead. `$var:` parses as a modifier — use `${var}`.
- `\$` inside a grep pattern aborts with "Variable name must
  contain alphanumeric characters" — patterns use `grep -xF`.
- `case` labels must stand alone on their line; `exec 0< file`
  is not a thing (explode re-invokes itself as `explode-walk`
  with the token stream as stdin).
- GNU `printf %b` interprets `\uXXXX` — escape output doubles
  its backslashes so the final text keeps literal `\u00XX`.
- tcsh's builtin `printf` lacks `%b`; `/usr/bin/printf` is used.
- A literal backslash in a quoted string is escape-processed
  unpredictably; the backslash enters only via a single-quoted
  variable (`set bs = '\'`).

## Measured limits

- Token walk rate: ~15,000 tokens/s for a bare read loop;
  the full explode walk (break switch + octal conversion +
  chunked flush) measures **~1,300 tokens/s effective**
  (2,265,624 B snapshot exploded in 1,741 s; implode 55 s,
  round trip byte-identical).
- Suite: 47 checks, 0 failures in ~7 s (semantics + JSON +
  canon + 15 fixtures). `chains/real-corpora-chain`
  (9,405,538 B, 10,547 scrolls) round-trips byte-identically
  in a separate long measured run.
- Adapter self-test: PASS (all 17 checks). Smoke verify:
  PASS/30 in 143 s.
- Game scale (snapshot of `games/test-001/stress.phext`,
  2,265,624 B, 1,005 placements): serve init 0.08 s
  driver-visible (deferred cache — gate (f) passes), but the
  hub-side load is one explode (~29 min), so choose ~29 min
  and validate ~3,500 s against the 60 s gate — gate (g)
  fails by ~58×. `scale-test-live.py` did not complete
  choose+apply+validate within a 70-minute bound.

## Files

- `src/phext.tcsh` — core: explode/implode/fetch/has/put/del/keyof
- `src/json.tcsh` — spans/spantext/spanraw/escape
- `src/cli.tcsh` — contract v2 CLI (handle/emit + helpers)
- `adapter` — local driver-side adapter (fleet-ssh relay,
  GZ1 framing, deferred init cache)
- `hub/build.sh`, `hub/run-cli.sh` — hub assembly in
  `~/telephone-csh/`
- `tests/test_phext.tcsh`, `tests/run_tests.sh`,
  `tests/adapter_selftest.py`
