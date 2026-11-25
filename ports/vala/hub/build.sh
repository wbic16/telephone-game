#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-vala
VALAC=$HOME/telephone-vala/env/bin/valac
export LD_LIBRARY_PATH=$HOME/telephone-vala/env/lib
"$VALAC" --pkg gio-2.0 --pkg posix -o telephone port/src/cli.vala port/src/phext.vala
"$VALAC" --pkg gio-2.0 --pkg posix -o test_phext port/src/phext.vala port/tests/test_phext.vala
echo "vala build ok"
