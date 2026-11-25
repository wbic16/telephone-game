#!/bin/sh
# Build and run the COBOL libphext test suite on the hub.
set -e
cd "$(dirname "$0")/.."
COBC=${COBC:-$HOME/telephone-cobol/env/bin/cobc}
FIXTURES=${1:-$HOME/telephone-ref/libphext-rs/tests/fixtures}
mkdir -p /tmp/telephone-cobol-build
$COBC -x -free -o /tmp/telephone-cobol-build/test_phext \
  -I src tests/test_phext.cob
/tmp/telephone-cobol-build/test_phext "$FIXTURES"
