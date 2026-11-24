#!/bin/bash
# test_phext.sh -- unit + conformance tests for the Bash libphext port.
# Run on the hub:  bash tests/run_tests.sh
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/../src/phext.sh"

FAILURES=0
check() {
    if [[ $1 == 0 ]]; then echo "ok - $2"; else echo "FAIL - $2"; FAILURES=$((FAILURES + 1)); fi
}
eq() { [[ $1 == "$2" ]]; }

coord_parse "2.3.4/5.6.7/8.9.10"; coord_str "$CP"; eq "$CS" "2.3.4/5.6.7/8.9.10"; check $? "coord round-trip"
coord_cmp "$(coord_parse '1.1.1/1.1.1/1.1.2'; echo $CP)" "$(coord_parse '1.1.1/1.1.1/1.1.10'; echo $CP)"
# (coord_parse sets CP; capture inline above via subshell is fine for parsing only)
c1=$(coord_parse "1.1.1/1.1.1/1.1.2"; echo "$CP"); c2=$(coord_parse "1.1.1/1.1.1/1.1.10"; echo "$CP")
coord_cmp "$c1" "$c2"; (( CMP < 0 )); check $? "coord order"
coord_parse "1.1.1/1.1.1/1.1.0"; [[ -z $CP ]]; check $? "coord rejects 0"
coord_parse "1.1.1/1.1.1"; [[ -z $CP ]]; check $? "coord rejects short"

sb=$'\x17'; sc=$'\x18'
buf="alpha${sb}beta${sc}gamma"
C() { coord_parse "$1"; echo "$CP"; }
fetch "$buf" "$(C '1.1.1/1.1.1/1.1.1')"; eq "$RET" "alpha"; check $? "fetch first"
fetch "$buf" "$(C '1.1.1/1.1.1/1.1.2')"; eq "$RET" "beta"; check $? "fetch scroll 2"
fetch "$buf" "$(C '1.1.1/1.1.1/1.2.1')"; eq "$RET" "gamma"; check $? "fetch section 2 scroll 1"
fetch "$buf" "$(C '1.1.1/1.1.1/1.1.9')"; eq "$RET" ""; check $? "fetch gap is empty"
normalize "$buf"; eq "$RET" "$buf"; check $? "normalize idempotent on canonical"

insert "" "$(C '1.1.1/1.1.1/1.1.2')" "second"; b2=$RET
fetch "$b2" "$(C '1.1.1/1.1.1/1.1.2')"; eq "$RET" "second"; check $? "insert creates"
insert "$b2" "$(C '1.1.1/1.1.1/1.1.2')" "+more"; b2=$RET
fetch "$b2" "$(C '1.1.1/1.1.1/1.1.2')"; eq "$RET" "second+more"; check $? "insert concatenates"
replace "$b2" "$(C '1.1.1/1.1.1/1.1.2')" "replaced"; b2=$RET
fetch "$b2" "$(C '1.1.1/1.1.1/1.1.2')"; eq "$RET" "replaced"; check $? "replace overwrites"

b3="one${sb}two${sb}three"
remove "$b3" "$(C '1.1.1/1.1.1/1.1.2')"; b3r=$RET
fetch "$b3r" "$(C '1.1.1/1.1.1/1.1.1')"; eq "$RET" "one"; check $? "remove keeps first"
fetch "$b3r" "$(C '1.1.1/1.1.1/1.1.2')"; eq "$RET" ""; check $? "remove empties target"
fetch "$b3r" "$(C '1.1.1/1.1.1/1.1.3')"; eq "$RET" "three"; check $? "remove does not shift later scrolls"

insert "" "$(C '3.1.4/1.5.9/2.6.5')" "far"; gap=$RET
explode "$gap"; implode; eq "$RET" "$gap"; check $? "explode/implode gap round-trip"

coords=("1.1.1/1.1.1/1.1.1" "1.1.1/1.1.1/1.1.2" "1.1.1/1.1.1/1.2.1" "2.1.1/1.1.1/1.1.1" "1.1.1/1.1.1/1.1.3")
dyn_init ""; trn_init ""
buf2=""
for i in 0 1 2 3 4; do
    cc=$(C "${coords[$i]}")
    insert "$buf2" "$cc" "text$((i + 1))"; buf2=$RET
    dyn_insert "$cc" "text$((i + 1))"
    trn_insert "$cc" "text$((i + 1))"
    dyn_serialize; eq "$RET" "$buf2"; check $? "dynamic == buffer after insert $((i + 1))"
    trn_serialize; eq "$RET" "$buf2"; check $? "transitive == buffer after insert $((i + 1))"
done
mid=$(C '1.1.1/1.1.1/1.1.2')
remove "$buf2" "$mid"; buf2=$RET
dyn_remove "$mid"; trn_remove "$mid"
dyn_serialize; eq "$RET" "$buf2"; check $? "dynamic == buffer after remove"
trn_serialize; eq "$RET" "$buf2"; check $? "transitive == buffer after remove"
dyn_fetch "$mid"; d1=$RET; trn_fetch "$mid"; eq "$d1$RET" ""; check $? "stores fetch removed as empty"
(( DYN_N == 4 && TRN_N == 4 )); check $? "store lengths"
dyn_replace "$(C '1.1.1/1.1.1/1.1.1')" ""
remove "$buf2" "$(C '1.1.1/1.1.1/1.1.1')"; buf2=$RET
dyn_serialize; eq "$RET" "$buf2"; check $? "dynamic replace-empty removes"

# shared fixtures: 16/16 byte-identical round-trips
FIXTURES=${PHEXT_FIXTURES:-$HOME/telephone-bash/fixtures}
mapfile -t files < <(find "$FIXTURES" -name input.phext | sort)
(( ${#files[@]} == 16 )); check $? "found 16 fixture inputs (got ${#files[@]})"
okc=0
for f in "${files[@]}"; do
    IFS= read -r -d '' data < "$f" || true
    explode "$data"; implode
    if [[ $RET == "$data" ]]; then
        normalize "$data"; n1=$RET
        normalize "$n1"
        if [[ $RET == "$n1" ]]; then okc=$((okc + 1)); else echo "FAIL - fixture normalize not idempotent: $f"; FAILURES=$((FAILURES + 1)); fi
    else
        echo "FAIL - fixture round-trip: $f"; FAILURES=$((FAILURES + 1))
    fi
done
(( okc == 16 )); check $? "fixtures round-trip $okc/16"

if (( FAILURES > 0 )); then echo "FAILURES: $FAILURES"; exit 1; fi
echo "PASS"
