NB. telephone.ijs -- Exocortical Stress Testing adapter CLI (contract
NB. v2) for the J port of libphext. One JSON object in, one JSON object
NB. out (cmd-dispatch wire protocol, mirroring the reference ports);
NB. serve mode loops on stdin. State travels base64-encoded; serve
NB. responses over 8 KB are GZ1-framed. PGP via subprocess gpg.

IMPL =: 'j'
KEY_UID =: 'libphext telephone j'
INDEX_CS =: '1.1.1/1.1.1/1.1.1'
KEYS_CS =: '1.1.1/1.1.1/1.1.2'
KH_CS =: '1.1.1/1.1.1/1.1.3'
INDEX_V =: 9 # 1
KEYS_V =: 1 1 1 1 1 1 1 1 2
KH_V =: 1 1 1 1 1 1 1 1 3
LF =: 10 { a.

NB. ---- small helpers ----
trimNL =: {{
  nn =. +/ *./\ |. (a. i. y) e. 10 13
  (-nn) }. y
}}
trimTrailLF =: {{
  nn =. +/ *./\ |. (a. i. y) = 10
  (-nn) }. y
}}
trimBoth =: {{
  if. 0 = #y do. '' return. end.
  ws =. (a. i. y) e. 32 9 10 13
  lead =. ws i. 0
  if. lead = #y do. '' return. end.
  trail =. (|. ws) i. 0
  (-trail) }. lead }. y
}}
stripSpaces =: {{
  if. 0 = #y do. '' return. end.
  ws =. (a. i. y) = 32
  lead =. ws i. 0
  if. lead = #y do. '' return. end.
  trail =. (|. ws) i. 0
  (-trail) }. lead }. y
}}
shOut =: {{ trimNL 2!:0 y }}
shRC =: {{
  out =. 2!:0 y , '; echo __RC__$?'
  starts =. I. '__RC__' E. out
  if. 0 = #starts do. _1 return. end.
  rest =. ({: starts + 5) }. out
  digits =. rest #~ rest e. '0123456789'
  ". digits
}}
shq =: {{ '''' , y , '''' }}
readFile =: {{
  r =. ''
  try. r =. 1!:1 <y catch. r =. '' end.
  r
}}
writeFile =: {{
  x 1!:2 <y
  1
}}
rmFile =: {{ shOut 'rm -f ' , shq y }}
firstWord =: {{
  sp =. y i. ' '
  sp {. y
}}

NB. ---- temp files + shell crypto ----
TCTR =: 0
tmpPath =: {{
  TCTR =: TCTR + 1
  TMPBASE , (": TCTR) , y
}}
sha256File =: {{
  firstWord shOut 'sha256sum ' , shq y
}}
sha256Text =: {{
  p =. tmpPath '.bin'
  y writeFile p
  r =. sha256File p
  rmFile p
  r
}}
b64EncFile =: {{
  shOut 'base64 -w0 ' , shq y
}}
b64EncText =: {{
  p =. tmpPath '.bin'
  y writeFile p
  r =. b64EncFile p
  rmFile p
  r
}}
NB. x = base64 text, y = out path.
b64DecToFile =: {{
  p =. tmpPath '.b64'
  x writeFile p
  shRC ('base64 -d ' , (shq p) , ' > ' , (shq y) , ' 2>/dev/null')
  rmFile p
  1
}}
b64DecText =: {{
  p =. tmpPath '.out'
  y b64DecToFile p
  r =. readFile p
  rmFile p
  r
}}
hexBytes =: {{
  pairs =. _2 [\ y
  +/"1 (hexVal"1 pairs) *"1 (16 1)
}}

NB. ---- gpg ----
gpgBase =: {{
  'GNUPGHOME=' , (shq GHOME) , ' gpg --batch --yes --pinentry-mode loopback --passphrase ' , (shq '') , ' '
}}
ensureGpg =: {{
  if. GPREADY = 0 do.
    shOut 'mkdir -p ' , shq GHOME
    shOut 'chmod 700 ' , shq GHOME
    GPREADY =: 1
  end.
  1
}}
doKeygen =: {{
  ensureGpg ''
  listing =. shOut (gpgBase '') , '--list-keys --with-colons 2>/dev/null || true'
  if. 0 = # I. 'pub:' E. listing do.
    shRC (gpgBase '') , '--quick-generate-key ' , (shq KEY_UID) , ' ed25519 sign never'
  end.
  pub =. shOut (gpgBase '') , '--armor --export ' , shq KEY_UID
  pub =. pub , LF
  mkObj ((<'impl') , (<jStr IMPL) , (<'pubkey') , (<jStr pub))
}}
detachSign =: {{
  ensureGpg ''
  dp =. tmpPath '.desc'
  sp =. tmpPath '.sig'
  y writeFile dp
  rc =. shRC (gpgBase '') , '--detach-sign --armor -u ' , (shq KEY_UID) , ' -o ' , (shq sp) , ' ' , shq dp
  r =. ''
  if. rc = 0 do. r =. readFile sp end.
  rmFile dp
  rmFile sp
  r
}}
NB. y = (pubkeys ; data ; signature); returns '' or an error string.
verifySignature =: {{
  'pubkeys data sig' =. y
  td =. tmpPath '.vfy'
  gd =. td , '/gnupg'
  shOut 'mkdir -p ' , shq gd
  shOut 'chmod 700 ' , shq gd
  pubkeys writeFile td , '/keys.asc'
  data writeFile td , '/data'
  sig writeFile td , '/sig.asc'
  base =. 'GNUPGHOME=' , (shq gd) , ' gpg --batch --yes '
  rc1 =. shRC base , '--import ' , shq td , '/keys.asc'
  rc2 =. _1
  if. rc1 = 0 do.
    rc2 =. shRC base , '--verify ' , (shq td , '/sig.asc') , ' ' , shq td , '/data'
  end.
  shOut 'rm -rf ' , shq td
  if. rc1 ~: 0 do. 'gpg import failed' return. end.
  if. rc2 ~: 0 do. 'gpg verify failed' return. end.
  ''
}}

NB. ---- game logic ----
echoValue =: {{
  ping =. y
  game =. ''
  round =. ''
  nonce =. ''
  if. ping jHas 'game' do. game =. jStrOf ping jGet 'game' end.
  if. ping jHas 'round' do.
    round =. jStrOf ping jGet 'round'
  elseif. ping jHas 'turn' do.
    round =. jStrOf ping jGet 'turn'
  end.
  if. ping jHas 'nonce' do. nonce =. jStrOf ping jGet 'nonce' end.
  sha256Text IMPL , '|' , game , '|' , round , '|' , nonce
}}
electWinner =: {{
  'position cands turn' =. y
  seed =. position , ((256 | turn) { a.) , (',' joinWith cands)
  hb =. hexBytes sha256Text seed
  > ((#cands) | {. hb) { cands
}}
wrap999 =: {{ 1 + 999 | (y - 1) }}
nextCoord =: {{
  c =. y
  d =. 8
  while. d >: 0 do.
    if. (d { c) < 999 do.
      (d { c) + 1) d } c return.
    end.
    c =. 1 d } c
    d =. d - 1
  end.
  c
}}
NB. Fetch text by coordinate string from a map; '' when absent.
fetchStr =: {{
  'CO TX' =. x
  cv =. parseCoord y
  if. 0 = #cv do. '' return. end.
  idx =. (cv -:"1 CO) i. 1
  if. idx < 0 { $ CO do. > idx { TX else. '' end.
}}
fetchVec =: {{
  'CO TX' =. x
  idx =. (y -:"1 CO) i. 1
  if. idx < 0 { $ CO do. > idx { TX else. '' end.
}}
chooseAdventure =: {{
  'state position turn' =. y
  mp =. explode state
  'CO TX' =. mp
  pv =. parseCoord position
  hb =. hexBytes sha256Text position , ((256 | turn) { a.) , state
  dim =. 9 | (1 { hb)
  bump =. 1 + 3 | (2 { hb)
  cand =. (wrap999 (dim { pv) + bump) dim } pv
  while. 1 do.
    idx =. (cand -:"1 CO) i. 1
    used =. idx < 0 { $ CO
    if. -. used do.
      used =. (cand -: INDEX_V) +. (cand -: KEYS_V) +. (cand -: KH_V)
    end.
    if. -. used do. break. end.
    cand =. nextCoord cand
  end.
  cs =. coordStr cand
  text =. IMPL , ' turn ' , (": turn) , ' at ' , cs
  mkObj ((<'coordinate') , (<jStr cs) , (<'op') , (<jStr 'insert') , (<'text') , (<jStr text))
}}
applyStep =: {{
  'state step' =. y
  op =. jStrOf step jGet 'op'
  cs =. jStrOf step jGet 'coordinate'
  text =. jStrOf step jGet 'text'
  cv =. parseCoord cs
  if. op -: 'fetch' do.
    fh =. sha256Text (explode state) fetchStr cs
    '{"fetch_sha256":' , (jQuoteSafe fh) , ',"state_b64":' , (jQuoteSafe b64EncText state) , ',"state_sha256":' , (jQuoteSafe sha256Text state) , '}'
    return.
  end.
  if. 0 = #cv do.
    '{"error":"bad coordinate"}' return.
  end.
  ow =. 0
  txt =. text
  if. op -: 'replace' do. ow =. 1 end.
  if. op -: 'remove' do. ow =. 1; txt =. '' end.
  if. -. op -: 'insert' do.
    if. -. ow do.
      '{"error":"unknown step op"}' return.
    end.
  end.
  newdata =. implode (explode state) mupdate (cv ; txt ; ow)
  '{"fetch_sha256":null,"state_b64":' , (jQuoteSafe b64EncText newdata) , ',"state_sha256":' , (jQuoteSafe sha256Text newdata) , '}'
}}
reqState =: {{
  if. y jHas 'state' do. b64DecText jStrOf y jGet 'state'
  elseif. y jHas 'state_b64' do. b64DecText jStrOf y jGet 'state_b64'
  else. '' end.
}}

NB. ---- cache: CHAS CCO CTX ----
initCache =: {{
  CHAS =: 0
  CCO =: 0 9 $ 0
  CTX =: EMPTYB
  1
}}

NB. ---- validate ----
vFail =: {{
  mkObj ((<'detail') , (<jStr y) , (<'impl') , (<jStr IMPL) , (<'verdict') , (<jStr 'fail'))
}}
doValidate =: {{
  req =. y
  step =. req jGet 'step'
  op =. jStrOf step jGet 'op'
  state =. reqState req
  if. req jHas 'prior_state' do.
    if. -. op -: 'insert' do. vFail 'step op is not insert' return. end.
    cs =. jStrOf step jGet 'coordinate'
    text =. jStrOf step jGet 'text'
    smp =. explode state
    if. -. (smp fetchStr cs) -: text do.
      vFail 'placed scroll absent or content differs at ' , cs return.
    end.
    prior =. b64DecText jStrOf req jGet 'prior_state'
    pmp =. explode prior
    if. -. (pmp fetchStr cs) -: '' do.
      vFail 'coordinate was not unused in the prior state' return.
    end.
    'PCO PTX' =. pmp
    'SCO STX' =. smp
    if. (0 { $ SCO) ~: (0 { $ PCO) + 1 do.
      vFail 'scroll count did not grow by exactly one' return.
    end.
    bad =. ''
    i =. 0
    while. i < 0 { $ SCO do.
      c =. i { SCO
      pidx =. (c -:"1 PCO) i. 1
      if. pidx < 0 { $ PCO do.
        if. -. (> pidx { PTX) -: > i { STX do.
          bad =. 'a prior scroll was overwritten: ' , coordStr c
          break.
        end.
      end.
      i =. i + 1
    end.
    if. #bad do. vFail bad return. end.
    mkObj ((<'detail') , (<jStr 'placed at unused coordinate; all prior scrolls intact') , (<'impl') , (<jStr IMPL) , (<'verdict') , (<jStr 'pass'))
    return.
  end.
  if. -. CHAS do. vFail 'validate called before init' return. end.
  smp =. explode state
  'SCO STX' =. smp
  cs =. jStrOf step jGet 'coordinate'
  ev =. jStrOf req jGet 'event_coord'
  index_line =. jStrOf req jGet 'index_line'
  text =. jStrOf step jGet 'text'
  if. -. (smp fetchStr cs) -: text do.
    vFail 'placed scroll missing or altered' return.
  end.
  bad =. ''
  i =. 0
  while. i < 0 { $ CCO do.
    c =. i { CCO
    if. -. c -: INDEX_V do.
      sidx =. (c -:"1 SCO) i. 1
      if. sidx >: 0 { $ SCO do.
        bad =. 'prior scroll overwritten at ' , coordStr c
        break.
      end.
      if. -. (> sidx { STX) -: > i { CTX do.
        bad =. 'prior scroll overwritten at ' , coordStr c
        break.
      end.
    end.
    i =. i + 1
  end.
  if. #bad do. vFail bad return. end.
  cv =. parseCoord cs
  evv =. parseCoord ev
  i =. 0
  while. i < 0 { $ SCO do.
    c =. i { SCO
    cidx =. (c -:"1 CCO) i. 1
    if. cidx >: 0 { $ CCO do.
      if. -. (c -: cv) +. c -: evv do.
        bad =. 'unexpected new scroll at ' , coordStr c
        break.
      end.
    end.
    i =. i + 1
  end.
  if. #bad do. vFail bad return. end.
  idxtext =. smp fetchVec INDEX_V
  a =. trimTrailLF idxtext
  b =. trimTrailLF index_line
  oki =. ((#b) <: (#a)) *. b -: (- (#b)) {. a
  if. -. oki do. vFail 'index does not record the placement' return. end.
  CCO =: SCO
  CTX =: STX
  CHAS =: 1
  mkObj ((<'impl') , (<jStr IMPL) , (<'verdict') , (<jStr 'pass'))
}}

NB. ---- verify ----
verifyFail =: {{
  'nn msg' =. y
  ff =. mkObj ((<'detail') , (<jStr msg))
  mkObj ((<'first_failure') , (<ff) , (<'impl') , (<jStr IMPL) , (<'placements_checked') , (<jNum ": nn) , (<'verdict') , (<jStr 'fail'))
}}
doVerify =: {{
  'state pubkeys' =. y
  mp =. explode state
  'CO TX' =. mp
  keys_text =. mp fetchVec KEYS_V
  if. 0 = #keys_text do.
    verifyFail (0 ; 'no public-keys scroll at 1.1.1/1.1.1/1.1.2') return.
  end.
  if. -. (trimBoth pubkeys) -: trimBoth keys_text do.
    verifyFail (0 ; 'supplied pubkeys do not match the inscribed keys scroll') return.
  end.
  kh =. mp fetchVec KH_V
  khidx =. (KH_V -:"1 CO) i. 1
  if. khidx >: 0 { $ CO do.
    verifyFail (0 ; 'no keys-hash scroll at 1.1.1/1.1.1/1.1.3') return.
  end.
  if. -. (stripSpaces kh) -: sha256Text keys_text do.
    verifyFail (0 ; 'keys-hash scroll does not match the keys scroll') return.
  end.
  idxtext =. mp fetchVec INDEX_V
  ilines =. linesOf idxtext
  icss =. EMPTYB
  ilineof =. EMPTYB
  bad =. ''
  li =. 0
  while. li < #ilines do.
    ln =. stripSpaces > li { ilines
    if. (#ln) *. -. '#' -: 0 { ln do.
      f =. ' ' splitStr ln
      if. (#f) ~: 4 do.
        bad =. 'malformed index line: ' , ln
        break.
      end.
      icss =. icss , < > 1 { f
      ilineof =. ilineof , <ln
    end.
    li =. li + 1
  end.
  if. #bad do. verifyFail (0 ; bad) return. end.
  checked =. 0
  seen =. EMPTYB
  prev_hash =. ''
  seq =. 0
  while. 1 do.
    seq =. seq + 1
    evv =. 1 1 1 1 1 1 2 1 , seq
    eidx =. (evv -:"1 CO) i. 1
    if. eidx >: 0 { $ CO do. break. end.
    evtext =. > eidx { TX
    ev =. jParse evtext
    if. JERR do.
      verifyFail (checked ; 'event ' , (": seq) , ' is not JSON') return.
    end.
    if. -. ev jHas 'body' do.
      verifyFail (checked ; 'event ' , (": seq) , ' lacks a body object') return.
    end.
    body =. ev jGet 'body'
    pv =. ev jGet 'prev'
    if. seq = 1 do.
      if. -. jIsNull pv do.
        verifyFail (checked ; 'event 1 prev is not null') return.
      end.
    else.
      if. -. (jStrOf pv) -: prev_hash do.
        verifyFail (checked ; 'event chain broken at seq ' , ": seq) return.
      end.
    end.
    prev_hash =. sha256Text jCanon body
    if. -. (body jHas 'type') *. (jStrOf body jGet 'type') -: 'placement' do.
      continue.
    end.
    miss =. ''
    for_f =. 'coord' ; 'text_sha256' ; 'file_sha256' ; 'att'
    fi =. 0
    while. fi < #for_f do.
      if. -. body jHas > fi { for_f do.
        miss =. > fi { for_f
        break.
      end.
      fi =. fi + 1
    end.
    if. #miss do.
      verifyFail (checked ; 'event ' , (": seq) , ' lacks ' , miss) return.
    end.
    cs =. jStrOf body jGet 'coord'
    text_hash =. jStrOf body jGet 'text_sha256'
    file_hash =. jStrOf body jGet 'file_sha256'
    att_b64 =. jStrOf body jGet 'att'
    turn_raw =. jNumRaw body jGet 'turn'
    actor =. jStrOf body jGet 'actor'
    if. (seen i. <cs) < #seen do.
      verifyFail (checked ; 'coordinate reused at ' , cs) return.
    end.
    ptxt =. mp fetchStr cs
    pcoord =. parseCoord cs
    pfound =. (pcoord -:"1 CO) i. 1
    if. pfound >: 0 { $ CO do.
      verifyFail (checked ; 'placement missing at ' , cs) return.
    end.
    if. -. (sha256Text ptxt) -: text_hash do.
      verifyFail (checked ; 'placement hash mismatch at ' , cs) return.
    end.
    ipos =. icss i. <cs
    if. ipos >: #icss do.
      verifyFail (checked ; 'index mismatch at ' , cs) return.
    end.
    il =. > ipos { ilineof
    ilf =. ' ' splitStr il
    if. ((-. (> 2 { ilf) -: text_hash) +. (-. (> 0 { ilf) -: turn_raw) +. (-. (> 3 { ilf) -: actor)) do.
      verifyFail (checked ; 'index mismatch at ' , cs) return.
    end.
    desc =. '{"coordinate":' , (jQuote cs) , ',"file_sha256":' , (jQuote file_hash) , ',"scroll_sha256":' , (jQuote text_hash) , ',"turn":' , turn_raw , '}'
    err =. verifySignature (pubkeys ; desc ; b64DecText att_b64)
    if. #err do.
      verifyFail (checked ; 'event ' , (": seq) , ' signature: ' , err) return.
    end.
    seen =. seen , <cs
    checked =. checked + 1
  end.
  if. checked = 0 do.
    verifyFail (0 ; 'no placement events found') return.
  end.
  li =. 0
  while. li < #icss do.
    if. (seen i. < (> li { icss)) >: #seen do.
      verifyFail (checked ; 'index lists a placement with no event: ' , > li { icss) return.
    end.
    li =. li + 1
  end.
  mkObj ((<'first_failure') , (<jNull) , (<'impl') , (<jStr IMPL) , (<'placements_checked') , (<jNum ": checked) , (<'verdict') , (<jStr 'pass'))
}}

NB. ---- dispatch + wire framing ----
handleLine =: {{
  line =. y
  if. 'GZ1:' -: 4 {. line do.
    gp =. tmpPath '.gz'
    op2 =. tmpPath '.raw'
    (4 }. line) b64DecToFile gp
    shRC ('gzip -dc ' , (shq gp) , ' > ' , shq op2)
    line =. readFile op2
    rmFile gp
    rmFile op2
  end.
  req =. jParse line
  if. JERR do. '{"error":"parse error"}' return. end.
  if. -. req jHas 'cmd' do. '{"error":"no cmd"}' return. end.
  cmd =. jStrOf req jGet 'cmd'
  if. cmd -: 'id' do.
    mkObj ((<'impl') , (<jStr IMPL)) return.
  end.
  if. cmd -: 'echo' do.
    ev =. echoValue req jGet 'ping'
    mkObj ((<'echo') , (<jStr ev) , (<'impl') , (<jStr IMPL)) return.
  end.
  if. cmd -: 'elect' do.
    pos =. jStrOf req jGet 'position'
    turn =. jNumVal req jGet 'turn'
    cd =. jArrVal req jGet 'candidates'
    cands =. jStrOf each cd
    w =. electWinner ((<pos) , (<cands) , <turn)
    mkObj ((<'elect') , (<jStr w)) return.
  end.
  if. cmd -: 'choose' do.
    state =. reqState req
    pos =. jStrOf req jGet 'position'
    turn =. jNumVal req jGet 'turn'
    chooseAdventure (state ; pos ; turn) return.
  end.
  if. cmd -: 'apply' do.
    state =. reqState req
    applyStep ((<state) , <(req jGet 'step')) return.
  end.
  if. cmd -: 'keygen' do. doKeygen '' return. end.
  if. cmd -: 'attest' do.
    sig =. detachSign jCanon req jGet 'descriptor'
    mkObj ((<'signature') , (<jStr sig)) return.
  end.
  if. cmd -: 'init' do.
    state =. reqState req
    'CCO CTX' =: explode state
    CHAS =: 1
    mkObj ((<'impl') , (<jStr IMPL) , (<'verdict') , (<jStr 'pass')) return.
  end.
  if. cmd -: 'validate' do. doValidate req return. end.
  if. cmd -: 'verify' do.
    state =. reqState req
    doVerify (state ; jStrOf req jGet 'pubkeys') return.
  end.
  '{"error":' , (jQuote 'unknown cmd ' , cmd) , '}'
}}
render =: {{
  if. (3!:0 y) = 32 do. jCanon y else. y end.
}}
emitLine =: {{
  resp =. y
  if. SERVING *. (#resp) > 8192 do.
    rp =. tmpPath '.resp'
    gp =. tmpPath '.rgz'
    resp writeFile rp
    shRC ('gzip -c ' , (shq rp) , ' > ' , shq gp)
    r =. 'GZ1:' , b64EncFile gp
    rmFile rp
    rmFile gp
    (r , LF) writeFile '/dev/stdout'
  else.
    (resp , LF) writeFile '/dev/stdout'
  end.
  1
}}

NB. ---- serve loop: chunked stdin via dd on the shared stdin ----
NB. (This J build's memory foreigns 15!:6/15!:7 are unusable, so the
NB. serve reader shells out to dd, which inherits this process's
NB. stdin; 2!:0 returns the chunk byte-exactly.)
readChunk =: {{
  d =. 2!:0 'dd bs=262144 count=1 2>/dev/null'
  if. #d do.
    INBUF =: INBUF , d
  end.
  #d
}}
readLine =: {{
  while. 1 do.
    if. INPOS > 65536 do.
      INBUF =: INPOS }. INBUF
      INPOS =: 0
    end.
    seg =. INPOS }. INBUF
    k =. seg i. LF
    if. k < #seg do.
      INPOS =: INPOS + k + 1
      LINEOF =: 0
      k {. seg return.
    end.
    if. INEOF do.
      if. INPOS < #INBUF do.
        LINEOF =: 0
        r =. INPOS }. INBUF
        INPOS =: #INBUF
        r return.
      end.
      LINEOF =: 1
      '' return.
    end.
    nn =. readChunk ''
    if. nn <: 0 do. INEOF =: 1 end.
  end.
}}
serveLoop =: {{
  while. 1 do.
    line =. readLine ''
    if. LINEOF do. return. end.
    line =. trimNL line
    if. #line do.
      emitLine render handleLine line
    end.
  end.
}}

NB. ---- main ----
setup =: {{
  GPREADY =: 0
  SERVING =: 0
  GHOME =: ''
  env =. shOut 'printenv TELEPHONE_GNUPGHOME || true'
  if. #env do.
    GHOME =: env
  else.
    home =. shOut 'printenv HOME || true'
    GHOME =: home , '/telephone-j/gnupg'
  end.
  TMPBASE =: '/tmp/telephone-j-' , (": <. 6!:1 '') , '-'
  INBUF =: ''
  INPOS =: 0
  INEOF =: 0
  LINEOF =: 0
  initCache ''
  1
}}
main =: {{
  setup ''
  args =. 2 }. ARGV
  if. (< 'serve') e. args do.
    SERVING =: 1
    serveLoop ''
  else.
    data =. readFile '/dev/stdin'
    lines =. linesOf data
    i =. 0
    while. i < #lines do.
      ln =. trimNL > i { lines
      if. #ln do.
        ((render handleLine ln) , LF) writeFile '/dev/stdout'
      end.
      i =. i + 1
    end.
  end.
  2!:55 ''
}}
main ''
