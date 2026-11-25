#!/bin/sh
# Build the ML telephone CLI on the hub into ~/telephone-ml/.
set -e
export PATH="$HOME/tools/mlton/bin:$PATH"
mkdir -p ~/telephone-ml/src ~/telephone-ml/tests
cp src/wire.sml src/phext.sml src/telephone.sml src/telephone.mlb ~/telephone-ml/src/
cp tests/test_phext.sml tests/test.mlb ~/telephone-ml/tests/
cd ~/telephone-ml
mlton -output telephone src/telephone.mlb
ls -l telephone
