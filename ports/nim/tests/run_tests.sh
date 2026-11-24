#!/bin/sh
# Build and run the Nim libphext test suite on the hub.
set -e
export PATH="$HOME/.nimble/bin:$PATH"
cd "$(dirname "$0")/.."
nim c -d:release --hints:off --warnings:off --path:src --out:/tmp/test_phext_nim tests/test_phext.nim
PHEXT_FIXTURES="${PHEXT_FIXTURES:-$HOME/telephone-nim/fixtures}" /tmp/test_phext_nim
