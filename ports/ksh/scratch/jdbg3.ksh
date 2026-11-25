. ~/telephone-ksh/port/src/json.ksh
json_parse '{"cmd":"id"}'
print "root=$JROOT nc=${NC[$JROOT]} nk=${NK[$JROOT,1]} nch=${NCH[$JROOT,1]}"
typeset -a keys=()
typeset i
for (( i = 1; i <= ${NC[$JROOT]}; i++ )); do keys+=("${NK["$JROOT,$i"]}"); done
print "keys=${keys[@]} nkeys=${#keys[@]}"
jget "$JROOT" "${keys[0]}"; print "JG=$JG NT[JG]=${NT[$JG]} NS[JG]=${NS[$JG]}"
function wrap {
    typeset id=$1
    typeset -a keys=()
    typeset i
    for (( i = 1; i <= ${NC[$id]}; i++ )); do keys+=("${NK["$id,$i"]}"); done
    print "wrap keys=${keys[@]}"
    jget "$id" "${keys[0]}"
    print "wrap JG=$JG"
    _canon_into "$JG"
    print "wrap BUF=$JC_BUF"
}
JC_BUF=""; wrap $JROOT
