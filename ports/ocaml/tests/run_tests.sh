#!/bin/sh
# Build and run the OCaml libphext test suite + CLI on the hub.
set -e
cd "$(dirname "$0")/.."
OCAMLC=$(command -v ocamlopt || command -v ocamlc)
$OCAMLC -o /tmp/test_phext_ocaml -I src src/phext.ml tests/test_phext.ml
PHEXT_FIXTURES="${PHEXT_FIXTURES:-$HOME/telephone-ocaml/fixtures}" /tmp/test_phext_ocaml
