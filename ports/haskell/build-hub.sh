#!/bin/sh
# Build the Haskell telephone CLI on the hub into ~/telephone-haskell/.
set -e
export PATH="$HOME/.ghcup/bin:$PATH"
mkdir -p ~/telephone-haskell/src ~/telephone-haskell/tests
cp src/Phext.hs src/Wire.hs src/Main.hs ~/telephone-haskell/src/
cp tests/TestPhext.hs ~/telephone-haskell/tests/
cd ~/telephone-haskell
ghc -O2 -isrc -o telephone src/Main.hs
ls -l telephone
