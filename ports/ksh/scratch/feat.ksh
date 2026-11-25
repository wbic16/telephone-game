x="abc123def"
if [[ $x =~ ^[a-z]+ ]]; then print "match1=${.sh.match[0]}"; fi
rest=${x:3}
if [[ $rest =~ ^[-+0-9.eE]+ ]]; then print "match2=${.sh.match[0]}"; fi
s="hello world tail"
print "neg=${s: -4}"
typeset -a f; IFS=' ' read -A f <<< "1.1.1/1.1.1/1.1.1 abc123 actor"
print "f0=${f[0]} f1=${f[1]} f2=${f[2]} n=${#f[@]}"
printf -v v '%02x' 65; print "printfv=$v"
printf 'line1\nline2\n' > /tmp/feat-test.txt
RF=""; IFS= read -r -d '' RF < /tmp/feat-test.txt || true; print "readD len=${#RF}"
typeset -A A; A["k"]=1; print "assoc=${A[k]}"
h=$((16#ff)); print "hex=$h"
