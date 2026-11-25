#!/bin/bash
# Run the smalltalk port suite (hub CLI test command, via the hub runner)
# and the adapter self-test (local, over fleet-ssh serve).
set -u
cd "$(dirname "$0")/.."
FLEET_SSH="$HOME/workspace/bickford-llama-ranch/deploy/fleet-ssh.sh"
FIXTURES="${1:-/home/wbic16/telephone-fixtures}"
echo "== suite (fixtures: $FIXTURES) =="
out="$(printf '{"cmd":"test","fixtures":"%s"}\n' "$FIXTURES" | "$FLEET_SSH" aletheia-core /home/wbic16/telephone-smalltalk/bin/run-telephone)"
printf '%s\n' "$out"
suite_rc=1
printf '%s' "$out" | grep -q 'suite: .* 0 failures' && suite_rc=0
echo "== adapter self-test =="
python3 tests/selftest_adapter.py
self_rc=$?
[ "$suite_rc" -eq 0 ] && [ "$self_rc" -eq 0 ]
