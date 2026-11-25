function dosort {
    typeset -a keys=()
    keys=("type" "turn" "actor" "elect_by" "coord" "text_sha256" "file_sha256" "att" "echoes" "consensus_prev")
    typeset i j tmp
    for (( i = 1; i < ${#keys[@]}; i++ )); do
        tmp=${keys[$i]}; j=$((i - 1))
        while (( j >= 0 )) && [[ ${keys[$j]} > $tmp ]]; do
            keys[$((j + 1))]=${keys[$j]}; j=$((j - 1))
        done
        keys[$((j + 1))]=$tmp
        print "i=$i tmp=$tmp keys=${keys[@]}"
    done
    print "final: ${keys[@]}"
}
dosort
