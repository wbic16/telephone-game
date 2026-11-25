. ~/telephone-ksh/port/src/json.ksh
function show { print "in func: NT[$1]=${NT[$1]} NS[$1]=${NS[$1]}"; }
jstr_new "ksh"; id=$JN_ID
print "top: NT[$id]=${NT[$id]} NS[$id]=${NS[$id]}"
show $id
json_canon $id; print "canon single=$CANON"
JC_BUF=""; _canon_into $id; print "direct _canon_into BUF=$JC_BUF"
json_parse '{"cmd":"id"}'
json_canon $JROOT; print "canon parsed=$CANON"
