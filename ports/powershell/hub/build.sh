#!/bin/bash
# PowerShell: interpreted by pwsh; syntax-check both sources.
exec </dev/null
set -e
cd ~/telephone-powershell
./pwsh-7.4.6/pwsh -NoProfile -NonInteractive -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('port/src/Phext.ps1', [ref]\$null, [ref]\$null); [void][System.Management.Automation.Language.Parser]::ParseFile('port/src/cli.ps1', [ref]\$null, [ref]\$null); Write-Output 'powershell parse ok'"
