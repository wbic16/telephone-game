#!/bin/sh
set -e
export PATH="$HOME/.dotnet:$PATH"
cd "$(dirname "$0")"
dotnet build -c Release test.vbproj -v q --nologo
PHEXT_FIXTURES="${PHEXT_FIXTURES:-$HOME/telephone-vb/fixtures}" dotnet bin/Release/net8.0/test_phext_vb.dll
