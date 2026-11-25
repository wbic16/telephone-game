#!/usr/bin/env ksh
. ~/telephone-ksh/port/src/phext.ksh
a=$(cat "$1"; printf '\x03'); a=${a%?}
b=$(cat "$2"; printf '\x03'); b=${b%?}
if bytes_eq "$a" "$b"; then print "bigeq yes"; else print "bigeq no"; fi
