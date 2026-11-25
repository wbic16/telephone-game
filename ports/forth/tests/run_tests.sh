#!/bin/bash
# Run the Forth port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-forth
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
OUT=$(~/tools/gforth-0.7.3/bin/gforth port/tests/test_phext.fs "$FIXTURES" 2>&1)
echo "$OUT" | grep -v "^redefined" | tail -5
echo "$OUT" | grep -q ", 0 failures"
