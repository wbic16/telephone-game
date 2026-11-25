#!/bin/sh
# Build the single-file REXX programs from their part-files (classic
# REXX has no module system; programs are concatenations, main first).
set -e
cd "$(dirname "$0")"
cat src/test-main.rexx src/phext.rexx > tests/test_phext.rexx
cat src/telephone-main.rexx src/telephone-main2.rexx src/phext.rexx src/json.rexx > src/telephone.rexx
echo built
