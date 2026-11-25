#!/bin/sh
# Build the J port: J has no module system for scripts, so the port
# is concatenated from its parts (core, json, main) into single
# scripts under build/. Runs on aletheia-core where the user-level
# J 9.6 toolchain lives (~/telephone-j/j/bin/jconsole).
set -e
cd "$(dirname "$0")"
mkdir -p build
cat src/phext.ijs src/json.ijs src/telephone.ijs > build/telephone.ijs
cat src/phext.ijs src/json.ijs tests/test_phext.ijs > build/test_phext.ijs
echo "built build/telephone.ijs and build/test_phext.ijs"
