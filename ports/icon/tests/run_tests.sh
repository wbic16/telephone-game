#!/bin/bash
# Run the Icon port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-icon
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
export PATH=$HOME/tools/icon/bin:$PATH
cd port/tests
icont -s test_phext.icn
./test_phext "$FIXTURES"
