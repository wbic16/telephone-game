#!/bin/bash
# Run the Groovy port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-groovy
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
java -cp "test-classes:classes:groovy/lib/*" phext.TestPhext "$FIXTURES"
