#!/bin/bash
# Run the Erlang port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-erlang
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
export PATH=~/tools/asdf-bin:$PATH
export ASDF_DATA_DIR=~/tools/asdf-data
export PATH=$ASDF_DATA_DIR/shims:$PATH
export ASDF_ERLANG_VERSION=27.3.4.20
erl -noshell -pa ebin -run test_phext boot -- "$FIXTURES"
