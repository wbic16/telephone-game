#!/bin/tcsh
# cli.tcsh -- Exocortical Stress Testing adapter CLI for the
# C shell (tcsh) port. Contract v2 (harness/ADAPTER-CONTRACT.md).
#
# Modes: serve (request lines on stdin until EOF) and oneshot
# (one request line). Each line is handled by a sub-invocation
# (tcsh has no functions): the line is staged to $W/req.raw and
# "handle" prints the response line. Serve-mode init caches the
# exploded state in $W/sdir for the following validate (the
# deferred-init pattern); one-shot work never uses the cache.
#
# All phext work goes through src/phext.tcsh (exploded state
# directories) and all JSON through src/json.tcsh (byte-token
# spans). sha256/base64/gzip/gpg are the standard CLI tools,
# gpg under the per-port GNUPGHOME the wrapper exports.
#
# Known scale limit (measured): the token-domain walk runs at
# roughly 4-15k tokens/sec, so game-scale states (2.2 MB) take
# minutes per pass -- see README.md. Small states (self-test,
# smoke) are fully served.

set IMPL = "csh"
set HERE = "$0:h"
if ("$HERE" == "$0") set HERE = "."
set PHEXT = "$HERE/phext.tcsh"
set JSON = "$HERE/json.tcsh"
set W = "/tmp/tel-csh-$$"
mkdir -p "$W"

# padded coordinate keys for the game scrolls
set K_ONE = "000000000001"
set INDEXKEY = "${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}"
set KEYSKEY = "${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}000000000002"
set KHKEY = "${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}000000000003"
set EVPREFIX = "${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}${K_ONE}000000000002${K_ONE}"

if ("$1" == "serve" || "$1" == "oneshot") then
  # The request-line intake loop lives in run.sh (POSIX sh):
  # tcsh's $< PARSES each input line (quotes are stripped and
  # braces group), so a JSON request line can never enter
  # through tcsh's stdin intact. run.sh stages each line to
  # $W/req.raw and invokes "handle" per line; all protocol
  # logic is in this file.
  echo '{"error":"serve/oneshot intake is run.sh; invoke handle"}'
  exit 2
endif

# ---- response framing: lines > 8 KB travel as GZ1 --------------
if ("$1" == "emit") then
  set sz = (`wc -c "$2"`)
  if ($sz[1] > 8192) then
    /usr/bin/printf 'GZ1:'
    gzip -c "$2" | base64 -w0
    /usr/bin/printf '\n'
  else
    cat "$2"
  endif
  exit 0
endif

# ================= handle one request ==========================
if ("$1" == "handle") then
  set W = "$2"
  # ---- deframe (no backquote capture of raw bytes: tcsh
  # re-parses backquote output, and a leading {"cm would break)
  head -c 4 "$W/req.raw" | grep -q '^GZ1'
  if ($status == 0) then
    tail -c +5 "$W/req.raw" | base64 -d | gunzip > "$W/req.json"
  else
    cp "$W/req.raw" "$W/req.json"
  endif
  tcsh "$JSON" spans "$W/req.json"
  # ---- cmd
  set ml = (`grep "^cmd " "$W/req.json.spans"`)
  if ($#ml == 0) then
    echo '{"error":"missing cmd"}'
    exit 0
  endif
  set cmd = `tcsh "$JSON" spantext "$W/req.json" $ml[3] $ml[4]`

  # ---- id
  if ("$cmd" == "id") then
    echo '{"impl":"csh"}'
    exit 0
  endif

  # ---- keygen
  if ("$cmd" == "keygen") then
    gpg --batch --yes --list-keys telephone-csh >& /dev/null
    if ($status != 0) then
      gpg --batch --yes --pinentry-mode loopback --passphrase '' --quick-generate-key telephone-csh ed25519 sign never >& /dev/null
    endif
    gpg --batch --yes --armor --export telephone-csh > "$W/pub.asc"
    set esc = `tcsh "$JSON" escape "$W/pub.asc"`
    /usr/bin/printf '%s\n' '{"impl":"csh","pubkey":'"$esc"'}'
    exit 0
  endif

  # ---- echo
  if ("$cmd" == "echo") then
    set ml = (`grep "^ping " "$W/req.json.spans"`)
    if ($ml[2] == "s") then
      tcsh "$JSON" spantext "$W/req.json" $ml[3] $ml[4] > "$W/ping.txt"
      set pingcanon = `tcsh "$JSON" escape "$W/ping.txt"`
      set canon = '{"impl":"csh","ping":'"$pingcanon"'}'
      /usr/bin/printf '%s' "$canon" > "$W/canon.txt"
    else if ($ml[2] == "v") then
      tcsh "$JSON" spanraw "$W/req.json" $ml[3] $ml[4] "$W/ping.raw"
      set pingcanon = `cat "$W/ping.raw"`
      set canon = '{"impl":"csh","ping":'"$pingcanon"'}'
      /usr/bin/printf '%s' "$canon" > "$W/canon.txt"
    else
      # object/array ping: canonicalize with the general
      # canonicalizer (any nesting), assembled in a file (the
      # value's braces can never sit in a tcsh variable)
      tcsh "$JSON" canon "$W/req.json" $ml[3] $ml[4] "$W/ping.canon"
      /usr/bin/printf '%s' '{"impl":"csh","ping":' > "$W/canon.txt"
      cat "$W/ping.canon" >> "$W/canon.txt"
      /usr/bin/printf '%s' '}' >> "$W/canon.txt"
    endif
    set h = `sha256sum "$W/canon.txt"`
    set hw = ($h)
    /usr/bin/printf '%s\n' '{"echo":"'"$hw[1]"'","impl":"csh"}'
    exit 0
  endif

  # ---- state-bearing commands: explode the state
  if ("$cmd" == "choose" || "$cmd" == "apply" || "$cmd" == "init" || "$cmd" == "validate" || "$cmd" == "verify" || "$cmd" == "elect") then
    set ml = (`grep "^state " "$W/req.json.spans"`)
    set cl = (`grep "^candidates " "$W/req.json.spans"`)
    if ($#ml > 0) then
      tcsh "$JSON" spanraw "$W/req.json" $ml[3] $ml[4] "$W/state.b64"
      base64 -d "$W/state.b64" > "$W/state.phext"
      # validate compares against the init cache, so its state
      # explodes alongside it; verify uses its own scratch dir
      if ("$cmd" == "validate") then
        set target = "$W/sdir-new"
      else if ("$cmd" == "verify") then
        set target = "$W/sdir-vfy"
      else
        set target = "$W/sdir"
      endif
      rm -rf "$target"
      tcsh "$PHEXT" explode "$W/state.phext" "$target"
      if ("$cmd" == "init") touch "$W/cached"
    else if (-e "$W/cached") then
      # serve-mode deferred init: reuse the exploded state
    else if ("$cmd" == "elect" && $#cl > 0) then
      # elect with explicit candidates needs no state
    else
      echo '{"error":"missing state"}'
      exit 0
    endif
  endif

  # ---- init
  if ("$cmd" == "init") then
    echo '{"impl":"csh","verdict":"pass"}'
    exit 0
  endif

  # ---- elect / choose share the election
  if ("$cmd" == "elect" || "$cmd" == "choose") then
    set ml = (`grep "^position " "$W/req.json.spans"`)
    set position = `tcsh "$JSON" spantext "$W/req.json" $ml[3] $ml[4]`
    set ml = (`grep "^turn " "$W/req.json.spans"`)
    tcsh "$JSON" spanraw "$W/req.json" $ml[3] $ml[4] "$W/turn.raw"
    set turn = `cat "$W/turn.raw"`
    # candidate actors: the request's candidates array when
    # given, else the index's actors in order (skip the header)
    set cl = (`grep "^candidates " "$W/req.json.spans"`)
    if ($#cl > 0) then
      tcsh "$JSON" array-strings "$W/req.json" $cl[3] $cl[4] > "$W/actors.txt"
    else
      tcsh "$0" index-actors "$W/sdir/s/$INDEXKEY" > "$W/actors.txt"
    endif
    set names = (`cat "$W/actors.txt"`)
    if ($#names == 0 && "$cmd" == "elect") then
      echo '{"error":"no candidates"}'
      exit 0
    endif
    if ($#names == 0) then
      # choose on a placement-free state: the requesting
      # position itself is the base (adapter_base choose takes
      # position, not a winner)
      set winner = "$position"
    else
      # pool = candidates minus self, fallback all
      set pool = ""
      foreach a ($names)
        if ("$a" != "$position") set pool = "$pool $a"
      end
      if ("$pool" == "") set pool = " $names"
      set poolw = ($pool)
      set joined = ""
      set first = 1
      foreach a ($names)
        if ($first == 1) then
          set joined = "$a"
          set first = 0
        else
          set joined = "$joined,$a"
        endif
      end
      set seed = "csh-elect:${position}:${turn}:${joined}"
      set h = `/usr/bin/printf '%s' "$seed" | sha256sum`
      set hw = ($h)
      set hex8 = `echo "$hw[1]" | cut -c1-8`
      set acc = `tcsh "$0" hexdec "$hex8"`
      @ idx = $acc % $#poolw
      @ idx++
      set winner = $poolw[$idx]
    endif
    if ("$cmd" == "elect") then
      /usr/bin/printf '%s' "$winner" > "$W/w.txt"
      set esc = `tcsh "$JSON" escape "$W/w.txt"`
      /usr/bin/printf '%s\n' '{"elect":'"$esc"'}'
      exit 0
    endif
    # choose: winner's last coordinate from the index, bump dim 9
    set last = (`awk -v a="$winner" '$4 == a' "$W/sdir/s/$INDEXKEY" | tail -1`)
    if ($#last == 0) then
      set coord = "$position"
    else
      set coord = $last[2]
    endif
    set parts = (`echo "$coord" | tr './' '  '`)
    set c9 = $parts[9]
    while (1)
      @ c9++
      set parts[9] = $c9
      set key = ""
      foreach comp ($parts)
        set p = `/usr/bin/printf "%012d" $comp`
        set key = "$key$p"
      end
      if (! -e "$W/sdir/s/$key") break
    end
    set ncoord = "$parts[1].$parts[2].$parts[3]/$parts[4].$parts[5].$parts[6]/$parts[7].$parts[8].$parts[9]"
    set text = "csh was here, turn $turn"
    /usr/bin/printf '%s' "$ncoord" > "$W/c.txt"
    set cesc = `tcsh "$JSON" escape "$W/c.txt"`
    /usr/bin/printf '%s' "$text" > "$W/t.txt"
    set tesc = `tcsh "$JSON" escape "$W/t.txt"`
    /usr/bin/printf '%s\n' '{"coordinate":'"$cesc"',"op":"insert","text":'"$tesc"'}'
    exit 0
  endif

  # ---- apply
  if ("$cmd" == "apply") then
    set ml = (`grep "^step " "$W/req.json.spans"`)
    tcsh "$JSON" spanraw "$W/req.json" $ml[3] $ml[4] "$W/step.json"
    tcsh "$JSON" spans "$W/step.json"
    set sl = (`grep "^coordinate " "$W/step.json.spans"`)
    set coord = `tcsh "$JSON" spantext "$W/step.json" $sl[3] $sl[4]`
    set sl = (`grep "^text " "$W/step.json.spans"`)
    tcsh "$JSON" spantext "$W/step.json" $sl[3] $sl[4] > "$W/step.txt"
    set parts = (`echo "$coord" | tr './' '  '`)
    set key = ""
    foreach comp ($parts)
      set p = `/usr/bin/printf "%012d" $comp`
      set key = "$key$p"
    end
    if (-e "$W/sdir/s/$key") then
      echo '{"error":"coordinate already occupied"}'
      exit 0
    endif
    tcsh "$PHEXT" put "$W/sdir" "$key" "$W/step.txt"
    tcsh "$PHEXT" implode "$W/sdir" "$W/out.phext"
    set h = `sha256sum "$W/out.phext"`
    set hw = ($h)
    # the base64 state can be megabytes: stream the response
    # in pieces, never through a variable or an argv
    base64 -w0 "$W/out.phext" > "$W/out.b64"
    /usr/bin/printf '%s' '{"state_b64":"'
    cat "$W/out.b64"
    /usr/bin/printf '%s\n' '","state_sha256":"'"$hw[1]"'"}'
    exit 0
  endif

  # ---- attest: sign the canonical descriptor
  if ("$cmd" == "attest") then
    set ml = (`grep "^descriptor " "$W/req.json.spans"`)
    tcsh "$JSON" spanraw "$W/req.json" $ml[3] $ml[4] "$W/desc.json"
    tcsh "$0" flat-canon "$W/desc.json"
    gpg --batch --yes --pinentry-mode loopback --passphrase '' --detach-sign --armor -u telephone-csh -o "$W/sig.asc" "$W/desc.json.canon" >& /dev/null
    set esc = `tcsh "$JSON" escape "$W/sig.asc"`
    /usr/bin/printf '%s\n' '{"signature":'"$esc"'}'
    exit 0
  endif

  # ---- validate: post-turn check against the init cache
  if ("$cmd" == "validate") then
    set ml = (`grep "^step " "$W/req.json.spans"`)
    tcsh "$JSON" spanraw "$W/req.json" $ml[3] $ml[4] "$W/step.json"
    tcsh "$JSON" spans "$W/step.json"
    set sl = (`grep "^coordinate " "$W/step.json.spans"`)
    tcsh "$JSON" spantext "$W/step.json" $sl[3] $sl[4] > "$W/vcoord.txt"
    set sl = (`grep "^text " "$W/step.json.spans"`)
    tcsh "$JSON" spantext "$W/step.json" $sl[3] $sl[4] > "$W/vtext.txt"
    set ml = (`grep "^event_coord " "$W/req.json.spans"`)
    tcsh "$JSON" spantext "$W/req.json" $ml[3] $ml[4] > "$W/vevcoord.txt"
    set ml = (`grep "^index_line " "$W/req.json.spans"`)
    tcsh "$JSON" spantext "$W/req.json" $ml[3] $ml[4] > "$W/vindex.txt"
    tcsh "$0" validate-walk "$W"
    exit 0
  endif

  # ---- verify: the total verification walk
  if ("$cmd" == "verify") then
    tcsh "$0" verify-walk "$W"
    exit 0
  endif

  echo '{"error":"unknown cmd"}'
  exit 0
endif

# ================= helpers =====================================
if ("$1" == "index-actors") then
  tcsh "$0" index-actors-walk < "$2"
  exit 0
endif

if ("$1" == "index-actors-walk") then
  set first = 1
  while (1)
    set line = "$<"
    if ("$line" == "") break
    if ($first == 1) then
      set first = 0
    else
      set w = ($line)
      echo "$w[4]"
    endif
  end
  exit 0
endif

if ("$1" == "hexdec") then
  set acc = 0
  set i = 1
  while ($i <= 8)
    set ch = `echo "$2" | cut -c$i`
    set d = 0
    switch ("$ch")
      case 0:
        set d = 0
        breaksw
      case 1:
        set d = 1
        breaksw
      case 2:
        set d = 2
        breaksw
      case 3:
        set d = 3
        breaksw
      case 4:
        set d = 4
        breaksw
      case 5:
        set d = 5
        breaksw
      case 6:
        set d = 6
        breaksw
      case 7:
        set d = 7
        breaksw
      case 8:
        set d = 8
        breaksw
      case 9:
        set d = 9
        breaksw
      case a:
        set d = 10
        breaksw
      case b:
        set d = 11
        breaksw
      case c:
        set d = 12
        breaksw
      case d:
        set d = 13
        breaksw
      case e:
        set d = 14
        breaksw
      case f:
        set d = 15
        breaksw
    endsw
    @ acc = $acc * 16 + $d
    @ i++
  end
  echo "$acc"
  exit 0
endif

# canonical JSON of a FLAT object (scalar members only) -- the
# attestation descriptor's shape. Writes <file>.canon (the
# canon's braces can never sit in a tcsh variable).
if ("$1" == "flat-canon") then
  tcsh "$JSON" spans "$2"
  sort "$2.spans" > "$2.sorted"
  tcsh "$0" flat-canon-walk "$2" < "$2.sorted"
  exit 0
endif

if ("$1" == "flat-canon-walk") then
  set file = "$2"
  set out = "{"
  set first = 1
  while (1)
    set line = "$<"
    if ("$line" == "") break
    set w = ($line)
    if ($w[2] == "s") then
      tcsh "$JSON" spantext "$file" $w[3] $w[4] > "$file.fv"
      set val = `tcsh "$JSON" escape "$file.fv"`
    else
      tcsh "$JSON" spanraw "$file" $w[3] $w[4] "$file.fv"
      set val = `cat "$file.fv"`
    endif
    if ($first == 0) set out = "$out,"
    set first = 0
    set Q = '"'
    set out = "$out${Q}$w[1]${Q}:$val"
  end
  set out = "$out}"
  /usr/bin/printf '%s' "$out" > "$file.canon"
  exit 0
endif

# ================= key <-> coordinate ==========================
if ("$1" == "keytocoord") then
  set key = "$2"
  set out = ""
  set d = 1
  while ($d <= 9)
    @ s = ($d - 1) * 12 + 1
    @ e = $d * 12
    set part = `echo "$key" | cut -c$s-$e | sed 's/^0*//'`
    if ("$part" == "") set part = 0
    if ($d == 4 || $d == 7) set out = "$out/"
    if ($d > 1 && $d != 4 && $d != 7) set out = "$out."
    set out = "$out$part"
    @ d++
  end
  echo "$out"
  exit 0
endif

# ================= validate (post-turn) ========================
# Mirrors adapter_base.validate: the placed state (sdir-new) is
# diffed against the init cache (sdir). On pass the cache is
# replaced by the placed state.
if ("$1" == "validate-walk") then
  set W = "$2"
  set old = "$W/sdir"
  set new = "$W/sdir-new"
  set detail = ""
  if (! -d "$old") set detail = "no cached state"
  set vcoord = `cat "$W/vcoord.txt"`
  set parts = (`echo "$vcoord" | tr './' '  '`)
  set coordkey = `tcsh "$PHEXT" keyof $parts`
  set evcoord = `cat "$W/vevcoord.txt"`
  set parts = (`echo "$evcoord" | tr './' '  '`)
  set evkey = `tcsh "$PHEXT" keyof $parts`
  if ("$detail" == "") then
    cmp -s "$W/vtext.txt" "$new/s/$coordkey"
    if ($status != 0) set detail = "placed scroll missing or altered"
  endif
  if ("$detail" == "") then
    foreach k (`cat "$old/keys"`)
      if ("$k" == "$INDEXKEY") continue
      cmp -s "$old/s/$k" "$new/s/$k"
      if ($status != 0) then
        set cs = `tcsh "$0" keytocoord "$k"`
        set detail = "prior scroll overwritten at $cs"
        break
      endif
    end
  endif
  if ("$detail" == "") then
    foreach k (`cat "$new/keys"`)
      grep -qxF "$k" "$old/keys" && continue
      if ("$k" == "$coordkey") continue
      if ("$k" == "$evkey") continue
      set cs = `tcsh "$0" keytocoord "$k"`
      set detail = "unexpected new scroll at $cs"
      break
    end
  endif
  if ("$detail" == "") then
    set ll = (`tail -n 1 "$new/s/$INDEXKEY"`)
    set want = `cat "$W/vindex.txt"`
    if ("$ll" != "$want") set detail = "index does not record the placement"
  endif
  if ("$detail" == "") then
    rm -rf "$old"
    mv "$new" "$old"
    echo '{"impl":"csh","verdict":"pass"}'
  else
    /usr/bin/printf '%s' "$detail" > "$W/detail.txt"
    set desc = `tcsh "$JSON" escape "$W/detail.txt"`
    /usr/bin/printf '%s\n' '{"detail":'"$desc"',"impl":"csh","verdict":"fail"}'
  endif
  exit 0
endif

# ================= verify (total walk) =========================
# Mirrors adapter_base.verify over the state in sdir-vfy.
if ("$1" == "verify-walk") then
  set W = "$2"
  set sd = "$W/sdir-vfy"
  rm -f "$W/failn.txt" "$W/faildetail.txt"
  echo 0 > "$W/plcount.txt"
  # (1) keys-hash
  set ok = 0
  if (-e "$sd/s/$KEYSKEY" && -e "$sd/s/$KHKEY") then
    set kh = `cat "$sd/s/$KHKEY"`
    set h = `sha256sum "$sd/s/$KEYSKEY"`
    set hw = ($h)
    if ("$hw[1]" == "$kh") set ok = 1
  endif
  if ($ok == 0) then
    echo 0 > "$W/failn.txt"
    echo "keys-hash scroll does not match keys" > "$W/faildetail.txt"
  else
    # import the inscribed keys into a scratch keyring
    mkdir -p "$W/vgpg"
    chmod 700 "$W/vgpg"
    awk -v dir="$W" 'BEGIN{n=0} /BEGIN PGP PUBLIC KEY BLOCK/{n++} {if(n>0) print > (dir "/keyblock." n)}' "$sd/s/$KEYSKEY"
    foreach kb ("$W"/keyblock.*)
      env GNUPGHOME="$W/vgpg" gpg --batch --import "$kb" >& /dev/null
    end
    rm -f "$W/placements.txt"
    touch "$W/placements.txt"
    echo 0 > "$W/evcount.txt"
    echo 0 > "$W/plcount.txt"
    rm -f "$W/prevhash.txt"
    grep "^$EVPREFIX" "$sd/keys" > "$W/evkeys.txt"
    tcsh "$0" verify-events "$W" < "$W/evkeys.txt"
  endif
  # (3) index lines vs placements
  if (! -e "$W/failn.txt") then
    tcsh "$0" verify-index "$W" < "$sd/s/$INDEXKEY"
  endif
  set pl = (`cat "$W/plcount.txt"`)
  if (-e "$W/failn.txt") then
    set fn = (`cat "$W/failn.txt"`)
    set desc = `tcsh "$JSON" escape "$W/faildetail.txt"`
    /usr/bin/printf '%s\n' '{"first_failure":{"detail":'"$desc"'},"impl":"csh","placements_checked":'"$fn[1]"',"verdict":"fail"}'
  else
    /usr/bin/printf '%s\n' '{"first_failure":null,"impl":"csh","placements_checked":'"$pl[1]"',"verdict":"pass"}'
  endif
  exit 0
endif

if ("$1" == "verify-events") then
  set W = "$2"
  set sd = "$W/sdir-vfy"
  while (1)
    set evkey = "$<"
    if ("$evkey" == "") break
    set evcount = (`cat "$W/evcount.txt"`)
    @ expect = $evcount[1] + 1
    set seqpart = `echo "$evkey" | cut -c97-108 | sed 's/^0*//'`
    if ("$seqpart" == "") set seqpart = 0
    set pl = (`cat "$W/plcount.txt"`)
    if ($seqpart != $expect) then
      echo "$pl[1]" > "$W/failn.txt"
      echo "event seq gap at $seqpart" > "$W/faildetail.txt"
      exit 0
    endif
    set ev = "$sd/s/$evkey"
    tcsh "$JSON" spans "$ev"
    # prev: absent or null for the first event, else the
    # sha256 of the previous event's canonical body
    set el = (`grep "^prev " "$ev.spans"`)
    if ($#el == 0) then
      set prev = "null"
    else if ($el[2] == "s") then
      set prev = `tcsh "$JSON" spantext "$ev" $el[3] $el[4]`
    else
      tcsh "$JSON" spanraw "$ev" $el[3] $el[4] "$W/ev.prev"
      set prev = `cat "$W/ev.prev"`
    endif
    if (-e "$W/prevhash.txt") then
      set wantprev = `cat "$W/prevhash.txt"`
    else
      set wantprev = "null"
    endif
    if ("$prev" != "$wantprev") then
      echo "$pl[1]" > "$W/failn.txt"
      echo "event chain broken at seq $seqpart" > "$W/faildetail.txt"
      exit 0
    endif
    # body: canonical form -> next prev_hash
    set el = (`grep "^body " "$ev.spans"`)
    tcsh "$JSON" spanraw "$ev" $el[3] $el[4] "$W/ev.body"
    tcsh "$JSON" canon "$ev" $el[3] $el[4] "$W/ev.body.canon"
    set h = `sha256sum "$W/ev.body.canon"`
    set hw = ($h)
    echo "$hw[1]" > "$W/prevhash.txt"
    tcsh "$JSON" spans "$W/ev.body"
    set bl = (`grep "^type " "$W/ev.body.spans"`)
    set btype = `tcsh "$JSON" spantext "$W/ev.body" $bl[3] $bl[4]`
    if ("$btype" == "placement") then
      set bl = (`grep "^coord " "$W/ev.body.spans"`)
      set bcoord = `tcsh "$JSON" spantext "$W/ev.body" $bl[3] $bl[4]`
      set bl = (`grep "^text_sha256 " "$W/ev.body.spans"`)
      set btsh = `tcsh "$JSON" spantext "$W/ev.body" $bl[3] $bl[4]`
      set bl = (`grep "^file_sha256 " "$W/ev.body.spans"`)
      set bfsh = `tcsh "$JSON" spantext "$W/ev.body" $bl[3] $bl[4]`
      set bl = (`grep "^turn " "$W/ev.body.spans"`)
      tcsh "$JSON" spanraw "$W/ev.body" $bl[3] $bl[4] "$W/ev.turn"
      set bturn = `cat "$W/ev.turn"`
      set bl = (`grep "^att " "$W/ev.body.spans"`)
      tcsh "$JSON" spantext "$W/ev.body" $bl[3] $bl[4] > "$W/ev.att"
      grep -q "^$bcoord " "$W/placements.txt"
      if ($status == 0) then
        echo "$pl[1]" > "$W/failn.txt"
        echo "coordinate reused at seq $seqpart" > "$W/faildetail.txt"
        exit 0
      endif
      set parts = (`echo "$bcoord" | tr './' '  '`)
      set ckey = `tcsh "$PHEXT" keyof $parts`
      set hok = 0
      if (-e "$sd/s/$ckey") then
        set h = `sha256sum "$sd/s/$ckey"`
        set hw = ($h)
        if ("$hw[1]" == "$btsh") set hok = 1
      endif
      if ($hok == 0) then
        echo "$pl[1]" > "$W/failn.txt"
        echo "placement scroll hash mismatch seq $seqpart" > "$W/faildetail.txt"
        exit 0
      endif
      # attestation over the canonical descriptor
      /usr/bin/printf '%s' '{"turn":'"$bturn"',"coordinate":"'"$bcoord"'","scroll_sha256":"'"$btsh"'","file_sha256":"'"$bfsh"'"}' > "$W/ev.desc.json"
      tcsh "$0" flat-canon "$W/ev.desc.json"
      base64 -d "$W/ev.att" > "$W/ev.sig"
      env GNUPGHOME="$W/vgpg" gpg --batch --verify "$W/ev.sig" "$W/ev.desc.json.canon" >& /dev/null
      if ($status != 0) then
        echo "$pl[1]" > "$W/failn.txt"
        echo "attestation fails at seq $seqpart" > "$W/faildetail.txt"
        exit 0
      endif
      echo "$bcoord $btsh" >> "$W/placements.txt"
      @ pln = $pl[1] + 1
      echo "$pln" > "$W/plcount.txt"
    endif
    echo "$expect" > "$W/evcount.txt"
  end
  exit 0
endif

if ("$1" == "verify-index") then
  set W = "$2"
  set nlines = 0
  while (1)
    set line = "$<"
    if ("$line" == "") break
    if ("$line" =~ \#*) continue
    set w = ($line)
    if ($#w < 4) continue
    @ nlines++
    set h = (`awk -v c="$w[2]" '$1 == c' "$W/placements.txt"`)
    set pl = (`cat "$W/plcount.txt"`)
    if ($#h == 0 || "$h[2]" != "$w[3]") then
      echo "$pl[1]" > "$W/failn.txt"
      set short = `echo "$line" | cut -c1-40`
      echo "index hash mismatch: $short" > "$W/faildetail.txt"
      exit 0
    endif
  end
  set pl = (`cat "$W/plcount.txt"`)
  if ($nlines != $pl[1]) then
    echo "$pl[1]" > "$W/failn.txt"
    echo "index lines != placements" > "$W/faildetail.txt"
  endif
  exit 0
endif

echo '{"error":"bad mode"}'
exit 2
