#!/usr/bin/env ksh
. ~/telephone-ksh/port/src/phext.ksh
f=$1; mode=$2
data=$(cat "$f"; printf '\x03'); data=${data%?}
case $mode in
  cmp) x=$data; if [[ $x == "$data" ]]; then print "cmp ok yes"; else print "cmp ok no"; fi;;
  cmpsub) m=$([[ $data == "$data" ]] && echo yes || echo no); print "cmpsub ok $m";;
  norm) normalize "$data"; print "norm len=${#RET}";;
  normcmp) normalize "$data"; print "norm len=${#RET}"; if [[ $RET == "$data" ]]; then print "cmp yes"; else print "cmp NO"; fi;;
  rt) explode "$data"; print "explode n=${#EXPL[@]}"; implode; print "implode len=${#RET}"; if [[ $RET == "$data" ]]; then print "rt cmp yes"; else print "rt cmp NO"; fi;;
esac
