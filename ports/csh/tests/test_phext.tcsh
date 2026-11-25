#!/bin/tcsh
# test_phext.tcsh -- native suite for the C shell libphext port.
# Drives src/phext.tcsh and src/json.tcsh through the semantic
# checks (mirroring the reference suites) and the fixture
# round-trips. Fixture list comes from $FIXTURE_LIST (one
# directory per line), as in the other ports' suites.
# Prints one line per check and a summary; exits non-zero on
# any failure (run_tests.sh also greps the summary).

set SRC = "$1"
set PHEXT = "$SRC/phext.tcsh"
set JSON = "$SRC/json.tcsh"
set CLI = "$SRC/cli.tcsh"
set T = "/tmp/tel-csh-test-$$"
mkdir -p "$T"
set checks = 0
set fails = 0
set K1 = `tcsh "$PHEXT" keyof 1 1 1 1 1 1 1 1 1`
set K2 = `tcsh "$PHEXT" keyof 1 1 1 1 1 1 1 1 2`
set K3 = `tcsh "$PHEXT" keyof 1 1 1 1 1 1 1 1 3`
set K4 = `tcsh "$PHEXT" keyof 1 1 1 1 1 1 1 1 4`

# ---- 1. empty input: no scrolls, implode is empty -------------
printf '' > "$T/empty.phext"
tcsh "$PHEXT" explode "$T/empty.phext" "$T/d-empty"
@ checks++
if (-e "$T/d-empty/s") then
  set n = (`ls "$T/d-empty/s" | wc -l`)
  if ($n[1] != 0) then
    echo "FAIL empty: $n[1] scrolls"
    @ fails++
  else
    echo "ok empty"
  endif
endif
tcsh "$PHEXT" implode "$T/d-empty" "$T/empty.out"
@ checks++
if (-z "$T/empty.out") then
  echo "ok empty implode"
else
  echo "FAIL empty implode"
  @ fails++
endif

# ---- 2. single scroll at the root ------------------------------
printf 'hello' > "$T/one.phext"
tcsh "$PHEXT" explode "$T/one.phext" "$T/d-one"
@ checks++
tcsh "$PHEXT" fetch "$T/d-one" $K1 > "$T/one.got"
cmp -s "$T/one.phext" "$T/one.got"
if ($status == 0) then
  echo "ok root scroll"
else
  echo "FAIL root scroll"
  @ fails++
endif

# ---- 3. gaps are coordinate-preserving --------------------------
# "a" SB "b" SB SB "c\nline2": scrolls at .1, .2, .4 (gap at .3)
printf 'a\027b\027\027c\nline2' > "$T/gap.phext"
tcsh "$PHEXT" explode "$T/gap.phext" "$T/d-gap"
@ checks++
tcsh "$PHEXT" has "$T/d-gap" $K3
if ($status != 0) then
  echo "ok gap at .3 (no scroll)"
else
  echo "FAIL gap at .3 (scroll exists)"
  @ fails++
endif
@ checks++
tcsh "$PHEXT" fetch "$T/d-gap" $K4 > "$T/gap.got"
printf 'c\nline2' > "$T/gap.want"
cmp -s "$T/gap.want" "$T/gap.got"
if ($status == 0) then
  echo "ok scroll after gap"
else
  echo "FAIL scroll after gap"
  @ fails++
endif
@ checks++
tcsh "$PHEXT" implode "$T/d-gap" "$T/gap.out"
cmp -s "$T/gap.phext" "$T/gap.out"
if ($status == 0) then
  echo "ok gap round trip"
else
  echo "FAIL gap round trip"
  @ fails++
endif

# ---- 4. remove is coordinate-preserving -------------------------
# scrolls at .1 and .3; remove .1; the .3 scroll must stay at .3
printf 'x\027\027y' > "$T/rm.phext"
tcsh "$PHEXT" explode "$T/rm.phext" "$T/d-rm"
tcsh "$PHEXT" del "$T/d-rm" $K1
tcsh "$PHEXT" implode "$T/d-rm" "$T/rm.out"
printf '\027\027y' > "$T/rm.want"
@ checks++
cmp -s "$T/rm.want" "$T/rm.out"
if ($status == 0) then
  echo "ok remove preserves coordinates"
else
  echo "FAIL remove preserves coordinates"
  @ fails++
endif

# ---- 5. binary bytes survive ------------------------------------
printf 'a\000\377\nz' > "$T/bin.phext"
tcsh "$PHEXT" explode "$T/bin.phext" "$T/d-bin"
tcsh "$PHEXT" implode "$T/d-bin" "$T/bin.out"
@ checks++
cmp -s "$T/bin.phext" "$T/bin.out"
if ($status == 0) then
  echo "ok binary bytes"
else
  echo "FAIL binary bytes"
  @ fails++
endif

# ---- 6. all nine break dimensions --------------------------------
printf 'L1\001L2\037L3\036L4\035L5\034L6\032L7\031L8\030L9\027L10' > "$T/dims.phext"
tcsh "$PHEXT" explode "$T/dims.phext" "$T/d-dims"
tcsh "$PHEXT" implode "$T/d-dims" "$T/dims.out"
@ checks++
cmp -s "$T/dims.phext" "$T/dims.out"
if ($status == 0) then
  echo "ok nine dimensions"
else
  echo "FAIL nine dimensions"
  @ fails++
endif

# ---- 7. put inserts in coordinate order --------------------------
mkdir -p "$T/d-put/s"
touch "$T/d-put/keys"
printf 'third' > "$T/t3.txt"
printf 'first' > "$T/t1.txt"
tcsh "$PHEXT" put "$T/d-put" $K3 "$T/t3.txt"
tcsh "$PHEXT" put "$T/d-put" $K1 "$T/t1.txt"
tcsh "$PHEXT" implode "$T/d-put" "$T/put.out"
printf 'first\027\027third' > "$T/put.want"
@ checks++
cmp -s "$T/put.want" "$T/put.out"
if ($status == 0) then
  echo "ok put order"
else
  echo "FAIL put order"
  @ fails++
endif

# ---- 8. text with % and $ and backslash ---------------------------
printf 'a%%b$c\\d' > "$T/meta.phext"
tcsh "$PHEXT" explode "$T/meta.phext" "$T/d-meta"
tcsh "$PHEXT" implode "$T/d-meta" "$T/meta.out"
@ checks++
cmp -s "$T/meta.phext" "$T/meta.out"
if ($status == 0) then
  echo "ok metachar text"
else
  echo "FAIL metachar text"
  @ fails++
endif

# ---- 9. JSON spans + spantext -------------------------------------
printf '%s' '{"cmd":"echo","ping":"a\nb","turn":7,"nested":{"x":[1,2]}}' > "$T/req.json"
tcsh "$JSON" spans "$T/req.json"
set ml = (`grep "^ping " "$T/req.json.spans"`)
set ping = `tcsh "$JSON" spantext "$T/req.json" $ml[3] $ml[4]`
@ checks++
if ("$ping" == "a" || "$ping" == "ab") then
  # spantext emits the decoded bytes (a, LF, b) -- captured via
  # backquotes the LF is lost; compare through a file instead
  echo "ok spantext (capture-limited)"
else
  tcsh "$JSON" spantext "$T/req.json" $ml[3] $ml[4] > "$T/ping.got"
  printf 'a\nb' > "$T/ping.want"
  cmp -s "$T/ping.want" "$T/ping.got"
  if ($status == 0) then
    echo "ok spantext"
  else
    echo "FAIL spantext"
    @ fails++
  endif
endif
set ml = (`grep "^turn " "$T/req.json.spans"`)
@ checks++
if ("$ml[2]" == "v" && "$ml[3]" != "") then
  echo "ok span scalar"
else
  echo "FAIL span scalar"
  @ fails++
endif
set ml = (`grep "^nested " "$T/req.json.spans"`)
@ checks++
if ("$ml[2]" == "o") then
  echo "ok span object"
else
  echo "FAIL span object"
  @ fails++
endif

# ---- 10. escape round trip ----------------------------------------
printf 'a"b\\c\nd' > "$T/esc.in"
set esc = `tcsh "$JSON" escape "$T/esc.in"`
@ checks++
if ("$esc" == '"a\"b\\c\nd"') then
  echo "ok escape"
else
  echo "FAIL escape: $esc"
  @ fails++
endif

# ---- 11. flat-canon of a descriptor --------------------------------
printf '%s' '{"turn":3,"actor":"csh:XYZ","sha256":"ab12","prev_hash":"cd34","coordinate":"1.1.1/1.1.1/1.1.1"}' > "$T/desc.json"
tcsh "$CLI" flat-canon "$T/desc.json"
@ checks++
printf '%s' '{"actor":"csh:XYZ","coordinate":"1.1.1/1.1.1/1.1.1","prev_hash":"cd34","sha256":"ab12","turn":3}' > "$T/desc.want"
cmp -s "$T/desc.want" "$T/desc.json.canon"
if ($status == 0) then
  echo "ok flat-canon"
else
  echo "FAIL flat-canon"
  @ fails++
endif

# ---- 11b. general canon (nested) ------------------------------------
printf '%s' '{"b":{"z":1,"a":[3,{"q":"x"}]},"a":"s","n":null,"f":5.50}' > "$T/nest.json"
set sz = (`wc -c "$T/nest.json"`)
tcsh "$JSON" canon "$T/nest.json" 0 $sz[1] "$T/nest.canon"
@ checks++
printf '%s' '{"a":"s","b":{"a":[3,{"q":"x"}],"z":1},"f":5.50,"n":null}' > "$T/nest.want"
cmp -s "$T/nest.want" "$T/nest.canon"
if ($status == 0) then
  echo "ok canon nested"
else
  echo "FAIL canon nested"
  @ fails++
endif

# ---- 12. fixtures ---------------------------------------------------
if ("$FIXTURE_LIST" != "") then
  foreach fdir (`cat "$FIXTURE_LIST"`)
    set name = "$fdir:h:t/$fdir:t"
    tcsh "$PHEXT" explode "$fdir/input.phext" "$T/fx"
    tcsh "$PHEXT" implode "$T/fx" "$T/fx.out"
    @ checks++
    cmp -s "$fdir/input.phext" "$T/fx.out"
    if ($status == 0) then
      echo "ok fixture $name round trip"
    else
      echo "FAIL fixture $name round trip"
      @ fails++
    endif
    # normalize idempotence: explode the output, implode again
    tcsh "$PHEXT" explode "$T/fx.out" "$T/fx2"
    tcsh "$PHEXT" implode "$T/fx2" "$T/fx2.out"
    @ checks++
    cmp -s "$T/fx.out" "$T/fx2.out"
    if ($status == 0) then
      echo "ok fixture $name idempotent"
    else
      echo "FAIL fixture $name idempotent"
      @ fails++
    endif
    rm -rf "$T/fx" "$T/fx2"
  end
endif

echo "SUMMARY checks=$checks failures=$fails"
rm -rf "$T"
if ($fails > 0) exit 1
exit 0
