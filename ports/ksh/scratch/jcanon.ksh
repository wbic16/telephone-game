. ~/telephone-ksh/port/src/json.ksh
ev=$(cat "$1"; printf '\x03'); ev=${ev%?}
json_parse "$ev"
print "root=$JROOT err=$JERR"
jget "$JROOT" body; b=$JG
json_canon "$b"
print "CANON=$CANON"
