#!/bin/sh
# Build and run the Haskell libphext test suite on the hub.
set -e
cd "$(dirname "$0")/.."
export PATH="$HOME/.ghcup/bin:$PATH"
ghc -O2 -isrc -o /tmp/test_phext_haskell src/Phext.hs src/Wire.hs tests/TestPhext.hs
PHEXT_FIXTURES="${PHEXT_FIXTURES:-$HOME/telephone-fixtures}" /tmp/test_phext_haskell
