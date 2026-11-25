#!/bin/tcsh
# json.tcsh -- minimal JSON machinery for the C shell port.
#
# tcsh has no substring operations, so JSON is processed in the
# byte-token domain (od -An -v -tu1 -w1: one decimal byte per
# line; token index == byte offset in the source file).
#
# Subcommands:
#   spans <file>
#       writes <file>.spans with one line per top-level object
#       member:  <key> <kind> <start> <end>
#       kind: s = string (start..end = raw content span between
#       the quotes), v = value (start..end = whole value span),
#       o = object/array (whole span). Indices are byte offsets
#       into <file>, end exclusive.
#   spantext <file> <start> <end>
#       decodes a string content span (JSON escapes) to stdout.
#   spanraw <file> <start> <end> <out>
#       copies the raw byte span to <out> (dd; no tcsh loop).
# Canonical JSON is never re-serialized from a parsed value in
# this port: the CLI builds canonical strings itself from
# fields (sorted by construction) and escapes with the escape
# subcommand. The one re-serialization the contract needs --
# echo's ping -- is a scalar or string in all driver traffic:
# scalars are verbatim-canonical, strings go through
# spantext + escape.

set bs = '\'

if ("$1" == "spanraw") then
  @ len = $4 - $3
  if ($len <= 0) then
    touch "$5"
  else
    dd if="$2" of="$5" bs=1 skip=$3 count=$len status=none
  endif
  exit 0
endif

# ---- tokenize helper: produce <file>.toks ----------------------
# (callers run: json.tcsh spans/canon which tokenize first)

if ("$1" == "spans") then
  od -An -v -tu1 -w1 "$2" | tr -d ' ' > "$2.toks"
  tcsh "$0" spans-walk "$2" < "$2.toks"
  exit 0
endif

if ("$1" == "spans-walk") then
  set file = "$2"
  rm -f "$file.spans"
  touch "$file.spans"
  set pos = 0
  set depth = 0
  set state = 0
  # state: 0 seek '{' ; 1 in object, want key or '}' ;
  #        2 in key string ; 3 want ':' ; 4 want value ;
  #        5 in value (sub-walk decides by first byte)
  set key = ""
  set keystart = 0
  set keyend = 0
  set esc = 0
  while (1)
    set b = $<
    if ("$b" == "") break
    if ($state == 0) then
      if ($b == 123) then
        set depth = 1
        set state = 1
      endif
    else if ($state == 1) then
      if ($b == 34) then
        set key = ""
        @ keystart = $pos + 1
        set esc = 0
        set state = 2
      else if ($b == 125) then
        set depth = 0
        break
      endif
    else if ($state == 2) then
      if ($esc == 1) then
        set esc = 0
      else if ($b == 92) then
        set esc = 1
      else if ($b == 34) then
        set keyend = $pos
        # decode the key (short ASCII) from the file by span
        set key = `tcsh "$0" spantext "$file" $keystart $keyend`
        set state = 3
      endif
    else if ($state == 3) then
      if ($b == 58) set state = 4
    else if ($state == 4) then
      if ($b == 34) then
        # string value: content span
        @ vs = $pos + 1
        set esc = 0
        set state = 6
      else if ($b == 123 || $b == 91) then
        set vs = $pos
        set vdepth = 1
        set instr = 0
        set esc = 0
        set state = 7
      else if ($b == 32 || $b == 9 || $b == 10 || $b == 13) then
        # skip whitespace, stay in state 4
      else
        set vs = $pos
        set state = 8
      endif
    else if ($state == 6) then
      if ($esc == 1) then
        set esc = 0
      else if ($b == 92) then
        set esc = 1
      else if ($b == 34) then
        echo "$key s $vs $pos" >> "$file.spans"
        set state = 9
      endif
    else if ($state == 7) then
      if ($instr == 1) then
        if ($esc == 1) then
          set esc = 0
        else if ($b == 92) then
          set esc = 1
        else if ($b == 34) then
          set instr = 0
        endif
      else if ($b == 34) then
        set instr = 1
        set esc = 0
      else if ($b == 123 || $b == 91) then
        @ vdepth++
      else if ($b == 125 || $b == 93) then
        @ vdepth--
        if ($vdepth == 0) then
          @ ve = $pos + 1
          echo "$key o $vs $ve" >> "$file.spans"
          set state = 9
        endif
      endif
    else if ($state == 8) then
      if ($b == 44 || $b == 125) then
        echo "$key v $vs $pos" >> "$file.spans"
        if ($b == 125) then
          set depth = 0
          break
        endif
        set state = 1
      endif
    else if ($state == 9) then
      if ($b == 44) then
        set state = 1
      else if ($b == 125) then
        set depth = 0
        break
      endif
    endif
    @ pos++
  end
  exit 0
endif

if ("$1" == "spantext") then
  # decode string content span $3..$4 of file $2 to stdout
  set file = "$2"
  @ len = $4 - $3
  if ($len <= 0) exit 0
  dd if="$file" bs=1 skip=$3 count=$len status=none > "$file.span"
  od -An -v -tu1 -w1 "$file.span" | tr -d ' ' > "$file.span.toks"
  tcsh "$0" spantext-walk < "$file.span.toks"
  rm -f "$file.span" "$file.span.toks"
  exit 0
endif

if ("$1" == "spantext-walk") then
  # tokens on stdin; emit decoded bytes via octal escapes + %b
  set out = ""
  set esc = 0
  set uni = 0
  set uval = 0
  while (1)
    set b = $<
    if ("$b" == "") break
    if ($uni == 1) then
      # hex digit of \uXXXX (only ASCII range fully supported)
      set d = 0
      if ($b >= 48 && $b <= 57) @ d = $b - 48
      if ($b >= 97 && $b <= 102) @ d = $b - 87
      if ($b >= 65 && $b <= 70) @ d = $b - 55
      @ uval = $uval * 16 + $d
      @ unicount++
      if ($unicount == 4) then
        set uni = 0
        if ($uval < 128) then
          @ o1 = $uval / 64
          @ o2 = ($uval / 8) % 8
          @ o3 = $uval % 8
          set out = "$out$bs$o1$o2$o3"
        else
          # non-ASCII \u: emit UTF-8 two-byte form
          @ hi = 192 + $uval / 64
          @ lo = 128 + $uval % 64
          @ o1 = $hi / 64
          @ o2 = ($hi / 8) % 8
          @ o3 = $hi % 8
          set out = "$out$bs$o1$o2$o3"
          @ o1 = $lo / 64
          @ o2 = ($lo / 8) % 8
          @ o3 = $lo % 8
          set out = "$out$bs$o1$o2$o3"
        endif
      endif
    else if ($esc == 1) then
      set esc = 0
      switch ($b)
        case 110:
          set out = "$out${bs}012"
          breaksw
        case 116:
          set out = "$out${bs}011"
          breaksw
        case 114:
          set out = "$out${bs}015"
          breaksw
        case 98:
          set out = "$out${bs}010"
          breaksw
        case 102:
          set out = "$out${bs}014"
          breaksw
        case 117:
          set uni = 1
          set uval = 0
          set unicount = 0
          breaksw
        default:
          @ o1 = $b / 64
          @ o2 = ($b / 8) % 8
          @ o3 = $b % 8
          set out = "$out$bs$o1$o2$o3"
          breaksw
      endsw
    else if ($b == 92) then
      set esc = 1
    else
      @ o1 = $b / 64
      @ o2 = ($b / 8) % 8
      @ o3 = $b % 8
      set out = "$out$bs$o1$o2$o3"
    endif
  end
  /usr/bin/printf '%b' "$out"
  exit 0
endif

if ("$1" == "array-strings") then
  # print each string element of the array span $3..$4 of file
  # $2, one decoded element per line
  tcsh "$0" spanraw "$2" $3 $4 "$2.arr"
  od -An -v -tu1 -w1 "$2.arr" | tr -d ' ' > "$2.arr.toks"
  tcsh "$0" array-strings-walk < "$2.arr.toks"
  rm -f "$2.arr" "$2.arr.toks"
  exit 0
endif

if ("$1" == "array-strings-walk") then
  set out = ""
  set instr = 0
  set esc = 0
  while (1)
    set b = $<
    if ("$b" == "") break
    if ($instr == 0) then
      if ($b == 34) then
        set instr = 1
        set out = ""
        set esc = 0
      endif
    else if ($esc == 1) then
      set esc = 0
      @ o1 = $b / 64
      @ o2 = ($b / 8) % 8
      @ o3 = $b % 8
      set out = "$out$bs$o1$o2$o3"
    else if ($b == 92) then
      set esc = 1
      set out = "$out${bs}134"
    else if ($b == 34) then
      set instr = 0
      /usr/bin/printf '%b\n' "$out"
    else
      @ o1 = $b / 64
      @ o2 = ($b / 8) % 8
      @ o3 = $b % 8
      set out = "$out$bs$o1$o2$o3"
    endif
  end
  exit 0
endif

if ("$1" == "elems") then
  # writes <file>.elems with one line per top-level ARRAY
  # element: <kind> <start> <end> (same kind codes as spans)
  od -An -v -tu1 -w1 "$2" | tr -d ' ' > "$2.toks"
  tcsh "$0" elems-walk "$2" < "$2.toks"
  exit 0
endif

if ("$1" == "elems-walk") then
  set file = "$2"
  rm -f "$file.elems"
  touch "$file.elems"
  set pos = 0
  set state = 0
  # 0 seek '[' ; 1 want element or ']' ; 2 in string element ;
  # 3 in compound element ; 4 in scalar element ; 5 after element
  set esc = 0
  while (1)
    set b = $<
    if ("$b" == "") break
    if ($state == 0) then
      if ($b == 91) set state = 1
    else if ($state == 1) then
      if ($b == 34) then
        @ vs = $pos + 1
        set esc = 0
        set state = 2
      else if ($b == 123 || $b == 91) then
        set vs = $pos
        set vdepth = 1
        set instr = 0
        set esc = 0
        set state = 3
      else if ($b == 93) then
        break
      else if ($b == 32 || $b == 9 || $b == 10 || $b == 13) then
        # skip whitespace
      else
        set vs = $pos
        set state = 4
      endif
    else if ($state == 2) then
      if ($esc == 1) then
        set esc = 0
      else if ($b == 92) then
        set esc = 1
      else if ($b == 34) then
        echo "s $vs $pos" >> "$file.elems"
        set state = 5
      endif
    else if ($state == 3) then
      if ($instr == 1) then
        if ($esc == 1) then
          set esc = 0
        else if ($b == 92) then
          set esc = 1
        else if ($b == 34) then
          set instr = 0
        endif
      else if ($b == 34) then
        set instr = 1
        set esc = 0
      else if ($b == 123 || $b == 91) then
        @ vdepth++
      else if ($b == 125 || $b == 93) then
        @ vdepth--
        if ($vdepth == 0) then
          @ ve = $pos + 1
          echo "o $vs $ve" >> "$file.elems"
          set state = 5
        endif
      endif
    else if ($state == 4) then
      if ($b == 44 || $b == 93) then
        echo "v $vs $pos" >> "$file.elems"
        if ($b == 93) break
        set state = 1
      endif
    else if ($state == 5) then
      if ($b == 44) then
        set state = 1
      else if ($b == 93) then
        break
      endif
    endif
    @ pos++
  end
  exit 0
endif

if ("$1" == "canon") then
  # canon <file> <start> <end> <out>: canonical JSON (sorted
  # keys, tight separators, ensure-ascii) of the value span,
  # written to <out>. Recursive by self-invocation per member /
  # element; fragments always travel as files (a canonical
  # value's braces can never sit in a tcsh variable).
  set file = "$2"
  set start = $3
  set end = $4
  set out = "$5"
  set tmp = "$out.part"
  tcsh "$0" spanraw "$file" $start $end "$tmp"
  set fb = `head -c 1 "$tmp" | od -An -tu1 | tr -d ' '`
  if ("$fb" == "123") then
    # object: members sorted by key
    tcsh "$0" spans "$tmp"
    sort "$tmp.spans" > "$tmp.sorted"
    /usr/bin/printf '{' > "$out"
    tcsh "$0" canon-obj-walk "$tmp" "$out" < "$tmp.sorted"
    /usr/bin/printf '}' >> "$out"
  else if ("$fb" == "91") then
    tcsh "$0" elems "$tmp"
    /usr/bin/printf '[' > "$out"
    tcsh "$0" canon-arr-walk "$tmp" "$out" < "$tmp.elems"
    /usr/bin/printf ']' >> "$out"
  else if ("$fb" == "34") then
    # string: decode the content span, re-escape canonically
    @ len = $end - $start
    @ cs = 1
    @ ce = $len - 1
    tcsh "$0" spantext "$tmp" $cs $ce > "$tmp.dec"
    tcsh "$0" escape "$tmp.dec" > "$out"
  else
    cp "$tmp" "$out"
  endif
  rm -f "$tmp" "$tmp.spans" "$tmp.sorted" "$tmp.elems" "$tmp.dec" "$tmp.toks"
  exit 0
endif

if ("$1" == "canon-obj-walk") then
  # stdin: sorted member lines "key kind start end" of $2;
  # appends  "key":<canon>  (comma-separated) to $3
  set file = "$2"
  set out = "$3"
  set first = 1
  while (1)
    set line = "$<"
    if ("$line" == "") break
    set w = ($line)
    if ($first == 0) /usr/bin/printf ',' >> "$out"
    set first = 0
    # $w[1] is the member name (spans records it decoded);
    # its canonical form is escape(name)
    /usr/bin/printf '%s' "$w[1]" > "$file.kv"
    set kesc = `tcsh "$0" escape "$file.kv"`
    /usr/bin/printf '%s' "$kesc" >> "$out"
    /usr/bin/printf ':' >> "$out"
    if ($w[2] == "s") then
      # string member: spans recorded the content span;
      # canon = escape(decoded content)
      tcsh "$0" spantext "$file" $w[3] $w[4] > "$file.vv"
      tcsh "$0" escape "$file.vv" >> "$out"
    else
      tcsh "$0" canon "$file" $w[3] $w[4] "$file.vc"
      cat "$file.vc" >> "$out"
    endif
  end
  exit 0
endif

if ("$1" == "canon-arr-walk") then
  set file = "$2"
  set out = "$3"
  set first = 1
  while (1)
    set line = "$<"
    if ("$line" == "") break
    set w = ($line)
    if ($first == 0) /usr/bin/printf ',' >> "$out"
    set first = 0
    if ($w[1] == "s") then
      tcsh "$0" spantext "$file" $w[2] $w[3] > "$file.vv"
      tcsh "$0" escape "$file.vv" >> "$out"
    else
      tcsh "$0" canon "$file" $w[2] $w[3] "$file.vc"
      cat "$file.vc" >> "$out"
    endif
  end
  exit 0
endif

if ("$1" == "escape") then
  # JSON-escape (canonical, ensure-ascii) the bytes of file $2,
  # quoted, to stdout. File-based: the payload (e.g. PGP armor)
  # contains newlines and cannot travel as an argument.
  set tmp = "$2"
  od -An -v -tu1 -w1 "$tmp" | tr -d ' ' > "$tmp.etoks"
  tcsh "$0" escape-walk < "$tmp.etoks"
  rm -f "$tmp.etoks"
  exit 0
endif

if ("$1" == "escape-walk") then
  set out = '"'
  while (1)
    set b = $<
    if ("$b" == "") break
    if ($b == 34) then
      set out = "$out$bs$bs${bs}042"
    else if ($b == 92) then
      # final text is two backslashes; %b halves each pair
      set out = "$out$bs$bs$bs$bs"
    else if ($b == 8) then
      set out = "$out${bs}${bs}b"
    else if ($b == 9) then
      set out = "$out${bs}${bs}t"
    else if ($b == 10) then
      set out = "$out${bs}${bs}n"
    else if ($b == 12) then
      set out = "$out${bs}${bs}f"
    else if ($b == 13) then
      set out = "$out${bs}${bs}r"
    else if ($b < 32 || $b >= 127) then
      # \u00XX with hex digits; the backslash is doubled
      # because GNU printf %b would otherwise interpret the
      # \uXXXX sequence itself when the string is printed
      @ h1 = $b / 16
      @ h2 = $b % 16
      set hexd = (0 1 2 3 4 5 6 7 8 9 a b c d e f)
      @ i1 = $h1 + 1
      @ i2 = $h2 + 1
      set out = "$out${bs}${bs}u00$hexd[$i1]$hexd[$i2]"
    else
      @ o1 = $b / 64
      @ o2 = ($b / 8) % 8
      @ o3 = $b % 8
      set out = "$out$bs$o1$o2$o3"
    endif
  end
  set out = "$out"'"'
  /usr/bin/printf '%b' "$out"
  exit 0
endif

echo "usage: json.tcsh spans|spantext|spanraw|canon|escape ..." >& /dev/stderr
exit 2
