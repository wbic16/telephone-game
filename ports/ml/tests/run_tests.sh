#!/bin/sh
# Build and run the ML libphext test suite on the hub.
set -e
cd "$(dirname "$0")/.."
export PATH="$HOME/tools/mlton/bin:$PATH"
mlton -output /tmp/test_phext_ml tests/test.mlb
PHEXT_FIXTURES="${PHEXT_FIXTURES:-$HOME/telephone-fixtures}" /tmp/test_phext_ml
