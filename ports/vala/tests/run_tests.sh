#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-vala
export LD_LIBRARY_PATH=$HOME/telephone-vala/env/lib
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
./test_phext "$FIXTURES"
