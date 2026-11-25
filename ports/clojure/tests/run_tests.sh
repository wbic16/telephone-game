#!/bin/bash
# Run the Clojure port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-clojure
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
export CLJ_CONFIG=$HOME/telephone-clojure/clj-config
./tools/bin/clojure -Sdeps '{:paths ["port/src" "port/tests"]}' -M -m telephone.test "$FIXTURES"
