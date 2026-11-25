#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-cfml
rm -f cache/test.fail
TELCFML_FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures} TELCFML_FAILMARK=$HOME/telephone-cfml/cache/test.fail ./boxzip/box port/tests/test_phext.cfm
test ! -f cache/test.fail
