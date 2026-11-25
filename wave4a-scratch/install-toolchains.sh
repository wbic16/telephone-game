#!/bin/bash
# Wave 4a toolchain installs on aletheia-core: user-level only, no sudo.
export HOME=/home/wbic16
mkdir -p ~/tools ~/telephone-haskell ~/telephone-ml ~/telephone-solidity
{
echo "=== GHCup ==="
date
if [ ! -x ~/.ghcup/bin/ghcup ]; then
  curl -fsSL -o /tmp/ghcup-bin https://downloads.haskell.org/~ghcup/0.1.30.0/x86_64-linux-ghcup-0.1.30.0
  mkdir -p ~/.ghcup/bin
  cp /tmp/ghcup-bin ~/.ghcup/bin/ghcup && chmod +x ~/.ghcup/bin/ghcup
fi
~/.ghcup/bin/ghcup --version
export GHCUP_INSTALL_BASE_PREFIX=$HOME
~/.ghcup/bin/ghcup install ghc 9.6.6 2>&1 | tail -3
~/.ghcup/bin/ghcup install cabal 3.10.3.0 2>&1 | tail -3
~/.ghcup/bin/ghc --version; ~/.ghcup/bin/cabal --version | head -1
echo "=== GHC DONE ==="
} > ~/telephone-haskell/install.log 2>&1 &
{
echo "=== MLton ==="
date
cd /tmp
if [ ! -x ~/tools/mlton/bin/mlton ]; then
  curl -fsSL -o /tmp/mlton.tgz https://github.com/MLton/mlton/releases/download/on-20210117-release/mlton-20210117-1.amd64-linux.ubuntu-20.04_glibc2.31.tgz
  mkdir -p ~/tools/mlton-extract
  tar -xzf /tmp/mlton.tgz -C ~/tools/mlton-extract
  ls ~/tools/mlton-extract
  cp -r ~/tools/mlton-extract/mlton-20210117-1.amd64-linux.ubuntu-20.04_glibc2.31 ~/tools/mlton
fi
~/tools/mlton/bin/mlton 2>&1 | head -2
ldconfig -p | grep -i gmp | head -3
echo "=== MLTON DONE ==="
} > ~/telephone-ml/install.log 2>&1 &
{
echo "=== solc ==="
date
if [ ! -x ~/tools/solc ]; then
  curl -fsSL -o ~/tools/solc https://github.com/ethereum/solidity/releases/download/v0.8.26/solc-static-linux
  chmod +x ~/tools/solc
fi
~/tools/solc --version
for t in geth anvil forge cast evm ganache hardhat; do printf "%s: %s\n" "$t" "$(command -v $t || echo ABSENT)"; done
ls /usr/bin | grep -i -E 'evm|geth|ethereum' || echo "no evm-related binaries in /usr/bin"
echo "=== SOLC DONE ==="
} > ~/telephone-solidity/install.log 2>&1 &
wait
echo ALL-INSTALL-JOBS-FINISHED
