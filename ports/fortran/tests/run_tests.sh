#!/bin/sh
# Build and run the Fortran libphext test suite on the hub.
# Usage: tests/run_tests.sh [fixtures_dir]   (default: the libphext-rs
# conformance fixtures in the ~/telephone-ref clone)
set -e
cd "$(dirname "$0")/.."
GFORTRAN=${GFORTRAN:-$HOME/telephone-fortran/gfortran}
FIXTURES=${1:-$HOME/telephone-ref/libphext-rs/tests/fixtures}
find "$FIXTURES" -name input.phext | sort > /tmp/telephone-fortran-fixtures.txt
$GFORTRAN -o /tmp/telephone-fortran-test src/phext.f90 src/wire.f90 tests/test_phext.f90
/tmp/telephone-fortran-test /tmp/telephone-fortran-fixtures.txt
