#!/bin/sh
# Build the Modula-2 telephone binaries on aletheia-core.
# gm2 13 quirks handled here:
#  - library modules are compiled with -c (a one-shot multi-module
#    compile gives every module its own main);
#  - user objects reference library/RTS symbols unprefixed while
#    Ubuntu's libm2* only exports m2pim_-prefixed ones, so a thunk
#    object of jmp aliases is generated from the undefined list.
set -e
H=$HOME/telephone-modula2
W=$H/bin/gm2wrap.sh
S=$H/src
T=$H/tests
B=$H/build
SYS="-B/usr/lib/gcc/x86_64-linux-gnu/13/ -L/usr/lib/gcc/x86_64-linux-gnu/13"
mkdir -p $B
for m in BStr Phext Json; do
  $W -fpim -I$S -c $S/$m.mod -o $B/$m.o
done
# pass 1: discover undefined symbols of a test link, build thunks
$W $SYS -fpim -I$S -I$T -o $B/test_phext $T/TestPhext.mod $B/BStr.o $B/Phext.o $B/Json.o 2>&1 \
  | grep -oE "undefined reference to \`[A-Za-z0-9_]+'" | sed "s/undefined reference to \`//;s/'//" \
  | sort -u > $B/undef.txt || true
RT=$H/gm2deb/usr/lib/x86_64-linux-gnu
: > $B/symmap.txt
for f in $RT/libm2pim.so.18 $RT/libm2iso.so.18 $RT/libm2cor.so.18 $RT/libm2log.so.18 $RT/libm2min.so.18; do
  nm -D "$f" 2>/dev/null | grep -E " T m2" | sed 's/.* T //' | while read -r full; do
    rest=$(echo "$full" | sed 's/^m2[a-z]*_//')
    echo "$rest $full" >> $B/symmap.txt
  done
done
sort -u $B/symmap.txt > $B/symmap2.txt && mv $B/symmap2.txt $B/symmap.txt
: > $B/thunk.s
while read -r sym; do
  case "$sym" in
    _M2_*) stripped=$(echo "$sym" | sed 's/^_//') ;;
    *) stripped="$sym" ;;
  esac
  tgt=$(grep -E "^$stripped " $B/symmap.txt | grep " m2pim_" | head -1 | cut -d' ' -f2)
  if [ -z "$tgt" ]; then tgt=$(grep -E "^$stripped " $B/symmap.txt | head -1 | cut -d' ' -f2); fi
  if [ -n "$tgt" ]; then printf '.globl %s\n%s: jmp %s\n' "$sym" "$sym" "$tgt" >> $B/thunk.s; fi
done < $B/undef.txt
gcc -c -o $B/thunk.o $B/thunk.s
# pass 2: real links
$W $SYS -fpim -I$S -I$T -o $B/test_phext $T/TestPhext.mod $B/BStr.o $B/Phext.o $B/Json.o $B/thunk.o
$W $SYS -fpim -I$S -o $B/telephone $S/Telephone.mod $B/BStr.o $B/Phext.o $B/Json.o $B/thunk.o
echo BUILD_OK
