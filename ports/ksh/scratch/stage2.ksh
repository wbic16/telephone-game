#!/usr/bin/env ksh
. ~/telephone-ksh/port/src/phext.ksh
f=$1; stage=$2
data=$(cat "$f"; printf '\x03'); data=${data%?}
explode "$data"; print "explode ok n=${#EXPL[@]}"
if [[ $stage == explode ]]; then exit 0; fi
if [[ $stage == sorted ]]; then _sorted_expl_coords; print "sorted ok n=${#SORTED[@]} first=${SORTED[0]} last=${SORTED[-1]}"; exit 0; fi
if [[ $stage == implode ]]; then implode; print "implode ok len=${#RET} match=$([[ $RET == "$data" ]] && echo yes || echo no)"; exit 0; fi
if [[ $stage == normalize ]]; then normalize "$data"; print "normalize ok len=${#RET} match=$([[ $RET == "$data" ]] && echo yes || echo no)"; exit 0; fi
