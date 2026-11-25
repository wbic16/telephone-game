#!/usr/bin/env ksh
. ~/telephone-ksh/port/src/phext.ksh
f=$1; stage=$2
data=$(cat "$f"; printf '\x03'); data=${data%?}
print "read ok len=${#data}"
if [[ $stage == read ]]; then exit 0; fi
_encode_breaks "$data"
print "encode ok len=${#ENC}"
if [[ $stage == encode ]]; then exit 0; fi
if [[ $stage == split ]]; then
  enc=$ENC; enc+=$'\x03'
  typeset -a parts; typeset oldifs=$IFS; IFS=$'\x02'; set -f; parts=($enc); set +f; IFS=$oldifs
  print "split ok nparts=${#parts[@]}"
  exit 0
fi
explode "$data"
print "explode ok n=${#EXPL[@]}"
implode
print "implode ok len=${#RET} match=$([[ $RET == "$data" ]] && echo yes || echo no)"
