#!/bin/bash
# Run the Io port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-io
IOBIN=$HOME/tools/dl/io-src/build/_build/binaries/io
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
find "$FIXTURES" -name input.phext | sort > /tmp/io-fixtures.txt
cd port
$IOBIN tests/test_phext.io
