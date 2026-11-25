. ~/telephone-ksh/port/src/json.ksh
json_parse '{"cmd":"id"}'
function wrap2 {
    typeset id=$1 i
    typeset -a keys=()
    for (( i = 1; i <= ${NC[$id]}; i++ )); do keys+=("${NK["$id,$i"]}"); done
    typeset j tmp
    for (( i = 1; i < ${#keys[@]}; i++ )); do
        tmp=${keys[$i]}; j=$((i - 1))
        while (( j >= 0 )) && [[ ${keys[$j]} > $tmp ]]; do keys[$((j + 1))]=${keys[$j]}; j=$((j - 1)); done
        keys[$((j + 1))]=$tmp
    done
    JC_BUF+="{"
    for (( i = 0; i < ${#keys[@]}; i++ )); do
        (( i > 0 )) && JC_BUF+=","
        _canon_str "${keys[$i]}"
        JC_BUF+=$CANON_STR":"
        print "wrap2 JG before jget=$JG id=$id key=${keys[$i]}"
        jget "$id" "${keys[$i]}"
        print "wrap2 JG after jget=$JG"
        _canon_into "$JG"
    done
    JC_BUF+="}"
    print "wrap2 BUF=$JC_BUF"
}
JC_BUF=""; wrap2 $JROOT
