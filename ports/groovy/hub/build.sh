#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-groovy
ln -sfn "$(ls -d groovy-[0-9]* | head -1)" groovy
mkdir -p classes test-classes
./groovy/bin/groovyc -d classes port/src/Phext.groovy port/src/Cli.groovy
./groovy/bin/groovyc -cp classes -d test-classes port/tests/TestPhext.groovy
echo "groovy build ok"
