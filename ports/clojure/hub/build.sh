#!/bin/bash
# Clojure: interpreted via the Clojure CLI tools; pre-warm dep resolution.
exec </dev/null
set -e
cd ~/telephone-clojure
export CLJ_CONFIG=$HOME/telephone-clojure/clj-config
./tools/bin/clojure -Sdeps '{:paths ["port/src"]}' -M -e "(require (quote telephone.cli))" </dev/null
echo "clojure build: deps resolved, namespaces compile"
