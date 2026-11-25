#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-crystal
CRYSTAL=$(ls crystal-*/bin/crystal | head -1)
"$CRYSTAL" build port/src/cli.cr -o telephone
"$CRYSTAL" build port/tests/test_phext.cr -o test_phext
echo "crystal build ok"
