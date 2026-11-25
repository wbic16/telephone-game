# libphext — Solidity port (Exocortical Stress Testing)

TIOBE #49. Status: **blocked-for-classification-review** (see
EVIDENCE.md for the full record with command output).

What exists: `src/Phext.sol` — a genuine implementation of the
libphext core semantics written in Solidity itself (phokenize,
dephokenize, fetch, insert, replace, coordinate-preserving remove,
normalize over `bytes`; coordinates as `uint256[9]`). It compiles
cleanly with solc 0.8.26 (user-level static binary in `~/tools/solc`
on aletheia-core): Phext.bin 11,048 bytes, sha256
4b804903287d5c4691cba927a1cbdb5110d5d8c16bec72f5578ed46d1340fd41.

Why it cannot play (the adapter contract is unsatisfiable from
inside the EVM, by construction — not a matter of effort):

1. **No execution host exists on the hub, and a contract cannot be
   one.** A Solidity contract runs only when an EVM executes a call
   to it. The hub has no EVM runtime at all (geth, anvil, forge,
   cast, evm, ganache, hardhat: all absent — EVIDENCE.md). Writing
   the missing EVM is writing a different language's runtime, not a
   Solidity port.
2. **The EVM instruction set has no I/O.** There are no file,
   process, socket, or stream opcodes. The contract's entire view of
   the world is calldata, block/account state, and its own storage.
   Three adapter subcommands are therefore impossible in-contract:
   - `seek` requires raw file I/O over the CYOA corpus on disk;
   - `keygen`/`attest` require subprocess PGP signing with a
     persistent private-key home (a contract has no subprocesses and
     no private filesystem; its keys are account keys controlled by
     an external signer);
   - `serve` requires a persistent stdin/stdout line protocol.
3. **Gas metering makes general string processing impractical at
   game scale.** Every byte of the 2.2 MB test-001 state would be
   calldata + memory expansion under a per-block gas limit; a single
   `validate` explode of 2,004 scrolls is a multi-block workload,
   not a call. (The compiled functions are all `pure` — the phext
   logic itself is expressible; the runtime model is the blocker.)

Per the wave brief, this is recorded as blocked-for-classification-
review rather than faked: no other language was shelled out to for
the phext logic and called Solidity, and no adapter is registered
as playing. The classification question for Will: Solidity is a
contract language whose only runtime is a blockchain VM — closer to
the class-(c) platform-bound entries (Apex, X++) than to the
class-(b) library languages, despite TOP100.md listing it (b) on the
strength of the solc install alone.
