#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-spark
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
./test_phext "$FIXTURES"
