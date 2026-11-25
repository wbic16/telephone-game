#!/bin/bash
# Run the Elixir port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-elixir
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
export PATH=~/tools/asdf-bin:$PATH
export ASDF_DATA_DIR=~/tools/asdf-data
export PATH=$ASDF_DATA_DIR/shims:$PATH
export ASDF_ERLANG_VERSION=27.3.4.20
export ASDF_ELIXIR_VERSION=main-otp-27
elixir port/tests/test_phext.exs "$FIXTURES"
