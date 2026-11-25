#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-mojo
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
./bin/telephone test "$FIXTURES"
