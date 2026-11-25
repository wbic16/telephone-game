#!/bin/sh
# Build and run the Ada libphext test suite on the hub.
set -e
cd "$(dirname "$0")/.."
GNATMAKE=${GNATMAKE:-$HOME/telephone-ada/env/bin/gnatmake}
FIXTURES=${1:-$HOME/telephone-ref/libphext-rs/tests/fixtures}
mkdir -p /tmp/telephone-ada-build
$GNATMAKE -f -O1 -gnat2012 -Isrc -D /tmp/telephone-ada-build \
  -o /tmp/telephone-ada-build/test_phext src/test_phext.adb
/tmp/telephone-ada-build/test_phext "$FIXTURES"
