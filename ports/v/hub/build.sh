#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-v
V=$HOME/telephone-v/v/v
rm -rf .build-cli .build-test
mkdir -p .build-cli .build-test
cp port/src/cli.v port/src/phext.v .build-cli/
cp port/src/phext.v port/tests/test_phext.v .build-test/
"$V" -cc gcc -enable-globals -o telephone .build-cli
"$V" -cc gcc -enable-globals -o test_phext .build-test
echo "v build ok"
