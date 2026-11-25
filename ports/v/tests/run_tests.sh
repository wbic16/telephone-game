#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-v
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
./test_phext "$FIXTURES"
