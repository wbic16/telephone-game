# Solidity port — classification evidence (2026-11-24, aletheia-core)

## Toolchain (installed, user-level, no sudo)

```
$ ~/tools/solc --version
solc, the solidity compiler commandline interface
Version: 0.8.26+commit.8a97fa7a.Linux.g++
```

## The phext logic in Solidity compiles

```
$ ~/tools/solc --optimize --bin --abi -o /tmp/solc-out --overwrite ~/telephone-solidity/src/Phext.sol
Compiler run successful. Artifact(s) can be found in directory "/tmp/solc-out".
Phext.abi  2015 bytes
Phext.bin 11048 bytes
sha256(Phext.bin)  = 4b804903287d5c4691cba927a1cbdb5110d5d8c16bec72f5578ed46d1340fd41
sha256(Phext.sol)  = 3844c7f383bed208b03c343f52efa58ddc9740c5148f60b047e3954df1f46702
ABI functions (all pure): dephokenize, fetch, insert, normalize,
phokenize, remove, replace
```

## No EVM runtime exists on the hub

```
geth: ABSENT
anvil: ABSENT
forge: ABSENT
cast: ABSENT
evm: ABSENT
ganache: ABSENT
hardhat: ABSENT
(no evm-related binaries in /usr/bin or /usr/local/bin; the only
 grep hit is the unrelated "ppmforge")
```

## Why no harness can cure this in-language

- The EVM opcode set (Yellow Paper, and as emitted by solc above)
  contains no file, process, socket, or console opcodes; a contract
  observes only calldata, its storage, and block/account fields.
  `seek` (raw file I/O), `keygen`/`attest` (subprocess gpg with a
  private key home), and `serve` (persistent stdin/stdout) are
  adapter-contract requirements that no contract code can perform.
- Any executing harness would be an EVM implemented in some other
  language; the phext work inside the contract would still be gated
  by gas: the 2,236,326-byte test-001 state as calldata alone is
  ~35M gas at 16 gas/non-zero byte before any computation, against
  a ~30M block gas limit on Ethereum mainnet parameters — one
  `validate` cannot fit in a block.
- Therefore: blocked-for-classification-review, per the wave brief's
  instruction not to shell out to another language for the phext
  logic and call it Solidity.
