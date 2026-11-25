#!/bin/bash
# Run the PowerShell port's test suite on the hub.
exec </dev/null
set -e
cd ~/telephone-powershell
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-fixtures}
./pwsh-7.4.6/pwsh -NoProfile -NonInteractive -File port/tests/Test-Phext.ps1 "$FIXTURES"
