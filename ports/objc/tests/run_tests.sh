#!/bin/sh
# Build and run the Objective-C libphext test suite on the hub.
# Toolchain: system clang 18 + user-level GNUstep stack in
# ~/telephone-objc (libobjc2 2.2.1 + gnustep-make ng-gnu-gnu +
# gnustep-base 1.30.0, all built from source, no sudo).
set -e
cd "$(dirname "$0")/.."
FIXTURES=${1:-$HOME/telephone-ref/libphext-rs/tests/fixtures}
. $HOME/telephone-objc/env.sh
mkdir -p /tmp/telephone-objc-build
clang -fobjc-runtime=gnustep-2.0 -fblocks $(gnustep-config --objc-flags) \
  -Isrc -o /tmp/telephone-objc-build/test_phext \
  src/Phext.m src/Wire.m tests/test_phext.m \
  $(gnustep-config --base-libs)
/tmp/telephone-objc-build/test_phext "$FIXTURES"
