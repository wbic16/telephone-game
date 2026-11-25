NB. test_phext.ijs -- suite for the J port: unit semantics, buffer /
NB. dynamic / transitive equivalence, fixture round-trips (16/16).
NB. build.sh prepends phext.ijs and json.ijs. Arg: fixtures list file.

FAILS =: 0
chk =: {{
  if. y do.
    echo 'ok - ' , x
  else.
    FAILS =: FAILS + 1
    echo 'FAIL - ' , x
  end.
  1
}}

runTests =: {{
  NB. breaks and coordinates
  'breaks: 9 dimension breaks' chk (#BRKCH) = 9
  'coord: origin parses to all ones' chk (parseCoord '1.1.1/1.1.1/1.1.1') -: 9 # 1
  'coord: format round trip' chk (coordStr parseCoord '2.3.4/5.6.7/8.9.10') -: '2.3.4/5.6.7/8.9.10'
  'coord: partial fills ones' chk (coordStr parseCoord '3') -: '3.1.1/1.1.1/1.1.1'
  'coord: invalid rejected' chk 0 = #parseCoord '1.2.3.4'
  'coord: bad char rejected' chk 0 = #parseCoord 'a.b.c'
  b1 =. bufInsert ('' ; (parseCoord '2.1.1/1.1.1/1.1.1') ; 'x')
  'breaks: library break byte' chk b1 -: (1 { a.) , 'x'
  b2 =. bufInsert ('' ; (parseCoord '1.1.1/1.1.1/1.1.2') ; 'y')
  'breaks: scroll break byte' chk b2 -: (23 { a.) , 'y'

  NB. buffer semantics
  d =. ''
  d =. bufInsert (d ; (parseCoord '1.1.1/1.1.1/1.1.1') ; 'Hello')
  d =. bufInsert (d ; (parseCoord '1.1.1/1.1.1/1.1.2') ; 'World')
  'insert: fetch first' chk (d bufFetch parseCoord '1.1.1/1.1.1/1.1.1') -: 'Hello'
  'insert: fetch second' chk (d bufFetch parseCoord '1.1.1/1.1.1/1.1.2') -: 'World'
  'fetch: missing is empty' chk (d bufFetch parseCoord '9.9.9/9.9.9/9.9.9') -: ''
  d =. bufInsert (d ; (parseCoord '1.1.1/1.1.1/1.1.1') ; '!')
  'insert: concatenates' chk (d bufFetch parseCoord '1.1.1/1.1.1/1.1.1') -: 'Hello!'
  d =. bufReplace (d ; (parseCoord '1.1.1/1.1.1/1.1.1') ; 'Replaced')
  'replace: overwrites' chk (d bufFetch parseCoord '1.1.1/1.1.1/1.1.1') -: 'Replaced'
  before =. d
  d =. bufRemove (d ; (parseCoord '1.1.1/1.1.1/1.1.1'))
  'remove: scroll gone' chk (d bufFetch parseCoord '1.1.1/1.1.1/1.1.1') -: ''
  'remove: coordinate-preserving' chk d -: bufRemove (before ; (parseCoord '1.1.1/1.1.1/1.1.1'))
  'remove: sibling intact' chk (d bufFetch parseCoord '1.1.1/1.1.1/1.1.2') -: 'World'
  d2 =. bufRemove (d ; (parseCoord '1.1.1/1.1.1/1.1.2'))
  'remove: last scroll empties buffer' chk d2 -: ''
  messy =. 'a' , (23 { a.) , (23 { a.) , 'b'
  'normalize: empty scrolls keep coordinates' chk (bufNormalize messy) -: messy
  'normalize: idempotent' chk (bufNormalize bufNormalize messy) -: bufNormalize messy

  NB. store equivalence over a scripted op sequence
  ops =. ''
  ops =. ops , < ((parseCoord '1.1.1/1.1.1/1.1.1') ; 'alpha' ; 0)
  ops =. ops , < ((parseCoord '1.1.1/1.1.1/1.1.2') ; 'beta' ; 0)
  ops =. ops , < ((parseCoord '2.1.1/1.1.1/1.1.1') ; 'gamma' ; 0)
  ops =. ops , < ((parseCoord '1.1.1/1.1.1/1.1.1') ; '-plus' ; 0)
  ops =. ops , < ((parseCoord '1.1.1/1.1.1/1.1.2') ; 'BETA' ; 1)
  ops =. ops , < ((parseCoord '1.2.3/4.5.6/7.8.9') ; 'deep' ; 0)
  ops =. ops , < ((parseCoord '2.1.1/1.1.1/1.1.1') ; '' ; 1)
  buf =. ''
  dyn =. dynNew
  trn =. trnNewNode
  i =. 0
  while. i < #ops do.
    'c t ow' =. > i { ops
    if. ow *. 0 = #t do.
      buf =. bufRemove (buf ; c)
    elseif. ow do.
      buf =. bufReplace (buf ; c ; t)
    else.
      buf =. bufInsert (buf ; c ; t)
    end.
    dyn =. dyn dynUpdate (c ; t ; ow)
    trn =. trn trnUpdate (c ; t ; ow)
    i =. i + 1
  end.
  'stores: dynamic serialize == buffer' chk (dynSerialize dyn) -: buf
  'stores: transitive serialize == buffer' chk (trnSerialize trn) -: buf
  'stores: dynamic len' chk (dynLen dyn) = 3
  'stores: transitive len' chk (trnLen trn) = 3
  'stores: transitive depth is 9' chk trnDepth = 9
  'stores: transitive fetch deep' chk (trn trnFetch parseCoord '1.2.3/4.5.6/7.8.9') -: 'deep'
  'stores: dynamic fetch replaced' chk (dyn dynFetch parseCoord '1.1.1/1.1.1/1.1.2') -: 'BETA'
  'stores: transitive fetch removed' chk (trn trnFetch parseCoord '2.1.1/1.1.1/1.1.1') -: ''

  NB. dynamic counters (CLRS discipline, mirrored from the C suite)
  d6 =. dynNew
  i =. 0
  while. i < 6 do.
    d6 =. d6 dynUpdate (((parseCoord '1.1.1/1.1.1/1.1.1') + 0 0 0 0 0 0 0 0 1 * i) ; ('v' , ": i) ; 0)
    i =. i + 1
  end.
  'dynamic: cap 8 after 6 inserts' chk (2 {:: d6) = 8
  'dynamic: 3 resizes after 6 inserts' chk (3 {:: d6) = 3
  'dynamic: 7 copied after 6 inserts' chk (4 {:: d6) = 7
  i =. 0
  while. i < 5 do.
    d6 =. d6 dynUpdate (((parseCoord '1.1.1/1.1.1/1.1.1') + 0 0 0 0 0 0 0 0 1 * i) ; '' ; 1)
    i =. i + 1
  end.
  'dynamic: len 1 after 5 removes' chk (dynLen d6) = 1
  'dynamic: cap 2 after shrinks' chk (2 {:: d6) = 2
  'dynamic: 5 resizes after shrinks' chk (3 {:: d6) = 5
  'dynamic: 10 copied after shrinks' chk (4 {:: d6) = 10

  NB. fixtures: byte-identical round-trips
  listpath =. > 2 { ARGV
  raw =. 1!:1 <listpath
  lines =. linesOf raw
  fi =. 0
  while. fi < #lines do.
    dir =. > fi { lines
    if. #dir do.
      orig =. 1!:1 < dir , '/input.phext'
      rt =. implode explode orig
      ('fixture ' , dir , ': round-trip') chk rt -: orig
    end.
    fi =. fi + 1
  end.

  if. FAILS = 0 do.
    echo 'RESULT: PASS'
  else.
    echo 'RESULT: FAIL (' , (": FAILS) , ')'
  end.
  2!:55 ''
}}
runTests ''
