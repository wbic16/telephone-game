#!/bin/sh
# Build the Caml telephone CLI on the hub into ~/telephone-caml/.
set -e
mkdir -p ~/telephone-caml/src ~/telephone-caml/tests
cp src/phext_caml.ml src/wire_caml.ml src/telephone_caml.ml ~/telephone-caml/src/
cp tests/test_caml.ml ~/telephone-caml/tests/
cd ~/telephone-caml
OCAMLC=$(command -v ocamlopt || command -v ocamlc)
$OCAMLC -o telephone -I src src/phext_caml.ml src/wire_caml.ml src/telephone_caml.ml
ls -l telephone
