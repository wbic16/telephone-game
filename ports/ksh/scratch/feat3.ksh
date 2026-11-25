data=$(cat "$1"; printf '\x03'); data=${data%?}
case $2 in
  regex) re='^[[:print:]]+$'; if [[ $data =~ $re ]]; then print "regex printable yes"; else print "regex printable no"; fi;;
  regexrun) re='^[^"\\]*'; rest=$data; if [[ $rest =~ $re ]]; then m=${.sh.match[0]}; print "regexrun len=${#m}"; fi;;
  glob) case $data in *[![:print:]]*) print "glob has nonprint";; *) print "glob all print";; esac;;
esac
