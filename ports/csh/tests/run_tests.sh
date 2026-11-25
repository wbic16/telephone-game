#!/bin/bash
# Native suite for the C shell port: runs test_phext.tcsh under
# the micromamba tcsh on the hub. FIXTURE_LIST names the fixture
# directories to round-trip (default: all 16). The big fixture
# (chains/real-corpora-chain, 9.4 MB) is token-walked at tcsh
# speed -- run_tests.sh takes an optional list file so the
# measured run can be split; see README.md for timings.
exec </dev/null
cd "$(dirname "$0")/.."
export PATH="$HOME/tools/mamba-root/envs/csh/bin:$PATH"
LIST="${FIXTURE_LIST:-/tmp/csh-fixtures.txt}"
if [ ! -f "$LIST" ]; then
  find "$HOME/telephone-fixtures" -name input.phext | sed 's|/input.phext||' | sort > "$LIST"
fi
export FIXTURE_LIST="$LIST"
tcsh tests/test_phext.tcsh src
