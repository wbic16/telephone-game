#!/usr/bin/env ksh
. ~/telephone-ksh/port/src/phext.ksh
f=$1; stage=$2
data=$(cat "$f"; printf '\x03'); data=${data%?}
print "read len=${#data}"
case $stage in
  norm1) normalize "$data"; print "normalize ok len=${#RET} match=$([[ $RET == "$data" ]] && echo yes || echo no)";;
  phok) phokenize "$data"; print "phokenize ok n=$PH_N";;
  dephok) phokenize "$data"; print "phokenize ok n=$PH_N"; dephokenize; print "dephokenize ok len=${#RET} match=$([[ $RET == "$data" ]] && echo yes || echo no)";;
  join) typeset -a pieces; pieces=("" "$data"); typeset IFS=''; RET="${pieces[*]}"; print "join ok len=${#RET}";;
  copy) x=$data; print "copy ok len=${#x}"; y=$x; print "copy2 ok len=${#y}";;
esac
