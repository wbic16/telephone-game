# Serve-protocol conformance — audit + fixes (in progress)

Started 2026-11-24 ~11:37 CST. Trigger: resumed game crashed in
`harness/telephone.py` `cmd_play` — it sends `{"cmd":"init",
"state_path": ...}` to every registered adapter's serve process at
play startup, and the Fortran adapter answered `unknown cmd`.

## Required serve command set (contract v2 + driver, together)

Driver (`telephone.py`) serve calls, verbatim forms:

| cmd | request fields | used in |
|---|---|---|
| init | `state_path` | cmd_new, cmd_play (re-init on resume) |
| echo | `ping` {game, round, nonce} | cmd_play, 5 s intervals |
| elect | `position`, `candidates`, `turn`, `placements` | cmd_play |
| choose | `state_path`, `position`, `turn` | cmd_play (15 s limit) |
| apply | `state_path`, `step`, `state_out_path` | cmd_play |
| attest | `descriptor` {turn, coordinate, scroll_sha256, file_sha256} | cmd_play |
| validate | `state_path`, `step`, `event_coord`, `index_line` | cmd_play |
| verify | `state_path`, `pubkeys` | cmd_verify |

Contract v2 names the same subcommands with state as base64
(`state`); `adapter_base._state_bytes` accepts either form locally.
Hub ports' wire protocol is base64-only, so their local wrappers must
translate `state_path` → `state` (and `state_out_path` on apply).

## Static audit (source reading)

- py, reference: subclass `harness/adapter_base.py`, whose `handle()`
  implements id/keygen/seek/echo/elect/choose/apply/attest/**init**/
  validate/verify incl. `state_path`. Expected conformant.
- dart, julia: also subclass adapter_base (hub CLI used only for the
  explode/implode/insert/fetch hooks). Expected conformant at the
  serve layer. Owned by wave-1b worker — audit read-only, no edits.
- go, php, perl, fortran: local wrapper `serve()` relays driver JSON
  lines **verbatim** over fleet-ssh to the hub CLI serve loop.
  Hub CLI dispatch (go main.go, php telephone.php, perl telephone.pl,
  fortran telephone.f90) implements id/echo/elect/choose/apply/keygen/
  attest/validate/verify — **no `init` in any of the four** — and
  expects state as base64 `state`/`state_b64`, never `state_path`.
  Consequences in driver form: init → unknown cmd; choose/apply/
  validate/verify → empty state. Hub `validate` also has selftest
  semantics (prior_state, count +1, all prior byte-intact incl.
  index), which do not match driver validate (file already carries
  the placement + event scroll + appended index line; prior state is
  the init/validate cache, cf. adapter_base.validate).

## Live audit

Method: `/tmp/audit_serve.py` spawns each adapter's `serve`, sends
the driver-form requests above against a scratch copy of
`games/smoke-001/stress.phext` (original never touched), in driver
order: init → echo → elect → choose → apply → attest → validate
(against a driver-inscribed file: placement + index line + event
scroll added via the reference implementation) → verify (smoke file,
30 placements). Performed 2026-11-24 ~11:40–11:50 CST.

| adapter | init | echo | elect | choose | apply | attest | validate | verify |
|---|---|---|---|---|---|---|---|---|
| reference | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| py | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| dart | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| julia | OK | OK | OK | OK | OK (hash match) | OK | pass | pass/30 |
| go | **unknown cmd** | OK | OK | **empty state** | **empty state** | OK | **fail** | **fail** |
| php | **unknown cmd** | OK | OK | **empty state** | **empty state** | OK | **fail** | **fail** |
| perl | **unknown cmd** | OK | OK | **empty state** | **empty state** | OK | **fail** | **fail** |
| fortran | **unknown cmd** | OK | OK | **empty state** | **empty state** | OK | **fail** | **fail** |

"empty state": the hub CLI received no `state` (driver sent
`state_path`, wrapper relayed verbatim), so choose/apply ran against
a zero-byte state — apply returned a phext containing only the new
placement, and never wrote `state_out_path`; validate/verify then
failed on the empty state ("placed scroll absent…", "no public-keys
scroll at 1.1.1/1.1.1/1.1.2"). Verbatim init errors: go
`unknown cmd "init"`, php `unknown cmd init`, perl `unknown cmd
init`, fortran `unknown cmd`.

dart/julia (wave-1b-owned): **no gaps** — nothing to report upstream
beyond this table; their files were not touched.

## Fixes

For go/php/perl/fortran (wave-1a, unowned — fixed here):

1. Local wrapper `serve()` (ports/<p>/adapter): translate at the
   boundary — `state_path` → base64 `state` (read the file locally);
   on apply, pop `state_out_path`, write the returned `state_b64`
   there, answer `{"state_sha256": ...}`. All other commands relay
   unchanged. (Mirrors adapter_base: path locally, base64 over SSH.)
2. Hub CLI (ports/<p>/src, synced byte-identical to hub): implement
   `init` — cache the state in the serve process, reply
   `{"impl": id, "verdict": "pass"}`; extend `validate` with the
   driver form (request carries `event_coord`/`index_line`): prior
   state = the init/validate cache (explicit `prior_state` still
   wins), checks per adapter_base.validate — placed scroll present
   with step text, every prior scroll except the index byte-intact,
   new scrolls only at the placement and event coordinates, index
   ends with `index_line`; on pass the cache advances to the new
   state. Legacy wire validate (selftest form) unchanged.
3. Rebuild compiled hub binaries (go, fortran); re-run one-shot
   verify (expect PASS/30) + full serve audit per port.

(Results appended below as fixes land.)
