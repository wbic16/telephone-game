data=$(cat "$1"; printf '\x03'); data=${data%?}
case $2 in
  regex) if [[ $data =~ ^[[:print:]]+$ ]]; then print "regex printable yes"; else print "regex printable no"; fi;;
  regexrun) rest=$data; if [[ $rest =~ ^[^"\\]* ]]; then print "regexrun len=${#.sh.match[0]}"; fi;;
  glob) case $data in *[! -~]*) print "glob has nonprint";; *) print "glob all print";; esac;;
esac
