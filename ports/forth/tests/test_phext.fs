\ Test suite for libphext-forth -- plain assertions, no framework.
\ Run: test_phext.fs [fixtures_dir]
include /home/wbic16/telephone-forth/port/src/phext.fs

variable checks variable failures
: ok ( flag addr u -- )
  1 checks +!
  rot if 2drop else 1 failures +! ." FAIL: " type cr then ;
: eq ( a b addr u -- ) >r >r = r> r> ok ;
: eqs ( a1 u1 a2 u2 addr u -- ) >r >r compare 0= r> r> ok ;
: s= ( a1 u1 a2 u2 -- flag ) compare 0= ;

16777216 make-arena constant ta
: app ( addr u -- ) ta arena-append drop ;
: appb ( byte -- ) ta arena-ptr c! 1 ta cell+ +! ;
: bstart ( -- addr ) ta arena-ptr ;
: bhere ( start -- addr u ) dup ta arena-ptr swap - ;
create cc 9 cells allot
: PCC ( addr u -- ) coord-parse cc 9 cells move ;
variable dyn variable trn variable strb variable strl
variable fx-files variable fx-ident variable fx-idem
variable fxd variable fxdl
create fxb 1024 allot
variable sl-f variable sl-u
: slurp-file ( path u -- addr u )
  r/o open-file throw sl-f !
  sl-f @ file-size throw drop sl-u !
  sl-u @ ta arena-alloc ( addr )
  dup sl-u @ sl-f @ read-file throw drop
  sl-u @
  sl-f @ close-file throw ;
variable cd- variable cdl variable cc- variable ccl
: fx-one ( path u -- )
  1 fx-files +!
  slurp-file ( addr u )
  2dup dephokenize 2over s= if 1 fx-ident +! then
  2dup normalize 2dup normalize s= if 1 fx-idem +! then
  2drop ;
: fx-case ( dir u case u -- )
  ccl ! cc- ! cdl ! cd- !
  cd- @ fxb cdl @ move
  [char] / fxb cdl @ + c!
  cc- @ fxb cdl @ + 1+ ccl @ move
  s" /input.phext" fxb cdl @ + 1+ ccl @ + swap move
  fxb cdl @ 1+ ccl @ + 12 + fx-one ;
: fixtures-run ( dir u -- )
  0 fx-files ! 0 fx-ident ! 0 fx-idem !
  2dup s" chains/adjacent-chain-closes" fx-case
  2dup s" chains/chain-of-one-empty-phext" fx-case
  2dup s" chains/empty-member" fx-case
  2dup s" chains/empty-stream" fx-case
  2dup s" chains/multi-member-3" fx-case
  2dup s" chains/multiple-chains" fx-case
  2dup s" chains/multiverse-addressing" fx-case
  2dup s" chains/real-corpora-chain" fx-case
  2dup s" chains/single-member" fx-case
  2dup s" chains/unclosed-at-eof" fx-case
  2dup s" ranges/offset-form" fx-case
  2dup s" ranges/point-basics" fx-case
  2dup s" ranges/range-cross-scroll" fx-case
  2dup s" ranges/range-multiverse" fx-case
  2dup s" ranges/range-unicode" fx-case
  2dup s" ranges/range-within-scroll" fx-case
  2drop
  ." fixtures: " fx-files @ . ." input.phext, " fx-ident @ .
  ." byte-identical round-trips, " fx-idem @ . ." normalize-idempotent" cr
  fx-files @ 16 s" 16 fixtures found" eq
  fx-ident @ fx-files @ s" fixtures byte-identical round-trips" eq
  fx-idem @ fx-files @ s" all fixtures normalize idempotently" eq ;
: run-tests
  0 checks ! 0 failures !
  \ --- coordinate
  s" 1.2.3/4.5.6/7.8.9" coord-parse coord>str
  s" 1.2.3/4.5.6/7.8.9" s" coord format" eqs
  s" 1.1.1/1.1.1/1.1.1" PCC cc s" 1.1.1/1.1.1/1.1.2" coord-parse
  cc swap coord-cmp 0< s" order scroll" ok
  s" 1.1.1/1.1.1/1.1.9" PCC cc s" 1.1.1/1.1.2/1.1.1" coord-parse
  cc swap coord-cmp 0< s" order section" ok
  s" 2.1.1/1.1.1/1.1.1" PCC cc s" 1.9.9/9.9.9/9.9.9" coord-parse
  cc swap coord-cmp 0> s" order library" ok
  \ --- phokenize / fetch
  bstart s" hello" app bhere ( buf u )
  2dup s" 1.1.1/1.1.1/1.1.1" PCC cc fetch s" hello" s" fetch root" eqs
  2dup s" 9.9.9/9.9.9/9.9.9" PCC cc fetch nip 0= s" far gap empty" ok
  2drop
  \ build one<23>two<23><23>four
  bstart s" one" app 23 appb s" two" app 23 appb 23 appb s" four" app bhere
  2dup s" 1.1.1/1.1.1/1.1.1" PCC cc fetch s" one" s" fetch 1" eqs
  2dup s" 1.1.1/1.1.1/1.1.4" PCC cc fetch s" four" s" fetch 4" eqs
  2dup s" 1.1.1/1.1.1/1.1.3" PCC cc fetch nip 0= s" gap fetch empty" ok
  \ round trip
  2dup normalize 2over compare 0= s" round trip sample" ok
  \ explode/implode
  2dup 1048576 make-arena explode dup table-count 3 = s" explode count" ok
  16777216 make-arena dephokenize-table 2over compare 0= s" implode round trip" ok
  2drop
  \ --- insert
  s" base" s" 1.1.1/1.1.1/1.1.1" PCC cc s" +more" insert ( buf u )
  2dup cc fetch s" base+more" s" insert appends after existing" eqs
  2drop
  bstart s" a" app 23 appb s" c" app bhere
  s" 1.1.1/1.1.1/1.1.2" PCC cc s" b" insert
  2dup cc fetch s" cb" s" insert merges existing + inserted" eqs
  2drop
  \ --- replace / remove (coordinate-preserving)
  bstart s" old" app 23 appb s" keep" app bhere
  s" 1.1.1/1.1.1/1.1.1" PCC cc s" new" replace
  bstart s" new" app 23 appb s" keep" app bhere compare 0= s" replace overwrites" ok
  bstart s" a" app 23 appb s" b" app 23 appb s" c" app bhere
  s" 1.1.1/1.1.1/1.1.2" PCC cc remove-scroll
  2dup cc fetch nip 0= s" removed coordinate reads empty" ok
  2dup s" 1.1.1/1.1.1/1.1.3" PCC cc fetch s" c" s" neighbour keeps coordinate" eqs
  bstart s" a" app 23 appb 23 appb s" c" app bhere compare 0= s" remove leaves a gap" ok
  \ --- Dynamic + Transitive equivalence over an op sequence
  4 dynamic-new dyn !
  transitive-new trn !
  0 strl ! pad strb !
  \ step 1: insert alpha at root
  s" 1.1.1/1.1.1/1.1.1" PCC cc
  strb @ strl @ cc s" alpha" insert strl ! strb !
  dyn @ cc s" alpha" dynamic-insert
  trn @ cc s" alpha" transitive-insert
  dyn @ 16777216 make-arena dynamic-serialize strb @ strl @ s= s" dynamic == string 1" ok
  trn @ 16777216 make-arena transitive-serialize strb @ strl @ s= s" transitive == string 1" ok
  \ step 2: insert gamma at scroll 3
  s" 1.1.1/1.1.1/1.1.3" PCC cc
  strb @ strl @ cc s" gamma" insert strl ! strb !
  dyn @ cc s" gamma" dynamic-insert
  trn @ cc s" gamma" transitive-insert
  dyn @ 16777216 make-arena dynamic-serialize strb @ strl @ s= s" dynamic == string 2" ok
  trn @ 16777216 make-arena transitive-serialize strb @ strl @ s= s" transitive == string 2" ok
  \ step 3: replace lib2 at 2.1.1/1.1.1/1.1.1
  s" 2.1.1/1.1.1/1.1.1" PCC cc
  strb @ strl @ cc s" lib2" replace strl ! strb !
  dyn @ cc s" lib2" dynamic-replace
  trn @ cc s" lib2" transitive-replace
  dyn @ 16777216 make-arena dynamic-serialize strb @ strl @ s= s" dynamic == string 3" ok
  trn @ 16777216 make-arena transitive-serialize strb @ strl @ s= s" transitive == string 3" ok
  \ step 4: remove scroll 3
  s" 1.1.1/1.1.1/1.1.3" PCC cc
  strb @ strl @ cc remove-scroll strl ! strb !
  dyn @ cc dynamic-remove
  trn @ cc transitive-remove
  dyn @ 16777216 make-arena dynamic-serialize strb @ strl @ s= s" dynamic == string 4" ok
  trn @ 16777216 make-arena transitive-serialize strb @ strl @ s= s" transitive == string 4" ok
  dyn @ cc dynamic-fetch nip 0= s" dynamic removed coord is gap" ok
  trn @ cc transitive-fetch nip 0= s" transitive removed coord is gap" ok
  s" 2.1.1/1.1.1/1.1.1" PCC cc
  dyn @ cc dynamic-fetch s" lib2" s" dynamic neighbour unmoved" eqs
  trn @ cc transitive-fetch s" lib2" s" transitive neighbour unmoved" eqs
  \ --- capacity discipline
  4 dynamic-new dyn !
  65 1 do
    9 0 do 1 cc i cells + ! loop i cc 8 cells + !
    dyn @ cc s" s" dynamic-append
  loop
  dyn @ dynamic-capacity 64 s" capacity doubles to fit 64" eq
  dyn @ dynamic-resize-count 7 <= s" resize count is logarithmic" ok
  \ --- fixtures (argv[1] = fixtures dir)
  next-arg dup 0> if
    fixtures-run
  else 2drop ." fixtures: skipped (no fixtures dir)" cr then
  ." forth suite: " checks @ . ." checks, " failures @ . ." failures" cr ;
run-tests
bye
