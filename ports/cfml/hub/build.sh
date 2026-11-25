#!/bin/bash
# No compilation for CFML: CommandBox (Lucee) runs the sources.
# This "build" is a smoke parse: run the CLI with an id request.
exec </dev/null
set -e
cd ~/telephone-cfml
echo '{"cmd":"id"}' | ./run-cli.sh
echo "cfml build ok"
