#!/bin/bash
# Run the Scheme port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-scheme
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
~/tools/mamba-root/envs/scheme/bin/guile port/tests/test_phext.scm "$FIXTURES"
