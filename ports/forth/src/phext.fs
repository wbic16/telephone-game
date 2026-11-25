\ libphext-forth -- a Gforth port of libphext (0.6.1 parity).
\
\ Semantics normative from libphext-py: a phext is a byte buffer;
\ nine dimension-break bytes walk a 9-component coordinate; scroll
\ text is a maximal run of non-break bytes (newline 0x0A is ordinary
\ text). Coordinates are 9 cells in an array, ordered
\ lexicographically; string form a.b.c/d.e.f/g.h.i.
\
\ A scroll table is an address holding [count] [capacity] [entries];
\ each entry is 11 cells: coord(9) text-addr text-len. Text bytes
\ live in arenas (bump-allocated byte regions).

\ ---------------- arenas ----------------
variable ma-base variable ma-hdr
: make-arena ( size -- arena )  \ arena cells: base ptr end
  dup allocate throw ma-base !
  3 cells allocate throw ma-hdr !
  ma-base @ ma-hdr @ !
  ma-base @ ma-hdr @ cell+ !
  ma-base @ + ma-hdr @ 2 cells + !
  ma-hdr @ ;
: arena-ptr ( arena -- addr ) cell+ @ ;
: arena-free ( arena -- n ) dup 2 cells + @ swap cell+ @ - ;
variable aa-a
: arena-alloc ( n arena -- addr )
  aa-a !
  dup aa-a @ arena-free > if ." arena overflow" cr abort then
  aa-a @ arena-ptr swap dup aa-a @ cell+ +! drop ;
: arena-append ( addr u arena -- taddr )
  >r dup r@ arena-alloc ( addr u taddr )
  dup >r swap move r> rdrop ;

\ ---------------- coordinates ----------------
create break-table 256 allot
create break-bytes 1 c, 31 c, 30 c, 29 c, 28 c, 26 c, 25 c, 24 c, 23 c,
: init-breaks ( -- )
  256 0 do 0 break-table i + c! loop
  9 0 do i 1+ break-bytes i + c@ break-table + c! loop ;
init-breaks

: coord-root ( addr -- ) 9 0 do 1 over i cells + ! loop drop ;
: coord-cmp ( a b -- -1|0|1 )
  9 0 do
    dup i cells + @ 2 pick i cells + @
    2dup < if 2drop 2drop 1 unloop exit then
    > if 2drop -1 unloop exit then
  loop 2drop 0 ;
: coord= ( a b -- flag ) coord-cmp 0= ;
: coord-apply-break ( coord dim -- )
  2dup cells + dup @ 1+ swap !
  1+ 9 swap ?do dup i cells + 1 swap ! loop drop ;
create coord-out 9 cells allot
create coord-tmp 9 cells allot
: coord-parse ( addr u -- coord-out )
  coord-out 9 cells erase
  0 ( idx ) >r
  begin dup 0> while
    0 ( val ) >r
    begin dup 0> 2 pick c@ [char] 0 [char] 9 1+ within and while
      over c@ [char] 0 - r> 10 * + >r 1 /string
    repeat
    r> r@ cells coord-out + !
    r> 1+ >r
    dup 0> if 1 /string then
  repeat 2drop rdrop
  coord-out 9 0 do dup i cells + @ 1 < if ." bad coord" cr abort then loop ;
: coord-copy ( src dst -- ) 9 cells move ;
variable cs-c variable cs-len
: coord>str ( coord -- addr u )
  cs-c ! 0 cs-len !
  9 0 do
    i 0> if
      i 3 = i 6 = or if [char] / else [char] . then
      pad cs-len @ + c! 1 cs-len +!
    then
    cs-c @ i cells + @ 0 <# #s #> ( addr u )
    dup >r pad cs-len @ + swap move r> cs-len +!
  loop
  pad cs-len @ ;
\ ---------------- scroll table ----------------
11 constant entry-cells
: table-new ( cap -- table )
  3 cells allocate throw >r
  0 r@ ! dup r@ cell+ !
  entry-cells cells * allocate throw r@ 2 cells + !
  r> ;
: table-count ( t -- n ) @ ;
: table-entry ( t i -- eaddr ) entry-cells cells * swap 2 cells + @ + ;
: table-coord ( t i -- caddr ) table-entry ;
: table-text ( t i -- addr ) table-entry 9 cells + @ ;
: table-textlen ( t i -- u ) table-entry 10 cells + @ ;
variable ts-t variable ts-i variable ts-a variable ts-u
: table-set-text ( t i addr u -- )
  ts-u ! ts-a ! ts-i ! ts-t !
  ts-a @ ts-t @ ts-i @ table-entry 9 cells + !
  ts-u @ ts-t @ ts-i @ table-entry 10 cells + ! ;
variable tg-t variable tg-n
: table-grow ( t -- )
  tg-t !
  tg-t @ cell+ @ 2* tg-n !
  tg-t @ 2 cells + @ tg-n @ entry-cells cells * resize throw
  tg-t @ 2 cells + !
  tg-n @ tg-t @ cell+ ! ;
variable tp-t variable tp-coord variable tp-a variable tp-u
: table-push ( t coord taddr tlen -- )
  tp-u ! tp-a ! tp-coord ! tp-t !
  tp-t @ table-count tp-t @ cell+ @ >= if tp-t @ table-grow then
  tp-t @ dup table-count table-entry >r
  tp-coord @ r@ 9 cells move
  tp-a @ r@ 9 cells + !
  tp-u @ r> 10 cells + !
  1 tp-t @ +! ;
: table-find ( t coord -- idx|-1 )
  over table-count 0 ?do
    1 pick i table-coord over coord= if 2drop i unloop exit then
  loop 2drop -1 ;
create swap-entry 11 cells allot
variable sw-t variable sw-i variable sw-j
: table-swap ( t i j -- )
  sw-j ! sw-i ! sw-t !
  sw-t @ sw-i @ table-entry swap-entry 11 cells move
  sw-t @ sw-j @ table-entry sw-t @ sw-i @ table-entry 11 cells move
  swap-entry sw-t @ sw-j @ table-entry 11 cells move ;
variable eg-i variable eg-j
: entry-gt ( t i j -- flag )
  eg-j ! eg-i ! dup eg-i @ table-coord swap eg-j @ table-coord
  coord-cmp 0> ;
variable srt-t variable srt-j
: table-sort ( t -- )  \ insertion sort (walk order is near-sorted)
  dup table-count 2 < if drop exit then
  dup srt-t ! table-count 1 ?do
    i srt-j !
    begin srt-j @ 0> while
      srt-t @ srt-j @ 1- srt-j @ entry-gt
      if srt-t @ srt-j @ 1- srt-j @ table-swap -1 srt-j +!
      else 0 srt-j ! then
    repeat
  loop ;
variable tr-t variable tr-i
: table-remove-at ( t idx -- )
  tr-i ! tr-t !
  tr-t @ table-count 1- tr-i @ ?do
    tr-t @ i 1+ table-entry tr-t @ i table-entry 11 cells move
  loop
  -1 tr-t @ +! ;
variable tf-t variable tf-i
: table-fetch ( t coord -- addr u )
  over tf-t ! table-find dup 0< if drop 0 0 else
    tf-i ! tf-t @ tf-i @ table-text tf-t @ tf-i @ table-textlen then ;

\ ---------------- phext core ----------------
variable ph-buf variable ph-len variable ph-arena variable ph-table
variable ph-buf variable ph-len variable ph-arena variable ph-table
variable pe-rs variable pe-i
: ph-emit ( run-start i -- )
  pe-i ! pe-rs !
  ph-buf @ pe-rs @ + pe-i @ pe-rs @ -
  dup >r ph-arena @ arena-append r> ( taddr len )
  ph-table @ coord-out 2swap table-push ;
: phokenize ( buf u arena table -- )
  ph-table ! ph-arena ! ph-len ! ph-buf !
  coord-out coord-root
  0 ( run-start ) 0 ( i )
  begin dup ph-len @ < while
    dup ph-buf @ + c@ break-table + c@ ( dim+1 )
    dup 0= if drop else
      1- >r
      2dup < if 2dup ph-emit then
      coord-out r> coord-apply-break
      nip dup 1+ swap ( new run-start, i unchanged; loop 1+ advances i )
    then
    1+
  repeat
  drop ( run-start )
  dup ph-len @ < if
    ph-buf @ over + ph-len @ rot - ( addr len )
    dup >r ph-arena @ arena-append r> ( taddr len )
    ph-table @ coord-out 2swap table-push
  else drop then ;
: explode ( buf u arena -- table )
  2048 table-new dup >r phokenize r> ;
create loc-coord 9 cells allot
variable em-dim
variable ef-b variable ef-a
: emit-fill ( byte count arena -- )
  ef-a ! swap ef-b !
  0 ?do ef-b @ ef-a @ arena-ptr c! 1 ef-a @ cell+ +! loop ;
variable ea-t variable ea-a
: emit-advance ( target arena -- )
  ea-a ! ea-t !
  loc-coord ea-t @ coord-cmp 0< if
    9 0 do loc-coord i cells + @ ea-t @ i cells + @ <> if i em-dim ! leave then loop
    break-bytes em-dim @ + c@
    ea-t @ em-dim @ cells + @ loc-coord em-dim @ cells + @ -
    ea-a @ emit-fill
    9 em-dim @ 1+ ?do
      break-bytes i + c@ ea-t @ i cells + @ 1- ea-a @ emit-fill
    loop
    ea-t @ loc-coord 9 cells move
  then ;
variable dt-t variable dt-a
: dephokenize-table ( t outarena -- addr u )
  dt-a ! dt-t !
  dt-a @ arena-ptr ( start )
  loc-coord coord-root
  dt-t @ table-sort
  dt-t @ table-count 0 ?do
    dt-t @ i table-textlen 0> if
      dt-t @ i table-coord dt-a @ emit-advance
      dt-t @ i table-text dt-t @ i table-textlen dt-a @ arena-append drop
    then
  loop
  dt-a @ arena-ptr over - ;
: implode ( t outarena -- addr u ) dephokenize-table ;
: normalize ( buf u -- addr u )
  67108864 make-arena dup >r explode r@ dephokenize-table rdrop ;
: dephokenize ( buf u -- addr u ) normalize ;
variable fe-c
: fetch ( buf u coord -- addr u )
  fe-c !
  16777216 make-arena explode fe-c @ table-fetch ;
\ insert/replace/remove via the exploded map (implode re-sorts)
variable ac-a variable ac-2 variable ac-2u
: arena-cat ( a1 u1 a2 u2 arena -- addr u )
  ac-a ! ac-2u ! ac-2 !
  ac-a @ arena-ptr >r
  ac-a @ arena-append drop
  ac-2 @ ac-2u @ ac-a @ arena-append drop
  r> dup ac-a @ arena-ptr swap - ;
variable up-arena
variable ub-b variable ub-u variable ub-c variable ub-s variable ub-sl variable ub-o variable ub-t variable ub-i
: update-buffer ( buf u coord scroll su overwrite -- addr u )
  ub-o ! ub-sl ! ub-s ! ub-c ! ub-u ! ub-b !
  33554432 make-arena up-arena !
  ub-b @ ub-u @ up-arena @ explode ub-t !
  ub-t @ ub-c @ table-find ub-i !
  ub-i @ 0< if
    ub-sl @ 0> if ub-t @ ub-c @ ub-s @ ub-sl @ table-push then
  else ub-o @ if
      ub-sl @ 0= if ub-t @ ub-i @ table-remove-at
      else ub-t @ ub-i @ ub-s @ ub-sl @ table-set-text then
    else
      ub-t @ ub-i @ table-text ub-t @ ub-i @ table-textlen ub-s @ ub-sl @ up-arena @ arena-cat ( a u )
      ub-t @ ub-i @ 2swap table-set-text
    then
  then
  ub-t @ up-arena @ dephokenize-table ;
: insert ( buf u coord scroll su -- addr u ) 0 update-buffer ;
: replace ( buf u coord scroll su -- addr u ) -1 update-buffer ;
: remove-scroll ( buf u coord -- addr u )
  0 0 -1 update-buffer normalize ;
33554432 make-arena up-arena !

\ ---------------- DynamicPhext ----------------
\ header: [table] [n] [capacity] [resize-count] [copied] [shrink-div]
: dynamic-new ( shrink-div -- dyn )
  6 cells allocate throw >r
  2048 table-new r@ !
  0 r@ cell+ ! 1 r@ 2 cells + ! 0 r@ 3 cells + !
  0 r@ 4 cells + ! r@ 5 cells + ! r> ;
: dynamic-length ( dyn -- n ) cell+ @ ;
: dynamic-capacity ( dyn -- n ) 2 cells + @ ;
: dynamic-resize-count ( dyn -- n ) 3 cells + @ ;
variable drz-d variable drz-n
: dynamic--resize ( dyn newcap -- )
  drz-n ! drz-d !
  drz-d @ cell+ @ drz-d @ 4 cells + +!
  drz-n @ drz-d @ 2 cells + !
  1 drz-d @ 3 cells + +! ;
: dynamic--grow ( dyn -- )
  dup cell+ @ over 2 cells + @ >= if
    dup 2 cells + @ 2* dynamic--resize
  then drop ;
: dynamic--shrink ( dyn -- )
  dup 2 cells + @ 1 > if
    dup cell+ @ over 2 cells + @ 2 pick 5 cells + @ / <= if
      dup 2 cells + @ 2/ 1 max dynamic--resize exit
    then
  then drop ;
variable dp-d variable dp-c variable dp-a variable dp-u
: dynamic-push ( dyn coord taddr tlen -- )
  dp-u ! dp-a ! dp-c ! dp-d !
  dp-d @ dynamic--grow
  dp-d @ @ dp-c @ dp-a @ dp-u @ table-push
  1 dp-d @ cell+ +! ;
variable dl-t variable dl-d
: dynamic-load ( buf u dyn -- )
  dl-d !
  16777216 make-arena explode dl-t !
  2048 table-new dl-d @ !
  0 dl-d @ cell+ ! 1 dl-d @ 2 cells + ! 0 dl-d @ 3 cells + ! 0 dl-d @ 4 cells + !
  dl-t @ table-count 0 ?do
    dl-d @ dl-t @ i table-coord dl-t @ i table-text dl-t @ i table-textlen dynamic-push
  loop ;
: dynamic-find ( dyn coord -- idx flag )
  swap @ swap table-find dup 0< if drop -1 false else true then ;
: dynamic-fetch ( dyn coord -- addr u ) swap @ swap table-fetch ;
variable da-d variable da-c variable da-a variable da-u
: dynamic-append ( dyn coord taddr tlen -- )
  da-u ! da-a ! da-c ! da-d !
  da-u @ 0= if exit then
  da-d @ cell+ @ 0> if
    da-d @ @ dup table-count 1- table-coord da-c @ coord-cmp 0>=
    if ." append order" cr abort then
  then
  da-d @ da-c @ da-a @ da-u @ dynamic-push ;
: dynamic-serialize ( dyn outarena -- addr u ) swap @ swap dephokenize-table ;
: dynamic-remove-at ( dyn idx -- )
  over @ swap table-remove-at
  -1 over cell+ +! dynamic--shrink ;
variable du-d variable du-c variable du-a variable du-u variable du-o variable du-i
: dynamic-update ( dyn coord taddr tlen overwrite -- )
  du-o ! du-u ! du-a ! du-c ! du-d !
  du-d @ du-c @ dynamic-find ( idx flag )
  if du-i !
    du-u @ 0= if
      du-o @ if du-d @ du-i @ dynamic-remove-at then
    else du-o @ if
        du-d @ @ du-i @ du-a @ du-u @ table-set-text
      else
        16777216 make-arena >r
        du-d @ @ du-i @ table-text du-d @ @ du-i @ table-textlen du-a @ du-u @ r@ arena-cat
        r> drop ( addr u )
        du-d @ @ du-i @ 2swap table-set-text
      then
    then
  else drop
    du-u @ 0> if du-d @ du-c @ du-a @ du-u @ dynamic-push then
  then ;
: dynamic-insert ( dyn coord a u -- ) 0 dynamic-update ;
: dynamic-replace ( dyn coord a u -- ) -1 dynamic-update ;
variable dr-d variable dr-c
: dynamic-remove ( dyn coord -- )
  dr-c ! dr-d !
  dr-d @ dr-c @ dynamic-find if dr-d @ swap dynamic-remove-at else drop then ;

\ ---------------- BranchingMap / TransitivePhext ----------------
\ Node: [pair-array] [cap] [count]; pair = [key] [val] [len]
\ (len = -1 marks a child node in val).
: bnode-new ( -- node )
  3 cells allocate throw >r
  8 r@ cell+ ! 0 r@ 2 cells + !
  8 3 * cells allocate throw r@ ! r> ;
: bnode-pair ( node i -- paddr ) 3 cells * swap @ + ;
variable bf-n variable bf-k
: bnode-find ( node key -- idx|-1 )
  bf-k ! bf-n !
  bf-n @ 2 cells + @ 0 ?do
    bf-n @ i bnode-pair @ bf-k @ = if i unloop exit then
  loop -1 ;
: bnode-grow ( node -- )
  dup @ over cell+ @ 2* 3 * cells resize throw over !
  dup cell+ @ 2* swap cell+ ! ;
variable ba-n variable ba-k variable ba-v variable ba-l
: bnode-add ( node key val len -- )
  ba-l ! ba-v ! ba-k ! ba-n !
  ba-n @ 2 cells + @ ba-n @ cell+ @ >= if ba-n @ bnode-grow then
  ba-k @ ba-n @ ba-n @ 2 cells + @ bnode-pair !
  ba-v @ ba-n @ ba-n @ 2 cells + @ bnode-pair cell+ !
  ba-l @ ba-n @ ba-n @ 2 cells + @ bnode-pair 2 cells + !
  1 ba-n @ 2 cells + +! ;
variable bs-n variable bs-i variable bs-v variable bs-l
: bnode-set ( node idx val len -- )
  bs-l ! bs-v ! bs-i ! bs-n !
  bs-v @ bs-n @ bs-i @ bnode-pair cell+ !
  bs-l @ bs-n @ bs-i @ bnode-pair 2 cells + ! ;
\ branching map: [depth] [root] [count]
: branching-new ( depth -- bm )
  3 cells allocate throw >r
  dup r@ ! bnode-new r@ cell+ ! 0 r@ 2 cells + ! r> ;
variable bp-text variable bp-len variable bp-created
variable bp-n variable bp-c variable bp-d
: branching-put-rec ( node comps depth -- )
  bp-d ! bp-c ! bp-n !
  bp-d @ 1 = if
    bp-n @ bp-c @ @ bnode-find ( idx )
    dup 0< if drop bp-n @ bp-c @ @ bp-text @ bp-len @ bnode-add true bp-created !
    else bp-n @ swap bp-text @ bp-len @ bnode-set false bp-created ! then
  else
    bp-n @ bp-c @ @ bnode-find ( idx )
    dup 0< if drop bnode-new ( child )
      dup bp-n @ bp-c @ @ rot -1 bnode-add
      bp-c @ cell+ bp-d @ 1- recurse
    else bp-n @ swap bnode-pair cell+ @ bp-c @ cell+ bp-d @ 1- recurse then
  then ;
variable bp-bm
: branching-put ( bm coord text tlen -- bm created )
  bp-len ! bp-text ! swap bp-bm !
  bp-bm @ cell+ @ swap bp-bm @ @ branching-put-rec
  bp-created @ if 1 bp-bm @ 2 cells + +! then
  bp-bm @ bp-created @ ;
variable bg-n variable bg-c variable bg-d
: branching-fetch-rec ( node comps depth -- addr u )
  bg-d ! bg-c ! bg-n !
  bg-n @ bg-c @ @ bnode-find ( idx )
  dup 0< if drop 0 0 else
    bg-d @ 1 = if bg-n @ swap bnode-pair dup cell+ @ swap 2 cells + @
    else bg-n @ swap bnode-pair cell+ @ bg-c @ cell+ bg-d @ 1- recurse then
  then ;
: branching-fetch ( bm coord -- addr u )
  swap dup >r cell+ @ swap r> @ branching-fetch-rec ;
variable br-removed
variable brm-n variable brm-c variable brm-d variable brm-i
: branching-remove-rec ( node comps depth -- )
  brm-d ! brm-c ! brm-n !
  brm-n @ brm-c @ @ bnode-find ( idx )
  dup 0< if drop else brm-i !
    brm-d @ 1 = if
      brm-n @ 2 cells + @ 1- brm-i @ ?do
        brm-n @ i 1+ bnode-pair brm-n @ i bnode-pair 3 cells move
      loop
      -1 brm-n @ 2 cells + +!
      true br-removed !
    else
      brm-n @ brm-i @ bnode-pair cell+ @ brm-c @ cell+ brm-d @ 1- recurse
    then
  then ;
variable brm-bm
: branching-remove ( bm coord -- bm removed )
  false br-removed !
  swap brm-bm !
  brm-bm @ cell+ @ swap brm-bm @ @ branching-remove-rec
  br-removed @ if -1 brm-bm @ 2 cells + +! then
  brm-bm @ br-removed @ ;
create items-prefix 9 cells allot
variable bi-table variable bi-depth
variable bi-n variable bi-d
: branching-items-rec ( node depth -- )
  bi-d ! bi-n !
  bi-d @ 1 = if
    bi-n @ 2 cells + @ 0 ?do
      bi-n @ i bnode-pair @ items-prefix bi-depth @ 1- cells + !
      bi-table @ items-prefix bi-n @ i bnode-pair dup cell+ @ swap 2 cells + @ table-push
    loop
  else
    bi-n @ 2 cells + @ 0 ?do
      bi-n @ i bnode-pair @ items-prefix bi-depth @ bi-d @ - cells + !
      bi-n @ i bnode-pair cell+ @ ( child )
      bi-n @ >r bi-d @ >r
      bi-d @ 1- recurse
      r> bi-d ! r> bi-n !
    loop
  then ;
: branching-items ( bm -- table )
  2048 table-new bi-table !
  dup @ bi-depth !
  cell+ @ bi-depth @ branching-items-rec
  bi-table @ dup table-sort ;
\ TransitivePhext: a branching map at depth 9 + global text arena
16777216 make-arena constant text-arena
: transitive-new ( -- tp ) 9 branching-new ;
: transitive-insert ( tp coord a u -- )
  dup >r text-arena arena-append r> ( tp coord a' u )
  branching-put 2drop ;
variable tl-t variable tl-p
: transitive-load ( buf u -- tp )
  transitive-new tl-p !
  16777216 make-arena explode tl-t !
  tl-t @ table-count 0 ?do
    tl-p @ tl-t @ i table-coord tl-t @ i table-text tl-t @ i table-textlen transitive-insert
  loop tl-p @ ;
: transitive-fetch ( tp coord -- a u ) branching-fetch ;
: transitive-length ( tp -- n ) 2 cells + @ ;
: transitive-serialize ( tp outarena -- a u )
  swap branching-items swap dephokenize-table ;
: transitive-remove ( tp coord -- ) branching-remove 2drop ;
variable tu-t variable tu-c variable tu-a variable tu-u variable tu-o
: transitive-update ( tp coord a u overwrite -- )
  tu-o ! tu-u ! tu-a ! tu-c ! tu-t !
  tu-u @ 0= if
    tu-o @ if tu-t @ tu-c @ transitive-remove then
  else tu-o @ if tu-t @ tu-c @ tu-a @ tu-u @ transitive-insert
  else
    tu-t @ tu-c @ transitive-fetch tu-a @ tu-u @ text-arena arena-cat ( a u )
    tu-t @ tu-c @ 2swap transitive-insert
  then then ;
: transitive-replace ( tp coord a u -- ) -1 transitive-update ;
