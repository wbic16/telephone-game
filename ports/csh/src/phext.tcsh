#!/bin/tcsh
# phext.tcsh -- libphext core for the C shell (tcsh) port.
#
# tcsh variables cannot hold arbitrary bytes (no NULs, fragile
# newline handling) and tcsh has no substring operations, so
# phext bytes are processed in the TOKEN DOMAIN: a state file is
# exploded to a byte-token stream by od(1) (one decimal byte
# value per line) and the coordinate walk runs over that stream
# with $< line reads. Scroll text is accumulated as octal-escape
# text (four chars per byte, always safe in a variable) and
# materialized byte-exactly with printf(1). Implode streams
# scroll files back with cat(1) -- only break bytes and the
# coordinate walk pass through tcsh there.
#
# State directory layout (the exploded form):
#   <dir>/keys        sorted coordinate keys, one per line
#   <dir>/s/<key>     raw scroll bytes at that coordinate
# A coordinate key is the 9 components zero-padded to 12 digits
# and concatenated (108 chars), so lexical order == coordinate
# order.
#
# Subcommands:
#   explode <statefile> <dir>
#   implode <dir> <statefile>
#   fetch <dir> <coordkey>            (bytes to stdout)
#   has <dir> <coordkey>              (exit 0 if present)
#   put <dir> <coordkey> <textfile>   (insert one scroll file)
#   coords                            (helper: coordkey from 9 args)

# ---- explode: state file -> state dir -------------------------
# (two parts: explode tokenizes with od(1), then re-invokes this
# script as explode-walk with the token stream as stdin, because
# csh cannot redirect its own stdin mid-script with exec)
if ("$1" == "explode") then
  set statefile = "$2"
  set dir = "$3"
  mkdir -p "$dir/s"
  rm -f "$dir/keys"
  touch "$dir/keys"
  od -An -v -tu1 -w1 "$statefile" | tr -d ' ' > "$dir/.tokens"
  tcsh "$0" explode-walk "$dir" < "$dir/.tokens"
  sort -o "$dir/keys" "$dir/keys"
  rm -f "$dir/.tokens"
  exit 0
endif

if ("$1" == "explode-walk") then
  set dir = "$2"
  # coordinate components c1..c9 and their padded key parts
  set c = (1 1 1 1 1 1 1 1 1)
  set run = ""
  set runlen = 0
  set curkey = ""
  set bs = '\'
  set havescroll = 0
  while (1)
    set b = $<
    if ("$b" == "") break
    # break byte -> dimension (1..9), 0 = text byte
    set dim = 0
    switch ("$b")
      case 1:
        set dim = 1
        breaksw
      case 31:
        set dim = 2
        breaksw
      case 30:
        set dim = 3
        breaksw
      case 29:
        set dim = 4
        breaksw
      case 28:
        set dim = 5
        breaksw
      case 26:
        set dim = 6
        breaksw
      case 25:
        set dim = 7
        breaksw
      case 24:
        set dim = 8
        breaksw
      case 23:
        set dim = 9
        breaksw
    endsw
    if ($dim == 0) then
      if ($havescroll == 0) then
        # first byte of a run: fix the target file now
        set curkey = ""
        foreach comp ($c)
          set p = `/usr/bin/printf "%012d" $comp`
          set curkey = "$curkey$p"
        end
        rm -f "$dir/s/$curkey"
        set havescroll = 1
      endif
      # append byte as a 3-digit OCTAL escape (the printf %b
      # domain); od reports decimal, so convert per byte:
      # b = 64*o1 + 8*o2 + o3. The backslash enters via $bs --
      # a literal backslash in a quoted tcsh string is
      # escape-processed unpredictably.
      @ o1 = $b / 64
      @ o2 = ($b / 8) % 8
      @ o3 = $b % 8
      set run = "$run$bs$o1$o2$o3"
      @ runlen += 4
      if ($runlen >= 8192) then
        # flush whole escapes only (4 chars each): a single
        # argv is capped at 128 KB, so a big scroll must be
        # materialized in chunks
        /usr/bin/printf '%b' "$run" >> "$dir/s/$curkey"
        set run = ""
        set runlen = 0
      endif
    else
      if ($havescroll == 1) then
        if ("$run" != "") /usr/bin/printf '%b' "$run" >> "$dir/s/$curkey"
        echo "$curkey" >> "$dir/keys"
        set run = ""
        set runlen = 0
        set havescroll = 0
      endif
      # advance coordinate: c[dim]++, deeper components reset
      @ c[$dim] = $c[$dim] + 1
      set j = $dim
      while ($j < 9)
        @ j++
        set c[$j] = 1
      end
    endif
  end
  if ($havescroll == 1) then
    if ("$run" != "") /usr/bin/printf '%b' "$run" >> "$dir/s/$curkey"
    echo "$curkey" >> "$dir/keys"
  endif
  exit 0
endif

# ---- implode: state dir -> state file --------------------------
if ("$1" == "implode") then
  set dir = "$2"
  set statefile = "$3"
  # break bytes by dimension 1..9 (octal escapes)
  set brk = (001 037 036 035 034 032 031 030 027)
  set bs = '\'
  set loc = (1 1 1 1 1 1 1 1 1)
  rm -f "$statefile"
  touch "$statefile"
  foreach key (`cat "$dir/keys"`)
    # split the key into 9 components of 12 chars via cut(1)
    set tgt = (1 1 1 1 1 1 1 1 1)
    set d = 1
    while ($d <= 9)
      @ s = ($d - 1) * 12 + 1
      @ e = $d * 12
      set part = `echo "$key" | cut -c$s-$e`
      # strip leading zeros for arithmetic (keep at least one digit)
      set part = `echo "$part" | sed 's/^0*//'`
      if ("$part" == "") set part = 0
      set tgt[$d] = $part
      @ d++
    end
    # first differing dimension between loc and tgt
    set dim = 0
    set d = 1
    while ($d <= 9)
      if ($dim == 0 && $tgt[$d] != $loc[$d]) set dim = $d
      @ d++
    end
    if ($dim > 0) then
      @ n = $tgt[$dim] - $loc[$dim]
      set esc = "$bs$brk[$dim]"
      while ($n > 0)
        /usr/bin/printf '%b' "$esc" >> "$statefile"
        @ n--
      end
      set loc[$dim] = $tgt[$dim]
      set d = $dim
      while ($d < 9)
        @ d++
        if ($tgt[$d] > 1) then
          @ n = $tgt[$d] - 1
          set esc = "$bs$brk[$d]"
          while ($n > 0)
            /usr/bin/printf '%b' "$esc" >> "$statefile"
            @ n--
          end
        endif
        set loc[$d] = $tgt[$d]
      end
    endif
    cat "$dir/s/$key" >> "$statefile"
  end
  exit 0
endif

# ---- fetch ------------------------------------------------------
if ("$1" == "fetch") then
  if (-e "$2/s/$3") then
    cat "$2/s/$3"
  endif
  exit 0
endif

# ---- has ---------------------------------------------------------
if ("$1" == "has") then
  if (-e "$2/s/$3") exit 0
  exit 1
endif

# ---- put: insert/replace one scroll (text from a file) -----------
if ("$1" == "put") then
  cp "$4" "$2/s/$3"
  grep -qxF "$3" "$2/keys" || echo "$3" >> "$2/keys"
  sort -o "$2/keys" "$2/keys"
  exit 0
endif

# ---- del ---------------------------------------------------------
if ("$1" == "del") then
  rm -f "$2/s/$3"
  grep -vxF "$3" "$2/keys" > "$2/keys.tmp" || true
  mv "$2/keys.tmp" "$2/keys"
  exit 0
endif

# ---- keyof: padded coordinate key from 9 components --------------
if ("$1" == "keyof") then
  shift
  set key = ""
  foreach comp ($argv)
    set p = `/usr/bin/printf "%012d" $comp`
    set key = "$key$p"
  end
  echo "$key"
  exit 0
endif

echo "usage: phext.tcsh explode|implode|fetch|has|put|del|keyof ..." >& /dev/stderr
exit 2
