#!/bin/bash
# Run the Crystal port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-crystal
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
./test_phext "$FIXTURES"
