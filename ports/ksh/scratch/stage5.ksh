#!/usr/bin/env ksh
. ~/telephone-ksh/port/src/phext.ksh
function fd {
    typeset -a pieces
    typeset loc="1,1,1,1,1,1,1,1,1"
    typeset -i i
    pieces=()
    for (( i = 1; i <= PH_N; i++ )); do
        _advance "$loc" "${PH_COORD[$i]}"
        pieces+=("$ADV" "${PH_TEXT[$i]}")
        loc=$LOCSTR
    done
    print "fd loop ok npieces=${#pieces[@]}"
    typeset IFS=''
    RET="${pieces[*]}"
    print "fd join ok len=${#RET}"
}
function fd2 {
    typeset -a pieces; pieces=()
    typeset -i i
    for (( i = 1; i <= PH_N; i++ )); do pieces+=("" "${PH_TEXT[$i]}"); done
    print "fd2 loop ok npieces=${#pieces[@]}"
    typeset IFS=''
    RET="${pieces[*]}"
    print "fd2 join ok len=${#RET}"
}
f=$1; mode=$2
data=$(cat "$f"; printf '\x03'); data=${data%?}
phokenize "$data"; print "phok n=$PH_N"
case $mode in
  fd) fd;;
  fd2) fd2;;
  real) dephokenize; print "real ok len=${#RET}";;
esac
