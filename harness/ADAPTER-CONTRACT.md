# Telephone-game adapter contract v2 — Exocortical Stress Testing

Supersedes contract v1 (2026-11-24, later the same day) on Will's rulings
closing the 8 design gaps (see RULE.md § The rulings). Every libphext
implementation participates through ONE adapter: an executable named
`adapter` in the port's directory (or a command in `harness/registry.json`).

The game is tracked in **stress.phext**: index at 1.1.1/1.1.1/1.1.1 (the
only mutable scroll — hashes of generated scrolls), participant public keys
at 1.1.1/1.1.1/1.1.2, that scroll's hash at 1.1.1/1.1.1/1.1.3, game events
as hash-chained scrolls at 1.1.1/1.1.1/2.1.<seq>, placements as scrolls at
their own coordinates.

**Pinned formats** (the driver's inscription is canonical; every verify
must read exactly this):
- Index scroll text: a header line `# exocortical stress testing - index
  of generated scrolls`, then one line per placement:
  `<turn> <coordinate> <sha256 of scroll text> <actor id>`.
- Keys scroll text: `== <id> ==\n<armored public key>` blocks joined by
  single newlines, trailing newline. Keys-hash scroll: sha256 hex of the
  keys scroll text exactly as inscribed.
- Event scroll text: canonical JSON `{"prev": <sha256 of previous event's
  body, or null>, "body": {...}}`. A placement body carries: type, turn,
  actor, elect_by, coord, text_sha256, file_sha256 (the file hash after
  the placement insert, before inscription), att (base64 of the armored
  detached signature), echoes, consensus_prev.
- Attestation descriptor (what gets signed): canonical JSON
  `{"turn": n, "coordinate": ..., "scroll_sha256": ..., "file_sha256":
  ...}`.

## Transport

- `adapter serve` — persistent mode: reads one JSON request per line on
  stdin, writes one JSON response per line on stdout. Request:
  `{"cmd": "<subcommand>", ...args}`. The driver keeps one serve process
  per participant for the whole test. (One-shot invocation
  `adapter <subcommand> ...` remains for keygen/seek and debugging.)

## Subcommands

- `id` → the implementation id, plain text (one-shot) or `{"impl": id}`.
- `keygen` (one-shot) → ensures the participant's PGP keypair exists in its
  own key home; stdout `{"impl": id, "pubkey": "<armored public key>"}`.
  Private keys never leave the participant's key home and are never
  inscribed anywhere.
- `seek` (one-shot) → races to find the Test of Will in CYOA using **raw
  file I/O only** (open/read bytes in-process; no search tools, no
  subprocess grep/find, no prebuilt indexes). Argument: the CYOA corpus
  root. Stdout: `{"impl": id, "path": ..., "offset": <int>,
  "coordinate": "13.13.13/13.13.13/13.13.13", "title": ...}` — the
  coordinate/title as read from the file; the driver verifies by raw read.
- `echo` — request `{"cmd":"echo","ping":{...}}` (ping carries game,
  round, nonce). → `{"impl": id, "echo": "<value>"}`. The echo is the
  participant's own call-and-response, deterministic given the ping.
- `elect` — request `{"cmd":"elect","position": ..., "candidates": [ids],
  "turn": n}`. The prior winner chooses the next player (popcorn style).
  → `{"elect": "<impl id>"}`.
- `choose` — request `{"cmd":"choose","state": "<base64 stress.phext>",
  "position": ..., "turn": n}`. The participant chooses its own adventure.
  **The only legal move is a non-destructive change: inserting content at
  an unused coordinate.** → `{"op": "insert",
  "coordinate": "a.b.c/d.e.f/g.h.i", "text": "..."}`. The coordinate must
  hold no scroll in the given state. Text must not contain dimension-break
  bytes. Coordinates beyond 999 per component are tolerated (a toll gate,
  not a proof) but discouraged for practicality.
- `apply` — request `{"cmd":"apply","state": "<base64>", "step": {...}}`.
  Applies the insert with its own libphext. → `{"state_b64": ...,
  "state_sha256": ...}`.
- `attest` — request `{"cmd":"attest","descriptor": {...}}` (turn,
  coordinate, scroll sha256, prior file sha256). → `{"signature":
  "<armored detached PGP signature over the canonical descriptor>"}`.
- `validate` — request `{"cmd":"validate","state": "<base64 new file>",
  "step": {...}}`. The node self-validates the file at this step: the
  placed scroll is present at an unused coordinate with the attested
  content, and no prior scroll was overwritten (failure = overwriting an
  immutable scroll from the prior step). → `{"impl": id,
  "verdict": "pass"|"fail", "detail": ...}`.
- `verify` — request `{"cmd":"verify","state": "<base64 final file>",
  "pubkeys": "<armored keys from 1.1.1/1.1.1/1.1.2>"}`. Total walk of
  stress.phext: event chain integrity, every placement's attestation
  signature against the inscribed public keys, index hashes matching every
  placement scroll, keys-hash scroll matching, no overwritten scrolls,
  placement count. → `{"impl": id, "verdict": "pass"|"fail",
  "placements_checked": n, "first_failure": ...}`.

## Rules for adapters

- An adapter wraps its own libphext only — never another port's code.
- `choose` and `elect` logic belong to the participant: any rule of its
  own devising within the legal-move definition.
- Coordinates: 9 components, each ≥ 1, written
  `a.b.c/d.e.f/g.h.i`.
