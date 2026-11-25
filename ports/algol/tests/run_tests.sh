#!/bin/bash
# Run the Algol port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-algol
bash port/hub/build.sh
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
find "$FIXTURES" -name input.phext | sort > /tmp/algol-fixtures.txt
$HOME/tools/a68g/bin/a68g --heap 6000000000 --stack 100000000 \
  --frame 100000000 test_phext.a68 > /tmp/algol-suite-out.txt 2>&1 || true
grep -v 'warning' /tmp/algol-suite-out.txt | grep -E 'fixtures:|algol suite:|FAIL' || true
# a68g has no exit-code channel for the suite; the summary line is
# the verdict (run_tests fails closed when it is not clean)
grep -q 'algol suite: .* 0 failures' /tmp/algol-suite-out.txt
