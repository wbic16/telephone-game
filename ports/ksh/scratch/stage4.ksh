#!/usr/bin/env ksh
. ~/telephone-ksh/port/src/phext.ksh
f=$1; mode=$2
data=$(cat "$f"; printf '\x03'); data=${data%?}
phokenize "$data"; print "phok n=$PH_N textlen=${#PH_TEXT[1]}"
case $mode in
  inline)
    typeset -a pieces; typeset loc="1,1,1,1,1,1,1,1,1"; typeset -i i; pieces=()
    for (( i = 1; i <= PH_N; i++ )); do _advance "$loc" "${PH_COORD[$i]}"; pieces+=("$ADV" "${PH_TEXT[$i]}"); loc=$LOCSTR; done
    print "loop ok npieces=${#pieces[@]}"
    typeset IFS=''; RET="${pieces[*]}"; print "join ok len=${#RET}";;
  funcjoin)
    function fj { typeset -a p; p=("" "$1"); typeset IFS=''; RET="${p[*]}"; }
    fj "$data"; print "funcjoin ok len=${#RET}";;
  advonly)
    _advance "1,1,1,1,1,1,1,1,1" "${PH_COORD[1]}"; print "advance ok ADVlen=${#ADV} LOC=$LOCSTR";;
  joinnoadv)
    typeset -a pieces; pieces=(); typeset -i i
    for (( i = 1; i <= PH_N; i++ )); do pieces+=("" "${PH_TEXT[$i]}"); done
    print "loop ok npieces=${#pieces[@]}"
    typeset IFS=''; RET="${pieces[*]}"; print "join ok len=${#RET}";;
esac
