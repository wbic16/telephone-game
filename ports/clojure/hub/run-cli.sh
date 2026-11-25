#!/bin/sh
export CLJ_CONFIG=/home/wbic16/telephone-clojure/clj-config
exec /home/wbic16/telephone-clojure/tools/bin/clojure -Sdeps '{:paths ["/home/wbic16/telephone-clojure/port/src"]}' -M -m telephone.cli "$@"
