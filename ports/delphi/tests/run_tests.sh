#!/bin/sh
# Build and run the Delphi (Free Pascal) libphext test suite on the hub.
set -e
cd "$(dirname "$0")/.."
FPC=${FPC:-$HOME/telephone-delphi/fpc}
FIXTURES=${1:-$HOME/telephone-ref/libphext-rs/tests/fixtures}
mkdir -p /tmp/telephone-delphi-build
$FPC -Mobjfpc -Sh -Fu src -FE/tmp/telephone-delphi-build -o/tmp/telephone-delphi-build/test_phext tests/test_phext.pas
/tmp/telephone-delphi-build/test_phext "$FIXTURES"
