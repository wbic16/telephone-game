#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-ksh
export LC_ALL=C
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
PHEXT_FIXTURES=$FIXTURES ~/telephone-ksh/ksh93/ksh port/tests/test_phext.ksh
