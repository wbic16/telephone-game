#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-spark
export PATH=$HOME/telephone-ada/env/bin:$PATH
mkdir -p build
gnatmake -f -O1 -gnat2012 -Iport/src -D build -o telephone port/src/cli.adb
gnatmake -f -O1 -gnat2012 -Iport/src -D build -o test_phext port/tests/test_phext.adb
echo "spark build ok"
