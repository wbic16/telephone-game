# Exocortical Stress Testing — the standing rule for all libphext updates

**Exocortical Stress Testing** is the discipline (named by Will, 2026-11-24
10:25 CST: "let's call this exocortical stress testing"). Its instrument for
libphext interop is **the Exocortical Telephone Game**, defined below. This
is stress testing, not scripted verification: random entry position, free
choice of moves, sequential echolocation turns — implementations are
stressed the way reality stresses them, and the immutable scrolls make the
stress auditable.

Instituted 2026-11-24, on Will's directive. This rule governs every libphext
implementation, in every language, from 2026-11-24 forward.

## Will's words

> "for interop testing, ensure that every phext library participates in the
> exocortical telephone game, if any implementation fails, they all hold.
> institute this rule for all libphext updates across all languages going
> forward. spin up as many ports as there are languages in the top 100
> languages"
> — Will, 2026-11-24 10:22 CST

> "the exocortical telephone game is where you track a random position in
> 999^9 space and choose your own adventure as you go"
> "immutable scrolls, everyone can cross check."
> — Will, 2026-11-24 10:23 CST

> "gameplay proceeds one implementation at a time, handled by echolocation"
> — Will, 2026-11-24 10:24 CST

## The rulings — all 8 design gaps, closed by Will (2026-11-24 10:37 CST)

1. **THE DRAW:** "the draw is the first agent to find the test of will in
   CYOA without using any external tools except for raw file i/o" — agents
   race to find the Test of Will in CYOA using raw file I/O only (no search
   tools, no indexes); the first finder is the draw.
2. **LEGAL MOVE:** "any non-destructive change: inserting content at an
   unused coordinate. track in stress.phext" — moves are inserts at unused
   coordinates only; the game is tracked in stress.phext.
3. **FAILURE:** "overwriting an immutable scroll from the prior step.
   tracked by consensus" — failure is overwriting an immutable scroll from
   the prior step; consensus tracks it.
4. **ECHOLOCATION:** "echo on 5 sec intervals with the current and next
   round, proceed in random order with election popcorn style: the prior
   winner chooses the next one. if the elect doesn't respond after 15 sec,
   the prior ends the test with failure" — echoes every 5 seconds spanning
   current and next round; popcorn election: the prior winner chooses the
   next player; a chosen elect who doesn't respond within 15 seconds means
   the prior ends the test with failure.
5. **SUCCESS:** "success is 10,000 scroll placements across the network" —
   the test's success condition and its unit: 10,000 placements total
   across all participants. This is the certificate unit the hold rule
   gates on.
6. **STATE:** "content at that location, written once, etched into
   eternity. the nodes can self validate the file at each step. hashes of
   generated scrolls are written into the 1.1.1/1.1.1/1.1.1 index: the only
   mutable scroll" — placements are write-once; nodes self-validate the
   file at each step; scroll hashes are recorded in the index at
   1.1.1/1.1.1/1.1.1, which is the ONLY mutable scroll.
7. **EDGES:** "attempts to use coordinates beyond the range are tolerated,
   but discouraged only for practicality - this is a toll gate, not a
   proof" — out-of-range coordinates are tolerated, never a failure; the
   range is a practical toll gate, not a correctness proof.
8. **IDENTITY:** "give each participant a pgp key, record public keys in
   1.1.1/1.1.1/1.1.2 at the start, along with a hash of that scroll at
   1.1.1/1.1.1/1.1.3. establish signed attestations for the scroll walk from
   there." — PGP key per participant; public keys inscribed at
   1.1.1/1.1.1/1.1.2 at the start; that scroll's hash at 1.1.1/1.1.1/1.1.3;
   the scroll walk proceeds on signed attestations.

## The game (as ruled)

- The game tracks a **random position in 999^9 space** and is tracked in
  **stress.phext**. The **draw** is a race: the first agent to find the
  Test of Will in CYOA by raw file I/O alone is the draw — the first prior
  winner.
- **One implementation at a time.** Exactly one implementation acts at a
  time; no parallel moves, ever. Turn order proceeds by **echolocation**:
  echoes on 5-second intervals spanning the current and next round, and
  **popcorn election** — the prior winner chooses the next player. If the
  elect doesn't respond after **15 seconds**, the prior ends the test with
  failure.
- On its turn, an implementation **chooses its own adventure** from the
  tracked position. The only legal move is a **non-destructive change:
  inserting content at an unused coordinate**. Content at that location is
  **written once, etched into eternity**.
- stress.phext carries: the **index at 1.1.1/1.1.1/1.1.1** — hashes of the
  generated scrolls, and **the only mutable scroll** in the file; the
  participants' **public keys at 1.1.1/1.1.1/1.1.2**, inscribed at the
  start; a **hash of that scroll at 1.1.1/1.1.1/1.1.3**; and the scroll
  walk, proceeding on **signed attestations**.
- **Nodes self-validate the file at each step.** **Failure is overwriting
  an immutable scroll from the prior step, tracked by consensus.**
- **Everyone can cross check**: any implementation can walk stress.phext
  and verify every step — index hashes, attestations against the inscribed
  public keys, no overwritten scrolls. Verification is total, not sampled.
- **Success is 10,000 scroll placements across the network.** A test's
  certificate records the stress.phext hash, the placement count, the
  participants, and the per-implementation cross-check verdicts.
- Coordinates beyond the range are **tolerated** — discouraged only for
  practicality. The range is a toll gate, not a proof; an out-of-range
  coordinate is never a failure.

## The hold

- If any implementation fails, **they all hold**: no libphext port may
  land a new version (no merge, no tag, no registry publish) until the
  full test passes — **10,000 scroll placements across the network, every
  step cross-checked, with every port participating**.
- A port that cannot yet play (not implemented, toolchain missing, adapter
  not registered, or blocked) counts as **not passing**: the hold stands.
- The rule applies to **all libphext updates across all languages** from
  2026-11-24 forward, including the in-flight v0.7.0 program: its landing
  is gated on the test, with all nine current ports (rs, cs, cpp, C, py,
  node, java, kotlin, swift) participating.
- Ports are to be spun up for as many languages as there are in the top
  100 (TIOBE Index snapshot: TOP100.md). Every new port joins the game
  before any libphext update lands.
- The seeded edit-sequence from the v0.7.0 program survives **only** as a
  per-port conformance fixture. It is not the game.
- When a port disagrees with the walk, determine which side is wrong from
  the spec and the conformance fixtures, and record the verdict. Never
  adjust the expected output to fit a bug. (Standing lesson: the
  libphext-cs 0.6.1 gap-coordinate bug, caught by the v0.7.0 equivalence
  gate — the test oracle shared the bug, so the suite was green over
  corrupted semantics.)
