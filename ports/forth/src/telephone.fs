\ telephone.fs -- Exocortical Telephone Game CLI (contract v2) for the
\ Forth libphext port (Gforth 0.7.3). Wire protocol: one JSON request
\ in, one JSON response out. With no arguments it handles a single
\ request on stdin; with the argument "serve" it loops over JSON
\ lines on stdin/stdout.
\
\   {"cmd":"id"}                          -> {"impl":"forth"}
\   {"cmd":"echo","ping":{game,round,nonce}}
\                                         -> {"impl":"forth","echo":hex}
\   {"cmd":"elect","position":..,"candidates":[..],"turn":n}
\                                         -> {"elect":id}
\   {"cmd":"choose","state":b64,"position":..,"turn":n} -> insert step
\   {"cmd":"apply","state":b64,"step":{...}}
\                                  -> {"state_b64","state_sha256",...}
\   {"cmd":"keygen"}                      -> {"impl":"forth","pubkey":..}
\   {"cmd":"attest","descriptor":{...}}   -> {"signature":armored}
\   {"cmd":"init","state":b64}            -> {"impl":"forth","verdict":"pass"}
\   {"cmd":"validate","state":b64,"step":{...},
\      "event_coord":..,"index_line":..}  -> {"impl","verdict","detail"}
\      (driver form; prior state is the init/validate cache, mirroring
\       harness/adapter_base.py validate)
\   {"cmd":"validate","state":b64,"step":{...},"prior_state":b64?}
\                                         -> legacy wire form (perl-style)
\   {"cmd":"verify","state":b64,"pubkeys":armored}
\                                  -> {"impl","verdict",
\                                      "placements_checked","first_failure"}
\ The state key is accepted as "state" (contract v2) or "state_b64".
\
\ Echo rule (adapter_base form): sha256 hex of the canonical JSON
\ {"impl":"forth","ping":<ping>}.
\
\ Elect rule (popcorn, perl-port idiom): seed = sha256(position bytes
\ || byte(turn) || candidates joined with ","); the winner is
\ candidates[seed_byte0 % count(candidates)].
\
\ Choose rule (insert-only per contract v2): seed = sha256(position
\ bytes || byte(turn) || decimal state length || first 64 state bytes
\ || last 64 state bytes). First candidate = position with component
\ seed_byte1 % 9 advanced by 1 + seed_byte2 % 3 (wrapping within
\ 1..999); while the candidate holds a scroll in the given state (the
\ bookkeeping coordinates 1.1.1/1.1.1/1.1.1-3 count as always used),
\ advance it by one scroll (lexicographic +1 within 999^9).
\ Text: "forth turn <turn> at <coordinate>".
\
\ Canonical JSON (attest/verify/echo): compact, keys sorted, strings
\ escaped the way Python's json.dumps(ensure_ascii=True) escapes them
\ (the perl port's canon rules, which are proven in play).
\
\ stress.phext layout (contract v2, pinned formats): index scroll at
\ 1.1.1/1.1.1/1.1.1 with a header line, then one
\ "<turn> <coordinate> <sha256hex> <actor id>" line per placement;
\ participant public keys at 1.1.1/1.1.1/1.1.2; sha256 of the keys
\ scroll text EXACTLY as inscribed (no trimming) at 1.1.1/1.1.1/1.1.3;
\ event scrolls at 1.1.1/1.1.1/2.1.<seq> (seq from 1), each canonical
\ JSON {"prev": <sha256 of previous event's body, or null>,
\ "body": {...}}. Verify mirrors harness/adapter_base.py exactly:
\ keys-hash match, event chain integrity, no coordinate reuse,
\ placement scroll hashes, attestation signatures against the
\ inscribed keys, index lines matching placements.
\
\ Serve framing (game scale, 2026-11-24): lines over 8 KB travel as
\ "GZ1:" + base64(gzip(line)) in both directions (system gzip on temp
\ files, as in the lua/fortran ports); small lines stay plain.
\ One-shot mode is never framed.
\
\ PGP: gpg subprocess on temp files, key home
\ ~/telephone-forth/gnupg (per-port GNUPGHOME). Private keys never
\ leave that home. Full-state hashes (apply) also go to sha256sum(1)
\ on a temp file; in-Forth SHA-256 covers the small pinned hashes
\ (echo, keys scroll, event bodies, scroll texts, descriptors).

include /home/wbic16/telephone-forth/port/src/phext.fs

\ ---------------- reusable arenas & buffers ----------------
: arena-reset ( arena -- ) dup @ swap cell+ ! ;
268435456 make-arena constant wk-arena    \ working-state explode texts
67108864 make-arena constant wk2-arena    \ prior-state explode (wire validate)
67108864 make-arena constant cache-arena \ init/validate cache texts
33554432 make-arena constant node-arena  \ JSON DOM nodes + strings
16777216 make-arena constant out-arena   \ response / canon output
1048576 make-arena constant can-arena    \ canon scratch (echo/descriptor)
: arena-free ( arena -- ) dup @ free throw free throw ;
: table-free ( t -- ) dup 2 cells + @ free throw free throw ;

25165824 allocate throw constant state-buf   \ decoded wire state
25165824 allocate throw constant cache-buf   \ cached raw state (validate)
25165824 allocate throw constant file-buf    \ temp-file reads
20971520 allocate throw constant line-buf    \ serve line input
variable cache-table  0 cache-table !
variable cache-len    0 cache-len !
variable vgnupg-ready 0 vgnupg-ready !

s" /home/wbic16/telephone-forth/tmp" over constant tmpdir constant tmpdir-len
create path-buf 1024 allot
variable pb-n
: tmp-path ( name u -- addr u )  \ build tmpdir/name in path-buf
  pb-n !
  tmpdir path-buf tmpdir-len move
  [char] / path-buf tmpdir-len + c!
  path-buf tmpdir-len + 1+ pb-n @ move
  path-buf tmpdir-len pb-n @ + 1+ ;

\ byte-append into an arena (out-arena / can-arena idiom)
variable ba-a
: ba-c! ( byte arena -- ) ba-a ! ba-a @ arena-ptr c! 1 ba-a @ cell+ +! ;
: ba-append ( addr u arena -- ) arena-append drop ;
: out-c! ( byte -- ) out-arena ba-c! ;
: out-append ( addr u -- ) out-arena ba-append ;
: out-start ( -- addr ) out-arena arena-ptr ;
: out-finish ( start -- addr u ) dup out-arena arena-ptr swap - ;
: can-c! ( byte -- ) can-arena ba-c! ;
: can-append ( addr u -- ) can-arena ba-append ;
: can-start ( -- addr ) can-arena arena-ptr ;
: can-finish ( start -- addr u ) dup can-arena arena-ptr swap - ;

\ ---------------- SHA-256 (FIPS 180-4, 32-bit words in cells) ----------------
create sha-k
$428a2f98 , $71374491 , $b5c0fbcf , $e9b5dba5 , $3956c25b , $59f111f1 , $923f82a4 , $ab1c5ed5 ,
$d807aa98 , $12835b01 , $243185be , $550c7dc3 , $72be5d74 , $80deb1fe , $9bdc06a7 , $c19bf174 ,
$e49b69c1 , $efbe4786 , $0fc19dc6 , $240ca1cc , $2de92c6f , $4a7484aa , $5cb0a9dc , $76f988da ,
$983e5152 , $a831c66d , $b00327c8 , $bf597fc7 , $c6e00bf3 , $d5a79147 , $06ca6351 , $14292967 ,
$27b70a85 , $2e1b2138 , $4d2c6dfc , $53380d13 , $650a7354 , $766a0abb , $81c2c92e , $92722c85 ,
$a2bfe8a1 , $a81a664b , $c24b8b70 , $c76c51a3 , $d192e819 , $d6990624 , $f40e3585 , $106aa070 ,
$19a4c116 , $1e376c08 , $2748774c , $34b0bcb5 , $391c0cb3 , $4ed8aa4a , $5b9cca4f , $682e6ff3 ,
$748f82ee , $78a5636f , $84c87814 , $8cc70208 , $90befffa , $a4506ceb , $bef9a3f7 , $c67178f2 ,
create sha-h 8 cells allot
create sha-w 64 cells allot
variable sha-a variable sha-b variable sha-c variable sha-d
variable sha-e variable sha-f variable sha-g variable sha-hh
variable sha-t1 variable sha-t2
: sha-rotr ( x n -- y )
  2dup rshift
  -rot 32 swap - lshift
  or $ffffffff and ;
: sha-init ( -- )
  $6a09e667 sha-h ! $bb67ae85 sha-h cell+ ! $3c6ef372 sha-h 2 cells + !
  $a54ff53a sha-h 3 cells + ! $510e527f sha-h 4 cells + !
  $9b05688c sha-h 5 cells + ! $1f83d9ab sha-h 6 cells + !
  $5be0cd19 sha-h 7 cells + ! ;
: sha-be32 ( addr -- w )
  dup c@ 24 lshift swap 1+ dup c@ 16 lshift swap 1+
  dup c@ 8 lshift swap 1+ c@ or or or ;
variable sb-blk
: sha-add ( val idx -- )
  cells sha-h + dup @ rot + $ffffffff and swap ! ;
: sha-block ( addr -- )
  sb-blk !
  16 0 do sb-blk @ i 4 * + sha-be32 sha-w i cells + ! loop
  64 16 do
    sha-w i 15 - cells + @ dup 7 sha-rotr swap dup 18 sha-rotr swap 3 rshift xor xor
    sha-w i 2 - cells + @ dup 17 sha-rotr swap dup 19 sha-rotr swap 10 rshift xor xor
    sha-w i 16 - cells + @ + sha-w i 7 - cells + @ + +
    $ffffffff and sha-w i cells + !
  loop
  sha-h @ sha-a ! sha-h cell+ @ sha-b ! sha-h 2 cells + @ sha-c !
  sha-h 3 cells + @ sha-d ! sha-h 4 cells + @ sha-e !
  sha-h 5 cells + @ sha-f ! sha-h 6 cells + @ sha-g !
  sha-h 7 cells + @ sha-hh !
  64 0 do
    sha-hh @
    sha-e @ dup 6 sha-rotr swap dup 11 sha-rotr swap 25 sha-rotr xor xor +
    sha-e @ sha-f @ and sha-e @ invert sha-g @ and xor +
    sha-k i cells + @ + sha-w i cells + @ + $ffffffff and sha-t1 !
    sha-a @ dup 2 sha-rotr swap dup 13 sha-rotr swap 22 sha-rotr xor xor
    sha-a @ sha-b @ and sha-a @ sha-c @ and xor sha-b @ sha-c @ and xor
    + $ffffffff and sha-t2 !
    sha-g @ sha-hh ! sha-f @ sha-g ! sha-e @ sha-f !
    sha-d @ sha-t1 @ + $ffffffff and sha-e !
    sha-c @ sha-d ! sha-b @ sha-c ! sha-a @ sha-b !
    sha-t1 @ sha-t2 @ + $ffffffff and sha-a !
  loop
  sha-a @ 0 sha-add sha-b @ 1 sha-add sha-c @ 2 sha-add
  sha-d @ 3 sha-add sha-e @ 4 sha-add sha-f @ 5 sha-add
  sha-g @ 6 sha-add sha-hh @ 7 sha-add ;
create sha-tail 128 allot
variable sha-src variable sha-len variable sha-total
: sha-be32! ( w addr -- )
  over 24 rshift over c! over 16 rshift over 1+ c!
  over 8 rshift over 2 + c! 3 + c! ;
: sha256 ( addr u -- )  \ digest words left in sha-h
  sha-total ! sha-total @ sha-len ! sha-src ! sha-init
  begin sha-len @ 64 >= while
    sha-src @ sha-block 64 sha-src +! -64 sha-len +!
  repeat
  sha-tail 128 erase
  sha-src @ sha-tail sha-len @ move
  $80 sha-tail sha-len @ + c!
  sha-len @ 56 < if
    sha-total @ 8 * sha-tail 60 + sha-be32!
    sha-total @ 536870912 / sha-tail 56 + sha-be32!
    sha-tail sha-block
  else
    sha-tail sha-block
    sha-tail 64 + 64 erase
    sha-total @ 8 * sha-tail 124 + sha-be32!
    sha-total @ 536870912 / sha-tail 120 + sha-be32!
    sha-tail 64 + sha-block
  then ;
create sha-hexbuf 65 allot
: sha256hex ( addr u -- hexaddr 64 )  \ hex digest in sha-hexbuf
  sha256
  8 0 do
    sha-h i cells + @
    8 0 do
      dup 28 rshift $f and
      dup 10 < if [char] 0 + else 87 + then
      sha-hexbuf j 8 * i + + c!
      4 lshift $ffffffff and
    loop drop
  loop
  sha-hexbuf 64 ;

\ ---------------- base64 ----------------
create b64-chars 64 allot
: b64-init ( -- )
  s" ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  drop
  64 0 do dup i + c@ b64-chars i + c! loop drop ;
b64-init
create b64-val 256 allot
: b64v-init ( -- )
  256 0 do 255 b64-val i + c! loop
  64 0 do b64-chars i + c@ b64-val + i swap c! loop ;
b64v-init
variable b64-out variable b64-dst variable b64-acc variable b64-nb
: b64-decode ( src u dst -- u' )  \ dst must hold u*3/4+3 bytes
  dup b64-dst ! b64-out ! 0 b64-acc ! 0 b64-nb !
  0 ?do
    dup i + c@ b64-val + c@
    dup 255 = if drop else
      b64-acc @ 6 lshift or b64-acc ! 1 b64-nb +!
      b64-nb @ 4 = if
        b64-acc @ 16 rshift b64-out @ c! 1 b64-out +!
        b64-acc @ 8 rshift b64-out @ c! 1 b64-out +!
        b64-acc @ b64-out @ c! 1 b64-out +!
        0 b64-acc ! 0 b64-nb !
      then
    then
  loop drop
  b64-nb @ 2 = if b64-acc @ 4 rshift b64-out @ c! 1 b64-out +! then
  b64-nb @ 3 = if
    b64-acc @ 10 rshift b64-out @ c! 1 b64-out +!
    b64-acc @ 2 rshift b64-out @ c! 1 b64-out +!
  then
  b64-out @ b64-dst @ - ;
variable be-s variable be-u variable be-b1 variable be-b2
variable be-arena
: be-c! ( byte -- ) be-arena @ ba-c! ;
: b64-encode-to ( src u arena -- )  \ append base64 text to arena
  be-arena ! be-u ! be-s !
  begin be-u @ 0> while
    be-u @ 1 > if be-s @ 1+ c@ else 0 then be-b1 !
    be-u @ 2 > if be-s @ 2 + c@ else 0 then be-b2 !
    be-s @ c@ 2 rshift b64-chars + c@ be-c!
    be-s @ c@ 4 lshift be-b1 @ 4 rshift or $3f and b64-chars + c@ be-c!
    be-u @ 1 > if
      be-b1 @ 2 lshift be-b2 @ 6 rshift or $3f and b64-chars + c@ be-c!
    else [char] = be-c! then
    be-u @ 2 > if
      be-b2 @ $3f and b64-chars + c@ be-c!
    else [char] = be-c! then
    3 be-s +! -3 be-u +!
  repeat ;
: b64-encode-out ( src u -- ) out-arena b64-encode-to ;

\ ---------------- subprocess / files ----------------
create cmd-buf 8192 allot
variable cmd-len
: cmd-reset ( -- ) 0 cmd-len ! ;
: cmd-append ( addr u -- )
  dup >r cmd-buf cmd-len @ + swap move r> cmd-len +! ;
: cmd-c! ( byte -- ) cmd-buf cmd-len @ + c! 1 cmd-len +! ;
: cmd-s ( addr u -- ) cmd-append ;
: run-cmd ( -- ) cmd-buf cmd-len @ system ;
: write-tmp ( addr u name u -- )
  tmp-path ( addr u path u )
  w/o create-file throw >r
  r@ write-file throw r> close-file throw ;
variable rt-f variable rt-b
: read-tmp ( name u buf -- u )
  rt-b ! tmp-path r/o open-file throw rt-f !
  rt-f @ file-size throw drop ( size, low cell of ud )
  rt-b @ swap rt-f @ read-file throw
  rt-f @ close-file throw ;
: tmp-exists ( name u -- flag )
  tmp-path r/o open-file if drop false else close-file throw true then ;
: rm-tmp ( name u -- ) tmp-path delete-file drop ;
: file-sha256hex ( addr u -- hexaddr 64 )  \ sha256sum(1) on given bytes
  s" data.bin" write-tmp
  cmd-reset
  s" sha256sum " cmd-s s" data.bin" tmp-path cmd-s
  s"  > " cmd-s s" data.sum" tmp-path cmd-s
  s"  2>/dev/null" cmd-s run-cmd
  s" data.sum" file-buf read-tmp drop
  file-buf 64 ;
: gpg-prefix ( gnupg-path-addr u -- )  \ append GNUPGHOME=.. gpg --batch
  s" GNUPGHOME=" cmd-s cmd-s
  s"  gpg --batch --yes " cmd-s ;
s" /home/wbic16/telephone-forth/gnupg" over constant gpghome constant gpghome-len
s" /home/wbic16/telephone-forth/vgnupg" over constant vgpghome constant vgpghome-len
: ensure-dirs ( -- )
  cmd-reset
  s" mkdir -p " cmd-s tmpdir tmpdir-len cmd-s
  s"  " cmd-s gpghome gpghome-len cmd-s
  s"  && chmod 700 " cmd-s gpghome gpghome-len cmd-s run-cmd ;
variable kg-done 0 kg-done !
: do-keygen ( -- pubaddr pubu )  \ armored public key in file-buf
  ensure-dirs
  cmd-reset gpghome gpghome-len gpg-prefix
  s" --list-keys --with-colons > " cmd-s
  s" keys.txt" tmp-path cmd-s s"  2>/dev/null" cmd-s run-cmd
  s" keys.txt" file-buf read-tmp ( u )
  file-buf swap s" pub:" search nip nip 0= if
    cmd-reset gpghome gpghome-len gpg-prefix
    s" --pinentry-mode loopback --passphrase '' --quick-generate-key telephone-forth ed25519 sign never 2>/dev/null" cmd-s run-cmd
  then
  cmd-reset gpghome gpghome-len gpg-prefix
  s" --armor --export telephone-forth > " cmd-s
  s" pub.txt" tmp-path cmd-s s"  2>/dev/null" cmd-s run-cmd
  s" pub.txt" file-buf read-tmp file-buf swap ;
: do-sign ( data u -- sigaddr sigu )  \ armored detached sig in file-buf
  s" desc.bin" write-tmp
  cmd-reset gpghome gpghome-len gpg-prefix
  s" --pinentry-mode loopback --passphrase '' --detach-sign --armor -u telephone-forth -o " cmd-s
  s" desc.asc" tmp-path cmd-s s"  " cmd-s
  s" desc.bin" tmp-path cmd-s s"  2>/dev/null" cmd-s run-cmd
  s" desc.asc" file-buf read-tmp file-buf swap ;
: vgnupg-setup ( keysaddr keysu -- flag )
  vgnupg-ready @ if drop drop true exit then
  s" vkeys.asc" write-tmp
  cmd-reset
  s" rm -rf " cmd-s vgpghome vgpghome-len cmd-s
  s"  && mkdir -p " cmd-s vgpghome vgpghome-len cmd-s
  s"  && chmod 700 " cmd-s vgpghome vgpghome-len cmd-s run-cmd
  s" vok" rm-tmp
  cmd-reset vgpghome vgpghome-len gpg-prefix
  s" --import " cmd-s s" vkeys.asc" tmp-path cmd-s
  s"  && touch " cmd-s s" vok" tmp-path cmd-s
  s"  2>/dev/null" cmd-s run-cmd
  s" vok" tmp-exists dup vgnupg-ready ! ;
: do-verify-sig ( data u sigaddr sigu -- flag )
  2swap s" vdesc.bin" write-tmp
  s" vsig.asc" write-tmp
  s" vok" rm-tmp
  cmd-reset vgpghome vgpghome-len gpg-prefix
  s" --verify " cmd-s s" vsig.asc" tmp-path cmd-s
  s"  " cmd-s s" vdesc.bin" tmp-path cmd-s
  s"  && touch " cmd-s s" vok" tmp-path cmd-s
  s"  2>/dev/null" cmd-s run-cmd
  s" vok" tmp-exists ;

\ ---------------- JSON parser (DOM in node-arena) ----------------
\ node: [0]=type [1]=a [2]=b [3]=c [4]=next
\ types: 0 null, 1 bool(a=flag), 2 number(a=raw,b=len,c=intval),
\ 3 string(a=addr,b=len), 4 array(a=first,b=count),
\ 5 object(a=first pair), 6 pair(a=key node,b=value node)
: node-new ( -- node ) 40 node-arena arena-alloc dup 40 erase ;
: node-type ( node -- t ) @ ;
: node-a ( node -- x ) cell+ @ ;
: node-b ( node -- x ) 2 cells + @ ;
: node-c ( node -- x ) 3 cells + @ ;
: node-next ( node -- x ) 4 cells + @ ;
variable jp-a variable jp-i variable jp-u
: jp-peek ( -- c ) jp-a @ jp-i @ + c@ ;
: jp-next ( -- c ) jp-peek 1 jp-i +! ;
: jp-ws? ( c -- flag ) dup 32 = over 9 = or over 10 = or swap 13 = or ;
: jp-skip ( -- )
  begin jp-i @ jp-u @ < jp-peek jp-ws? and while 1 jp-i +! repeat ;
: jp-expect ( c -- ) jp-next drop drop ;
: na-c! ( byte -- ) node-arena ba-c! ;
: na-utf8 ( cp -- )
  dup $80 < if na-c!
  else dup $800 < if
    dup 6 rshift $c0 or na-c! dup $3f and $80 or na-c!
  else dup $10000 < if
    dup 12 rshift $e0 or na-c! dup 6 rshift $3f and $80 or na-c!
    dup $3f and $80 or na-c!
  else
    dup 18 rshift $f0 or na-c! dup 12 rshift $3f and $80 or na-c!
    dup 6 rshift $3f and $80 or na-c! dup $3f and $80 or na-c!
  then then then ;
variable jh-v
: jp-hex4 ( -- cp )
  0 jh-v !
  4 0 do jp-next dup [char] 0 [char] 9 1+ within if [char] 0 -
    else dup [char] a [char] f 1+ within if 87 - else 55 - then then
    jh-v @ 4 lshift or jh-v ! loop jh-v @ ;
variable js-s variable js-e variable js-n
: jp-string ( -- node )  \ current char is opening quote
  jp-next drop
  node-arena arena-ptr js-s !
  begin jp-peek [char] " <> while
    jp-next ( c )
    dup [char] \ = if drop jp-next ( esc )
      dup [char] n = if drop 10 na-c! else
      dup [char] r = if drop 13 na-c! else
      dup [char] t = if drop 9 na-c! else
      dup [char] b = if drop 8 na-c! else
      dup [char] f = if drop 12 na-c! else
      dup [char] u = if drop jp-hex4 ( cp )
        dup $d800 $dc00 within if ( high surrogate )
          jp-next drop jp-next drop jp-hex4 ( cp lo )
          swap $d800 - 10 lshift swap $dc00 - + $10000 + then
        na-utf8
      else na-c! then then then then then then
    else na-c! then
  repeat
  jp-next drop ( closing quote )
  node-arena arena-ptr js-e !
  node-new js-n !
  3 js-n @ !
  js-s @ js-n @ cell+ !
  js-e @ js-s @ - js-n @ 2 cells + !
  js-n @ ;
variable jn-v variable jn-neg
: jp-number ( -- node )
  jp-a @ jp-i @ + ( raw )
  0 jn-v ! false jn-neg !
  jp-peek [char] - = if jp-next drop true jn-neg ! then
  begin jp-i @ jp-u @ < jp-peek [char] 0 [char] 9 1+ within and while
    jp-next [char] 0 - jn-v @ 10 * + jn-v !
  repeat
  begin jp-i @ jp-u @ < dup if drop jp-peek
      dup [char] . = over [char] e = or over [char] E = or
      over [char] + = or over [char] - = or
      over [char] 0 [char] 9 1+ within or swap drop
    then
  while jp-next drop repeat
  node-new ( raw node ) dup 2 swap !
  tuck cell+ ! ( a = raw; stack: node )
  dup dup node-a jp-a @ jp-i @ + swap - swap 2 cells + !
  jn-v @ jn-neg @ if negate then over 3 cells + ! ;
variable jp-tmp
: jp-append ( head last new -- head new )
  jp-tmp !
  dup 0= if drop jp-tmp @ over cell+ !
  else jp-tmp @ swap 4 cells + ! then
  jp-tmp @ ;
defer jp-object
defer jp-array
: jp-value ( -- node )
  jp-skip jp-peek ( c )
  dup [char] { = if drop jp-object exit then
  dup [char] [ = if drop jp-array exit then
  dup [char] " = if drop jp-string exit then
  dup [char] t = if drop
    jp-next drop jp-next drop jp-next drop jp-next drop
    node-new dup 1 swap ! true over cell+ ! exit then
  dup [char] f = if drop
    jp-next drop jp-next drop jp-next drop jp-next drop jp-next drop
    node-new dup 1 swap ! false over cell+ ! exit then
  dup [char] n = if drop
    jp-next drop jp-next drop jp-next drop jp-next drop
    node-new dup 0 swap ! exit then
  drop jp-number ;
:noname ( -- node )
  jp-next drop ( [ )
  node-new dup 4 swap ! 0 ( arr last )
  jp-skip jp-peek [char] ] = if jp-next drop drop exit then
  begin
    jp-value jp-append ( arr last )
    over 2 cells + 1 swap +!
    jp-skip jp-peek [char] , = if jp-next drop false else true then
  until
  jp-skip jp-next drop ( ] ) drop ;
is jp-array
:noname ( -- node )
  jp-next drop ( { )
  node-new dup 5 swap ! 0 ( obj last )
  jp-skip jp-peek [char] } = if jp-next drop drop exit then
  begin
    jp-skip jp-string ( obj last key )
    jp-skip jp-next drop ( : )
    jp-value ( obj last key val )
    node-new dup 6 swap ! ( obj last key val pair )
    tuck 2 cells + ! ( pair.b = val )
    tuck cell+ ! ( pair.a = key )
    jp-append ( obj last )
    jp-skip jp-peek [char] , = if jp-next drop false else true then
  until
  jp-skip jp-next drop ( } ) drop ;
is jp-object
: json-parse ( addr u -- node )
  jp-u ! jp-a ! 0 jp-i ! jp-value ;
variable jk-a variable jk-u
: obj-get ( node key u -- val|0 )
  jk-u ! jk-a !
  dup node-type 5 <> if drop 0 exit then
  node-a ( first pair )
  begin dup while
    dup node-a dup node-a swap node-b jk-a @ jk-u @ compare 0=
    if node-b exit then
    node-next
  repeat drop 0 ;
: node-str ( node -- addr u )
  dup 0= if drop 0 0 exit then
  dup node-type 3 = over node-type 2 = or if
    dup node-a swap node-b
  else drop 0 0 then ;
: node-int ( node -- n ) dup 0= if drop 0 else node-c then ;

\ ---------------- canonical JSON emitter (into can-arena) ----------------
: ce-c! ( byte -- ) can-c! ;
: ce-append ( addr u -- ) can-append ;
: ce-hex4 ( v -- )
  4 0 do dup $f000 and 12 rshift
    dup 10 < if [char] 0 + else 87 + then ce-c! 4 lshift
  loop drop ;
: ce-emit-u ( cp -- )
  dup $10000 < if s\" \\u" ce-append ce-hex4
  else $10000 -
    dup 10 rshift $d800 + s\" \\u" ce-append ce-hex4
    $3ff and $dc00 + s\" \\u" ce-append ce-hex4
  then ;
variable ce-cp
: ce-emit-cp ( cp -- )
  dup [char] " = if drop s\" \\\"" ce-append exit then
  dup [char] \ = if drop s\" \\\\" ce-append exit then
  dup 8 = if drop s\" \\b" ce-append exit then
  dup 12 = if drop s\" \\f" ce-append exit then
  dup 10 = if drop s\" \\n" ce-append exit then
  dup 13 = if drop s\" \\r" ce-append exit then
  dup 9 = if drop s\" \\t" ce-append exit then
  dup $20 < over $7e > or if ce-emit-u else ce-c! then ;
variable ce-a variable ce-u variable ce-i variable ce-n
: ce-esc ( addr u -- )
  ce-u ! ce-a ! 0 ce-i !
  [char] " ce-c!
  begin ce-i @ ce-u @ < while
    ce-a @ ce-i @ + c@
    dup $80 < if ce-cp ! 0 ce-n !
    else dup $e0 < if $1f and ce-cp ! 1 ce-n !
    else dup $f0 < if $0f and ce-cp ! 2 ce-n !
    else $07 and ce-cp ! 3 ce-n ! then then then
    1 ce-i +!
    ce-n @ 0 ?do
      ce-a @ ce-i @ + c@ $3f and ce-cp @ 6 lshift or ce-cp !
      1 ce-i +!
    loop
    ce-cp @ ce-emit-cp
  repeat
  [char] " ce-c! ;
create ce-ptrs 8192 cells allot
variable ce-np variable ce-p
variable ce-top 0 ce-top !
create ce-stack 256 cells allot
variable ce-sp 0 ce-sp !
: ce-push ( n -- ) ce-stack ce-sp @ cells + ! 1 ce-sp +! ;
: ce-pop ( -- n ) -1 ce-sp +! ce-stack ce-sp @ cells + @ ;
: ce-base ( -- n ) ce-stack ce-sp @ 2 - cells + @ ;
: ce-nps ( -- n ) ce-stack ce-sp @ 1 - cells + @ ;
: ce-key< ( p1 p2 -- flag )  \ pair key strings byte-compare
  node-a dup node-a swap node-b rot node-a dup node-a swap node-b
  2swap compare 0< ;
: canon-emit ( node -- ) recursive
  dup node-type ( t )
  dup 0 = if drop s" null" ce-append exit then
  dup 1 = if drop node-a if s" true" else s" false" then ce-append exit then
  dup 2 = if drop dup node-a swap node-b ce-append exit then
  dup 3 = if drop dup node-a swap node-b ce-esc exit then
  dup 4 = if drop ( array )
    [char] [ ce-c!
    node-a ( first )
    begin dup while
      dup canon-emit
      node-next dup if [char] , ce-c! then
    repeat drop
    [char] ] ce-c! exit then
  dup 5 = if drop ( object )
    ce-top @ ce-push ( slice base slot )
    0 ce-push ( np slot )
    0 ce-np ! node-a ( first pair )
    begin dup while
      dup ce-ptrs ce-base ce-np @ + cells + ! 1 ce-np +! node-next
    repeat drop
    ce-np @ ce-stack ce-sp @ 1 - cells + !
    ce-np @ ce-top +!
    ce-nps 1 > if
    ce-nps 1 ?do  \ insertion sort slice by key
      ce-ptrs ce-base i + cells + @ ce-p !
      i ( j ) begin
        dup 0> if dup ce-base + 1- cells ce-ptrs + @ ce-p @ ce-key< 0=
        else false then
      while
        dup ce-base + cells ce-ptrs + dup 1 cells - @ swap !
        1-
      repeat
      ce-base + cells ce-ptrs + ce-p @ swap !
    loop
    then
    [char] { ce-c!
    ce-nps 0 ?do
      ce-ptrs ce-base i + cells + @ ( pair )
      dup node-a dup node-a swap node-b ce-esc
      [char] : ce-c! node-b canon-emit
      i 1+ ce-nps < if [char] , ce-c! then
    loop
    [char] } ce-c!
    ce-pop drop ce-pop ce-top ! exit then
  drop ;
: canon-of ( node -- addr u )
  can-arena arena-reset can-start swap canon-emit can-finish ;

\ ---------------- response building ----------------
: resp-start ( -- ) out-arena arena-reset ;
: resp-s ( addr u -- ) out-append ;
: resp-jstr ( addr u -- )  \ quoted JSON string (canon escaping) into out
  can-arena arena-reset can-start -rot ce-esc can-finish out-append ;
: resp-num ( n -- )
  0 <# #s #> out-append ;
variable so-a variable so-u
: state-of ( req -- u )  \ decode req state into state-buf; return length
  dup s" state" obj-get ( req val )
  dup 0= if drop dup s" state_b64" obj-get then ( req val )
  node-str so-u ! so-a ! drop
  so-a @ so-u @ state-buf b64-decode ;

\ ---------------- coordinate statics ----------------
create idx-coord 9 cells allot
create keys-coord 9 cells allot
create kh-coord 9 cells allot
create ev-prefix 8 cells allot
create op-coord 9 cells allot
create ev-coord 9 cells allot
create cand-coord 9 cells allot
create tmp-coord 9 cells allot
: init-coords ( -- )
  s" 1.1.1/1.1.1/1.1.1" coord-parse idx-coord 9 cells move
  s" 1.1.1/1.1.1/1.1.2" coord-parse keys-coord 9 cells move
  s" 1.1.1/1.1.1/1.1.3" coord-parse kh-coord 9 cells move
  1 ev-prefix ! 1 ev-prefix cell+ ! 1 ev-prefix 2 cells + !
  1 ev-prefix 3 cells + ! 1 ev-prefix 4 cells + !
  1 ev-prefix 5 cells + ! 2 ev-prefix 6 cells + !
  1 ev-prefix 7 cells + ! ;
init-coords
: parse-to ( addr u dst -- ) >r coord-parse r> 9 cells move ;
: coord-reserved ( coord -- flag )  \ 1.1.1/1.1.1/1.1.1-3 always used
  8 0 do dup i cells + @ 1 <> if drop false unloop exit then loop
  8 cells + @ 4 < ;
: next-coord ( coord -- )  \ lexicographic +1 within 999^9
  9 0 do
    dup 8 i - cells + dup @ 999 < if 1 swap +! drop unloop exit
    else 1 swap ! then
  loop drop ;

\ ---------------- fail-detail builder ----------------
create fail-buf 2048 allot
variable fb-len
: fb-reset ( -- ) 0 fb-len ! ;
: fb-append ( addr u -- )
  dup >r fail-buf fb-len @ + swap move r> fb-len +! ;
: fb-num ( n -- ) 0 <# #s #> fb-append ;
: fb-str ( -- addr u ) fail-buf fb-len @ ;

\ ---------------- handlers ----------------
variable hd-req
: h-id ( -- ) s\" {\"impl\":\"forth\"}" resp-s ;
: h-keygen ( -- )
  do-keygen ( addr u )
  s\" {\"impl\":\"forth\",\"pubkey\":" resp-s resp-jstr s\" }" resp-s ;
: h-echo ( -- )
  hd-req @ s" ping" obj-get ( ping|0 )
  dup 0= if drop node-new dup 0 swap ! then
  can-arena arena-reset can-start
  s\" {\"impl\":\"forth\",\"ping\":" can-append
  swap canon-emit
  s\" }" can-append can-finish sha256hex ( hex 64 )
  s\" {\"impl\":\"forth\",\"echo\":" resp-s resp-jstr s\" }" resp-s ;
variable el-n variable el-seed variable el-cand
: h-elect ( -- )
  hd-req @ s" candidates" obj-get ( candnode )
  dup el-cand ! node-b el-n !
  can-arena arena-reset can-start
  hd-req @ s" position" obj-get node-str can-append
  hd-req @ s" turn" obj-get node-int 256 mod can-c!
  el-cand @ node-a ( first ) begin dup while
    dup node-str can-append
    node-next dup if [char] , can-c! then
  repeat drop
  can-finish sha256 ( -- ) sha-h @ 24 rshift el-seed !
  el-cand @ node-a ( first ) el-seed @ el-n @ mod 0 ?do node-next loop
  node-str ( winner )
  s\" {\"elect\":" resp-s resp-jstr s\" }" resp-s ;
variable ch-t variable ch-len
create ch-text 1024 allot variable ch-textlen
create ch-cs 64 allot variable ch-cslen
variable ch-pa variable ch-pu variable ch-turn
: choose-seed ( posaddr posu turn -- )
  ch-turn ! ch-pu ! ch-pa !
  can-arena arena-reset can-start
  ch-pa @ ch-pu @ can-append ( position bytes )
  ch-turn @ 256 mod can-c!
  ch-len @ 0 <# #s #> can-append
  state-buf ch-len @ 64 min can-append
  ch-len @ if
    state-buf ch-len @ + ch-len @ 64 min - ch-len @ 64 min can-append
  then
  can-finish sha256 ;
: h-choose ( -- )
  hd-req @ state-of ch-len !
  wk-arena arena-reset
  state-buf ch-len @ wk-arena explode ch-t !
  hd-req @ s" position" obj-get node-str ( pos u )
  2dup cand-coord parse-to
  hd-req @ s" turn" obj-get node-int ( pos u turn )
  choose-seed
  sha-h @ 16 rshift $ff and 9 mod ( dim )
  dup cells cand-coord + ( dimaddr )
  dup @ sha-h @ 8 rshift $ff and 3 mod 1+ + ( dimaddr newv )
  dup 999 > if 999 - then swap ! 
  begin
    cand-coord coord-reserved
    ch-t @ cand-coord table-find 0>= or
  while cand-coord next-coord repeat
  cand-coord coord>str ( cs u ) dup ch-cslen ! ch-cs swap move
  can-arena arena-reset can-start
  s" forth turn " can-append
  hd-req @ s" turn" obj-get node-int 0 <# #s #> can-append
  s"  at " can-append
  ch-cs ch-cslen @ can-append
  can-finish dup ch-textlen ! ch-text swap move
  ch-t @ table-free
  s\" {\"op\":\"insert\",\"coordinate\":" resp-s
  ch-cs ch-cslen @ resp-jstr
  s\" ,\"text\":" resp-s
  ch-text ch-textlen @ resp-jstr
  s\" }" resp-s ;
variable ap-len variable ap-fhexlen variable ap-ta variable ap-tu
variable ap-op variable ap-opu
create ap-fhexbuf 64 allot
: h-apply ( -- )
  hd-req @ state-of ap-len !
  hd-req @ s" step" obj-get ( step )
  dup s" coordinate" obj-get node-str op-coord parse-to
  dup s" text" obj-get node-str ap-tu ! ap-ta !
  s" op" obj-get node-str ap-opu ! ap-op !
  0 ap-fhexlen !
  ap-op @ ap-opu @ s" insert" compare 0= if
    state-buf ap-len @ op-coord ap-ta @ ap-tu @ insert ( naddr nu )
    dup ap-len ! state-buf swap move
    up-arena @ arena-free
  else ap-op @ ap-opu @ s" replace" compare 0= if
    state-buf ap-len @ op-coord ap-ta @ ap-tu @ replace ( naddr nu )
    dup ap-len ! state-buf swap move
    up-arena @ arena-free
  else ap-op @ ap-opu @ s" remove" compare 0= if
    state-buf ap-len @ op-coord remove-scroll ( naddr nu )
    dup ap-len ! state-buf swap move
  else ap-op @ ap-opu @ s" fetch" compare 0= if
    wk-arena arena-reset
    state-buf ap-len @ wk-arena explode ( t )
    dup op-coord table-fetch sha256hex ( t hex 64 )
    dup ap-fhexlen ! ap-fhexbuf swap move
    table-free
  then then then then
  s\" {\"state_b64\":\"" resp-s
  state-buf ap-len @ b64-encode-out
  s\" \",\"state_sha256\":\"" resp-s
  state-buf ap-len @ file-sha256hex resp-s
  s\" \",\"fetch_sha256\":" resp-s
  ap-fhexlen @ if ap-fhexbuf ap-fhexlen @ resp-jstr else s" null" resp-s then
  s\" }" resp-s ;
: h-attest ( -- )
  hd-req @ s" descriptor" obj-get canon-of ( addr u )
  do-sign ( sigaddr sigu )
  s\" {\"signature\":" resp-s resp-jstr s\" }" resp-s ;
: h-init ( -- )
  hd-req @ state-of ( len )
  dup cache-len !
  state-buf cache-buf rot move
  cache-table @ if cache-table @ table-free then
  cache-arena arena-reset
  cache-buf cache-len @ cache-arena explode cache-table !
  s\" {\"impl\":\"forth\",\"verdict\":\"pass\"}" resp-s ;

\ ---------------- validate ----------------
25000000 allocate throw constant prior-buf
variable vd-t variable vd-pt variable vd-len
variable vd-ta variable vd-tu variable vd-op variable vd-opu
variable vd-ila variable vd-ilu
: entry-text ( t i -- addr u ) 2dup table-text -rot table-textlen ;
: vd-fail ( -- ) 7777 throw ;
: vd-parse-step ( -- )
  hd-req @ s" step" obj-get ( step )
  dup s" coordinate" obj-get node-str op-coord parse-to
  dup s" text" obj-get node-str vd-tu ! vd-ta !
  s" op" obj-get node-str vd-opu ! vd-op ! ;
: vd-placed ( -- )  \ vd-t op-coord holds exactly the step text
  vd-t @ op-coord table-find dup 0< if
    drop fb-reset s" placed scroll missing or altered" fb-append vd-fail
  then
  vd-t @ swap entry-text ( addr u )
  dup vd-tu @ <> if 2drop fb-reset
    s" placed scroll missing or altered" fb-append vd-fail then
  vd-ta @ vd-tu @ compare 0<> if fb-reset
    s" placed scroll missing or altered" fb-append vd-fail then ;
variable ed-t1 variable ed-t2 variable ed-i variable ed-ci
: entry-differs ( t1 t2 i -- flag )
  \ true when entry i of t1 is missing from t2 or its text differs
  ed-i ! ed-t2 ! ed-t1 !
  ed-t1 @ ed-i @ table-coord ed-ci !
  ed-t2 @ ed-ci @ table-find ( fi )
  dup 0< if drop true exit then
  ed-t2 @ swap entry-text ( na nu )
  ed-t1 @ ed-i @ entry-text ( na nu ca cu )
  dup 3 pick <> if 2drop 2drop true exit then
  compare 0<> ;
: vd-driver ( -- )
  hd-req @ s" event_coord" obj-get node-str ev-coord parse-to
  hd-req @ s" index_line" obj-get node-str vd-ilu ! vd-ila !
  cache-table @ 0= if fb-reset
    s" no prior state (init not called)" fb-append vd-fail then
  hd-req @ state-of vd-len !
  wk-arena arena-reset
  state-buf vd-len @ wk-arena explode vd-t !
  vd-placed
  \ prior scrolls intact (skip the index coordinate)
  cache-table @ @ 0 ?do
    cache-table @ i table-coord dup idx-coord coord= 0= if
      cache-table @ vd-t @ i entry-differs if
        fb-reset s" prior scroll overwritten at " fb-append
        ed-ci @ coord>str fb-append vd-fail
      then
    then
  loop
  \ no unexpected new scrolls
  vd-t @ dup @ 0 ?do
    dup i table-coord ( nt ci )
    cache-table @ over table-find 0< if
      dup op-coord coord= 0=
      over ev-coord coord= 0= and if
        fb-reset s" unexpected new scroll at " fb-append
        coord>str fb-append vd-fail
      then
    then drop
  loop drop
  \ index tail
  vd-t @ idx-coord table-find dup 0< if
    drop fb-reset s" index does not record the placement" fb-append vd-fail
  then
  vd-t @ swap entry-text ( ia iu )
  begin dup 0> if 2dup + 1- c@ 10 = else false then while 1- repeat
  vd-ilu @ begin dup 0> if
    vd-ila @ over + 1- c@ 10 = else false then while 1- repeat vd-ilu !
  dup vd-ilu @ < if 2drop fb-reset
    s" index does not record the placement" fb-append vd-fail then
  vd-ilu @ - + vd-ilu @ vd-ila @ vd-ilu @ compare 0<> if fb-reset
    s" index does not record the placement" fb-append vd-fail then
  \ adopt the new state as the cache
  cache-table @ table-free
  state-buf cache-buf vd-len @ move vd-len @ cache-len !
  cache-arena arena-reset
  cache-buf cache-len @ cache-arena explode cache-table !
  vd-t @ table-free
  fb-reset s" placed at unused coordinate; all prior scrolls intact"
  fb-append ;
: vd-wire ( -- )
  hd-req @ s" prior_state" obj-get dup 0<> if
    node-str prior-buf b64-decode ( plen )
    wk2-arena arena-reset
    prior-buf swap wk2-arena explode vd-pt !
  else drop then
  vd-op @ vd-opu @ s" insert" compare 0<> if fb-reset
    s" step op is not insert" fb-append vd-fail then
  hd-req @ state-of vd-len !
  wk-arena arena-reset
  state-buf vd-len @ wk-arena explode vd-t !
  vd-t @ op-coord table-find dup 0< if
    drop fb-reset s" placed scroll absent or content differs at "
    fb-append op-coord coord>str fb-append vd-fail
  then
  vd-t @ swap entry-text ( addr u )
  dup vd-tu @ <> if 2drop fb-reset
    s" placed scroll absent or content differs at " fb-append
    op-coord coord>str fb-append vd-fail then
  vd-ta @ vd-tu @ compare 0<> if fb-reset
    s" placed scroll absent or content differs at " fb-append
    op-coord coord>str fb-append vd-fail then
  vd-pt @ if
    vd-pt @ op-coord table-find 0>= if
      vd-pt @ swap entry-text nip 0> if fb-reset
        s" coordinate was not unused in the prior state" fb-append
        vd-fail then
    then
    vd-t @ @ vd-pt @ @ 1+ <> if fb-reset
      s" scroll count did not grow by exactly one" fb-append vd-fail then
    vd-pt @ @ 0 ?do
      vd-pt @ vd-t @ i entry-differs if
        fb-reset s" a prior scroll was overwritten: " fb-append
        ed-ci @ coord>str fb-append vd-fail
      then
    loop
    fb-reset s" placed at unused coordinate; all prior scrolls intact"
    fb-append
  else
    fb-reset
    s" placed scroll present with attested content (no prior state supplied)"
    fb-append
  then
  vd-t @ table-free
  vd-pt @ if vd-pt @ table-free then ;
: h-validate ( -- )
  vd-parse-step
  fb-reset 0 vd-pt !
  hd-req @ s" event_coord" obj-get 0<> if ['] vd-driver catch
  else ['] vd-wire catch then
  ( n ) dup 7777 = if drop
    s\" {\"impl\":\"forth\",\"verdict\":\"fail\",\"detail\":" resp-s
    fb-str resp-jstr s\" }" resp-s
  else dup if throw then drop
    s\" {\"impl\":\"forth\",\"verdict\":\"pass\",\"detail\":" resp-s
    fb-str resp-jstr s\" }" resp-s
  then ;

\ ---------------- verify ----------------
create ev-seq 8192 cells allot
create ev-ta 8192 cells allot
create ev-tu 8192 cells allot
variable vf-n variable vf-t variable vf-len variable vf-vgok
variable vf-i variable vf-body-node
create pl-coord 8192 9 * cells allot
create pl-turn 8192 cells allot
create pl-hash 8192 64 * allot
create pl-cs 8192 40 * allot
create pl-cslen 8192 cells allot
variable vf-pl
create prev-buf 64 allot
create att-buf 8192 allot
create cs-buf 128 allot variable cs-len
variable vf-ka variable vf-ku variable vf-kha variable vf-khu
variable vf-ci
variable si-s variable si-a variable si-u variable si-j
: vf-fail ( -- ) 7778 throw ;
: vf-seq-fail ( addr u seq -- )
  fb-reset fb-append fb-num vf-fail ;
: vf-chain-fail ( -- )
  fb-reset s" event chain broken at seq " fb-append
  vf-i @ 1+ fb-num vf-fail ;
: vf-hash-fail ( -- )
  fb-reset s" placement scroll hash mismatch seq " fb-append
  vf-i @ 1+ fb-num vf-fail ;
: vf-att-fail ( -- )
  fb-reset s" attestation fails at seq " fb-append
  vf-i @ 1+ fb-num vf-fail ;
: strip-ws ( addr u -- addr u )
  begin dup 0> if
    2dup + 1- c@ dup 32 = swap dup 9 = swap dup 10 = swap 13 = or or or
    else false then
  while 1- repeat
  begin dup 0> if
    over c@ dup 32 = swap dup 9 = swap dup 10 = swap 13 = or or or
    else false then
  while swap 1+ swap 1- repeat ;
\ index line iteration + tokenising
variable li-a variable li-p variable li-end
variable il-p0 variable il-pe variable il-done
: idx-line-next ( -- la lu flag )
  li-p @ li-end @ >= if 0 0 false exit then
  li-p @ il-p0 ! li-p @ il-pe ! false il-done !
  begin il-done @ 0= while
    il-pe @ li-end @ >= if true il-done !
    else li-a @ il-pe @ + c@ 10 = if true il-done !
    else il-pe @ 1+ il-pe ! then then
  repeat
  li-a @ il-p0 @ + ( la )
  il-pe @ il-p0 @ - ( la lu )
  il-pe @ li-end @ < if il-pe @ 1+ li-p ! else il-pe @ li-p ! then
  true ;
variable tk-p variable tk-e
: tk-init ( la lu -- ) over + tk-e ! tk-p ! ;
: tk-next ( -- ta tu flag )
  begin tk-p @ tk-e @ < if tk-p @ c@ 32 = else false then while
    tk-p @ 1+ tk-p ! repeat
  tk-p @ tk-e @ >= if tk-p @ 0 false exit then
  tk-p @
  begin tk-p @ tk-e @ < if tk-p @ c@ 32 <> else false then while
    tk-p @ 1+ tk-p ! repeat
  tk-p @ over - true ;
variable ic-la variable ic-lu variable ic-ca variable ic-cu
variable ic-row
: idx-check-line ( la lu -- )
  ic-lu ! ic-la !
  ic-la @ ic-lu @ tk-init
  tk-next 0= if exit then 2drop
  tk-next 0= if exit then ic-cu ! ic-ca !
  -1 ic-row !
  vf-pl @ 0 ?do
    ic-cu @ pl-cslen i cells + @ = if
      ic-ca @ ic-cu @ pl-cs i 40 * + ic-cu @ compare 0= if i ic-row ! then
    then
  loop
  ic-row @ 0< if
    fb-reset s" index hash mismatch: " fb-append
    ic-la @ ic-lu @ 40 min fb-append vf-fail
  then
  tk-next 0= if exit then ( ha hu )
  dup 64 <> if 2drop fb-reset s" index hash mismatch: " fb-append
    ic-la @ ic-lu @ 40 min fb-append vf-fail then
  pl-hash ic-row @ 64 * + 64 compare 0<> if fb-reset
    s" index hash mismatch: " fb-append
    ic-la @ ic-lu @ 40 min fb-append vf-fail then ;
: vf-body ( -- )
  hd-req @ state-of vf-len !
  wk-arena arena-reset
  state-buf vf-len @ wk-arena explode vf-t !
  \ keys + keys-hash
  vf-t @ keys-coord table-find dup 0< if drop 0 0
  else vf-t @ swap entry-text then vf-ku ! vf-ka !
  vf-t @ kh-coord table-find dup 0< if
    drop fb-reset s" keys-hash scroll does not match keys" fb-append
    vf-fail
  then
  vf-t @ swap entry-text strip-ws vf-khu ! vf-kha !
  vf-ka @ vf-ku @ sha256hex ( hex 64 )
  vf-khu @ 64 <> if 2drop fb-reset
    s" keys-hash scroll does not match keys" fb-append vf-fail then
  vf-kha @ 64 compare 0<> if fb-reset
    s" keys-hash scroll does not match keys" fb-append vf-fail then
  vf-ka @ vf-ku @ vgnupg-setup vf-vgok !
  \ collect events
  0 vf-n !
  vf-t @ @ 0 ?do
    vf-t @ i table-coord vf-ci !
    vf-ci @ 64 ev-prefix 64 compare 0= if
      vf-ci @ 8 cells + @ ev-seq vf-n @ cells + !
      vf-t @ vf-ci @ table-fetch ( a u )
      dup ev-tu vf-n @ cells + !
      swap ev-ta vf-n @ cells + ! drop
      vf-n @ 1+ vf-n !
    then
  loop
  \ insertion sort events by seq
  vf-n @ 1 > if
  vf-n @ 1 ?do
    ev-seq i cells + @ si-s ! ev-ta i cells + @ si-a !
    ev-tu i cells + @ si-u ! i si-j !
    begin si-j @ 0> if ev-seq si-j @ 1- cells + @ si-s @ >
      else false then while
      ev-seq si-j @ 1- cells + @ ev-seq si-j @ cells + !
      ev-ta si-j @ 1- cells + @ ev-ta si-j @ cells + !
      ev-tu si-j @ 1- cells + @ ev-tu si-j @ cells + !
      si-j @ 1- si-j !
    repeat
    si-s @ ev-seq si-j @ cells + !
    si-a @ ev-ta si-j @ cells + !
    si-u @ ev-tu si-j @ cells + !
  loop
  then
  \ walk the chain
  0 vf-pl !
  vf-n @ 0 ?do
    i vf-i !
    ev-seq i cells + @ ( seq )
    dup vf-i @ 1+ <> if s" event seq gap at " rot vf-seq-fail then
    drop
    node-arena arena-reset
    ev-ta i cells + @ ev-tu i cells + @ json-parse ( evn )
    dup s" prev" obj-get ( evn pv )
    vf-i @ 0= if
      dup 0<> if dup node-type 0<> if drop drop vf-chain-fail
      then then
      drop ( evn )
    else
      dup 0= if drop vf-chain-fail then
      node-str ( evn pa pu )
      dup 64 <> if 2drop vf-chain-fail then
      prev-buf 64 compare 0<> if vf-chain-fail then
      ( evn )
    then
    dup s" body" obj-get ( evn body )
    dup 0= if drop drop vf-chain-fail then
    dup vf-body-node !
    dup canon-of sha256hex prev-buf swap move drop ( evn )
    vf-body-node @ s" type" obj-get node-str s" placement"
    compare 0= if
      vf-body-node @ s" coord" obj-get node-str ( ca cu )
      dup cs-len ! cs-buf swap move
      cs-buf cs-len @ tmp-coord parse-to
      vf-pl @ 0 ?do
        pl-coord i 72 * + tmp-coord coord= if
          fb-reset s" coordinate reused at seq " fb-append
          vf-i @ 1+ fb-num vf-fail
        then
      loop
      vf-t @ tmp-coord table-find dup 0< if drop vf-hash-fail then
      vf-t @ swap entry-text sha256hex ( hex 64 )
      vf-body-node @ s" text_sha256" obj-get node-str ( hex 64 ha hu )
      dup 64 <> if 2drop 2drop vf-hash-fail then
      compare 0<> if vf-hash-fail then
      \ canonical descriptor
      can-arena arena-reset can-start
      s\" {\"coordinate\":" can-append
      cs-buf cs-len @ ce-esc
      s\" ,\"file_sha256\":" can-append
      vf-body-node @ s" file_sha256" obj-get node-str ce-esc
      s\" ,\"scroll_sha256\":" can-append
      vf-body-node @ s" text_sha256" obj-get node-str ce-esc
      s\" ,\"turn\":" can-append
      vf-body-node @ s" turn" obj-get node-int 0 <# #s #> can-append
      [char] } can-c!
      can-finish ( da du )
      vf-body-node @ s" att" obj-get node-str ( da du aa au )
      att-buf b64-decode ( da du su )
      vf-vgok @ 0= if drop 2drop vf-att-fail then
      att-buf swap do-verify-sig ( flag )
      0= if vf-att-fail then
      vf-body-node @ s" turn" obj-get node-int
      pl-turn vf-pl @ cells + !
      tmp-coord pl-coord vf-pl @ 72 * + 9 cells move
      vf-body-node @ s" text_sha256" obj-get node-str ( ha hu )
      drop pl-hash vf-pl @ 64 * + 64 move
      cs-buf pl-cs vf-pl @ 40 * + cs-len @ move
      cs-len @ pl-cslen vf-pl @ cells + !
      vf-pl @ 1+ vf-pl !
    then
  loop
  \ index cross-check
  vf-t @ idx-coord table-find dup 0< if drop 0 0
  else vf-t @ swap entry-text then
  li-end ! li-a ! 0 li-p !
  0 ( nidx )
  begin idx-line-next while ( nidx la lu )
    dup 0> if over c@ [char] # <> if rot 1+ -rot then then
    2drop
  repeat 2drop ( nidx )
  vf-pl @ <> if fb-reset
    s" index lines != placements" fb-append vf-fail then
  0 li-p !
  begin idx-line-next while ( la lu )
    dup 0> if over c@ [char] # <> if idx-check-line
    else 2drop then else 2drop then
  repeat 2drop ;
: h-verify ( -- )
  fb-reset 0 vf-pl ! 0 vf-t !
  ['] vf-body catch ( n )
  dup 7778 = if drop
    s\" {\"impl\":\"forth\",\"verdict\":\"fail\",\"placements_checked\":"
    resp-s vf-pl @ resp-num
    s\" ,\"first_failure\":{\"detail\":" resp-s
    fb-str resp-jstr s\" }}" resp-s
  else dup if throw then drop
    s\" {\"impl\":\"forth\",\"verdict\":\"pass\",\"placements_checked\":"
    resp-s vf-pl @ resp-num
    s\" ,\"first_failure\":null}" resp-s
  then
  vf-t @ if vf-t @ table-free 0 vf-t ! then ;

\ ---------------- dispatch + framing + main ----------------
: handle ( req -- )
  dup hd-req !
  s" cmd" obj-get node-str ( cmd cu )
  resp-start
  2dup s" id" compare 0= if 2drop h-id exit then
  2dup s" keygen" compare 0= if 2drop h-keygen exit then
  2dup s" echo" compare 0= if 2drop h-echo exit then
  2dup s" elect" compare 0= if 2drop h-elect exit then
  2dup s" choose" compare 0= if 2drop h-choose exit then
  2dup s" apply" compare 0= if 2drop h-apply exit then
  2dup s" attest" compare 0= if 2drop h-attest exit then
  2dup s" init" compare 0= if 2drop h-init exit then
  2dup s" validate" compare 0= if 2drop h-validate exit then
  2dup s" verify" compare 0= if 2drop h-verify exit then
  2drop s\" {\"error\":\"unknown cmd\"}" resp-s ;
: process ( addr u -- )
  node-arena arena-reset
  json-parse ( req )
  ['] handle catch ( n )
  if resp-start s\" {\"error\":\"gforth exception\"}" resp-s then ;
: emit-response ( serve -- )
  out-arena arena-ptr out-arena @ - ( serve len )
  dup 8192 > rot and if
    drop
    out-arena @ out-arena arena-ptr over - s" in.bin" write-tmp
    cmd-reset s" gzip -c " cmd-append tmpdir tmpdir-len cmd-append
    s" /in.bin > " cmd-append tmpdir tmpdir-len cmd-append
    s" /in.bin.gz" cmd-append run-cmd
    s" in.bin.gz" file-buf read-tmp file-buf swap ( gz gu )
    s" GZ1:" type
    node-arena arena-reset
    node-arena b64-encode-to
    node-arena @ node-arena arena-ptr over - type cr
  else
    drop out-arena @ out-arena arena-ptr over - type cr
  then
  stdout flush-file drop ;
: gz1? ( addr u -- flag )
  dup 4 < if 2drop false exit then
  drop 4 s" GZ1:" compare 0= ;
: serve-loop ( -- )
  begin
    depth 0 ?do drop loop
    line-buf 20971520 stdin read-line throw ( u flag )
    0= if drop bye then
    ( u ) dup 0> if
      line-buf over gz1? ( u framed? )
      if ( u )
        4 - line-buf 4 + swap ( src u )
        state-buf b64-decode ( gu )
        state-buf swap s" frame.gz" write-tmp
        cmd-reset s" gzip -dc " cmd-append tmpdir tmpdir-len cmd-append
        s" /frame.gz > " cmd-append tmpdir tmpdir-len cmd-append
        s" /frame.bin" cmd-append run-cmd
        s" frame.bin" file-buf read-tmp file-buf swap ( ja ju )
        process
      else
        line-buf swap process
      then
      true emit-response
    else drop then
  again ;
: one-shot ( -- )
  line-buf 20971520 stdin read-line throw drop ( u )
  dup 0> if line-buf swap process else drop then
  false emit-response bye ;
: main ( -- )
  next-arg s" serve" compare 0= if serve-loop else one-shot then ;
main
