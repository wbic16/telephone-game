#!/bin/bash
# Run the gawk port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-awk
export LC_ALL=C
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-awk/fixtures}
gawk -f src/phext.awk -f tests/test_phext.awk $(find "$FIXTURES" -name input.phext | sort)
