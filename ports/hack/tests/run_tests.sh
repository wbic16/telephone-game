#!/bin/bash
# Native suite for the hack port, run on the hub.
set -e
cd "$HOME/telephone-hack"
./bin/hhvm src/telephone.hack test "$HOME/telephone-fixtures"
