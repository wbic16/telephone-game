. ~/telephone-ksh/port/src/json.ksh
json_parse '{"cmd":"id","n":3}'
print "JROOT=$JROOT JERR=$JERR"
for k in "${!NT[@]}"; do print "node $k type=${NT[$k]} ns=${NS[$k]} nc=${NC[$k]}"; done
jget "$JROOT" cmd; print "JG=$JG val=${NS[$JG]}"
jobj_new; r=$JN_ID; print "obj id=$r"
jstr_new "ksh"; print "str id=$JN_ID type=${NT[$JN_ID]} ns=${NS[$JN_ID]}"
jobj_set $r impl $JN_ID
print "obj nc=${NC[$r]} nk=${NK[$r,1]} nch=${NCH[$r,1]}"
json_canon $r; print "CANON=$CANON"
