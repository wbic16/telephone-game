# Wave-1a format reconciliation — audit + verify battery

Second attempt (2026-11-24, ~11:31 CST start). First worker died
mid-flight; this file is the checkpointed record. Authority:
`harness/ADAPTER-CONTRACT.md` pinned formats + driver inscription in
`harness/telephone.py` / `harness/adapter_base.py` (prev =
sha256(canon(body)); index header `# exocortical stress testing -
index of generated scrolls`; descriptor canon
{"turn","coordinate","scroll_sha256","file_sha256"}).

## Step 1 — AUDIT (complete)

Method: read each port's local `validate`/`verify` source; md5 local
source vs hub source on aletheia-core (`~/telephone-<slug>/`).

md5 evidence (local == hub for every file):

| file | md5 |
|---|---|
| php/src/telephone.php | e74bb0f17ea2268afc4d443d0219f377 |
| php/src/phext.php | 498c49942e6e69e8ef6f265e54ad3d82 |
| perl/src/telephone.pl | 28773b2c1092ff32cc40cceedca0d2a5 |
| perl/src/Phext.pm | c64da59aa94ae5b8fbd8e98b2176fe95 |
| go/src/cmd/telephone/main.go | a178fd52c681cd823c20a3d2f127e992 |
| go/src/phext/phext.go | 1c2e8824ec9931e33ea38d29448b5586 |
| fortran/src/telephone.f90 | ba9a35ddebf52b60536ccf43cbd03f86 |
| fortran/src/wire.f90 | 11506acde253ff1b8b20c0bfa1f5634c |
| fortran/src/phext.f90 | 5dfd14b4d5f2941774a21f8056b9fee3 |

Hub binaries: `telephone-go/telephone` and
`telephone-fortran/telephone` both rebuilt Nov 24 11:24 — at/after
their hub source mtimes (go main.go 11:17, fortran telephone.f90
11:24; php telephone.php hub mtime 11:22, perl telephone.pl 11:23).
Conclusion: the first worker DID re-sync all four hub CLIs and
rebuild the compiled ones. The only unknown it left was whether the
verify batteries ran.

Per port per format:

- **go** — index: ALIGNED (already-fixed-by-first-worker). Verify
  skips `#` header/blank lines, requires exactly 4 fields
  `<turn> <coordinate> <sha256> <actor id>`, cross-checks
  turn/hash/actor per placement and rejects index lines with no
  event. Event: ALIGNED — parses {"prev","body"} at
  1.1.1/1.1.1/2.1.<seq>, seq 1 prev must be null, later prev must
  equal sha256(canon(previous body)). Descriptor: ALIGNED — canon
  {"turn","coordinate","scroll_sha256","file_sha256"} built from the
  body, att = base64 armored detached signature verified against
  inscribed keys. Validate: ALIGNED — insert-only, coordinate unused
  in prior state, scroll count +1, every prior scroll byte-intact.
- **php** — index/event/descriptor/validate: ALIGNED
  (already-fixed-by-first-worker), same checks as go (chain hash
  computed from the stdClass decode so empty objects canon as {}).
- **perl** — index/event/descriptor/validate: ALIGNED
  (already-fixed-by-first-worker), same checks (descriptor turn
  re-numerified before canon so it serializes as a number).
- **fortran** — index/event/descriptor/validate: ALIGNED
  (already-fixed-by-first-worker). Index matched per placement via
  index_has on (turn, coord, hash, actor) plus a final index-line
  count == placement count check (header `#` lines skipped). Event
  chain: prev compared against sha256 of the previous event's
  inscribed body span — the driver inscribes canon(body), so the
  span is the canonical form; equivalent to the other ports.
  Descriptor built as the flat sorted canonical string directly.

## Step 2 — FIXES

None required. Nothing was misaligned at audit time; no port source,
hub CLI, phext implementation, or game-move logic was changed by
this attempt.

## Step 3 — VERIFY BATTERY

(a) smoke-001 (`games/smoke-001/stress.phext`) — ALL PASS, verbatim:

- go: `{"first_failure": null, "impl": "go", "placements_checked": 30, "verdict": "pass"}`
- php: `{"impl": "php", "verdict": "pass", "placements_checked": 30, "first_failure": null}` (stderr: repeated benign `PHP Warning: mkdir(): File exists` from the hub CLI)
- perl: `{"impl": "perl", "placements_checked": 30, "first_failure": null, "verdict": "pass"}` (stderr: gpg import/"Good signature" noise only)
- fortran: `{"impl": "fortran", "verdict": "pass", "placements_checked": 30, "first_failure": null}`

(b) test-001 snapshot — copied 2026-11-24 ~11:32 CST to
`harness/reconcile-scratch/test001-snapshot.phext` (2,236,326 bytes;
md5 15e281968a40eebfba3c8233948a0995, identical to the live file at
copy time; `games/test-001/` was never written to). ALL PASS,
verbatim:

- go: `{"first_failure": null, "impl": "go", "placements_checked": 1000, "verdict": "pass"}`
- php: `{"impl": "php", "verdict": "pass", "placements_checked": 1000, "first_failure": null}`
- perl: `{"impl": "perl", "first_failure": null, "verdict": "pass", "placements_checked": 1000}`
- fortran: `{"impl": "fortran", "verdict": "pass", "placements_checked": 1000, "first_failure": null}`

All four independently counted exactly 1000 placements in the
snapshot — the live game has since moved on; 1000 is what the
snapshot showed.

## Step 4 — FAILURE ADJUDICATION

None. No port failed any driver-produced file, so there is nothing
to adjudicate; no expected output and no driver file was adjusted.

## Conclusion

Wave-1a format reconciliation is COMPLETE. The first worker's fixes
were fully landed (local sources + hub CLIs byte-identical, compiled
hub binaries rebuilt) — only the acceptance evidence was missing,
and it is now recorded above: all four ports' `verify` speak the
pinned index/event/descriptor formats and pass on both
driver-produced files (smoke-001: 30/30; test-001 snapshot:
1000/1000, four independent stacks agreeing).
