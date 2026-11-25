#!/usr/bin/env ksh
. ~/telephone-ksh/port/src/phext.ksh
function big_eq {
    [[ ${#1} != ${#2} ]] && return 1
    typeset -i n=${#1} pos=0
    while (( pos < n )); do
        [[ ${1:pos:65536} == "${2:pos:65536}" ]] || return 1
        pos=$((pos + 65536))
    done
    return 0
}
f=$1; mode=$2
data=$(cat "$f"; printf '\x03'); data=${data%?}
case $mode in
  cmp) x=$data; if [[ $x == "$data" ]]; then print "cmp yes"; else print "cmp no"; fi;;
  bigeq) x=$data; if big_eq "$x" "$data"; then print "bigeq yes"; else print "bigeq no"; fi;;
  rt) explode "$data"; print "explode n=${#EXPL[@]}"; implode; print "implode len=${#RET}"; if big_eq "$RET" "$data"; then print "rt bigeq yes"; else print "rt bigeq NO"; fi; normalize "$data"; print "norm len=${#RET}"; if big_eq "$RET" "$data"; then print "norm bigeq yes"; else print "norm bigeq NO"; fi;;
esac
