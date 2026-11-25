#!/bin/sh
# Build and run the Caml libphext test suite on the hub.
set -e
cd "$(dirname "$0")/.."
OCAMLC=$(command -v ocamlopt || command -v ocamlc)
$OCAMLC -o /tmp/test_phext_caml -I src src/phext_caml.ml tests/test_caml.ml
PHEXT_FIXTURES="${PHEXT_FIXTURES:-$HOME/telephone-fixtures}" /tmp/test_phext_caml
