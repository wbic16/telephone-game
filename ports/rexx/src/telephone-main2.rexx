/* telephone-main2.rexx -- validate/verify part of the REXX telephone
   CLI (concatenated after telephone-main.rexx). */
VFail: procedure expose IMPL
  parse arg detail
  return '{"detail":' || JQuote(detail) || ',"impl":' || JQuote(IMPL) || ',"verdict":"fail"}'

DoValidate: procedure expose IMPL INDEX_CS CACHE_SET CACHE_N CACHE_C. CACHE_T. M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC. JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN TMPDIR
  parse arg req
  step = JGet(req, 'step')
  op = JStr(JGet(step, 'op'))
  state = ReqState(req)
  if JHas(req, 'prior_state') then do
    if op <> 'insert' then return VFail('step op is not insert')
    cs = JStr(JGet(step, 'coordinate'))
    text = JStr(JGet(step, 'text'))
    if BufFetch(state, cs) \== text then return VFail('placed scroll absent or content differs at ' || cs)
    prior = B64Dec(JStr(JGet(req, 'prior_state')))
    if BufFetch(prior, cs) \== '' then return VFail('coordinate was not unused in the prior state')
    call Explode prior
    bn = M_N
    bc. = 0; bt. = ''
    do k = 1 to M_N; c = M_C.k; bc.c = 1; bt.c = M_T.k; end
    call Explode state
    if M_N <> bn + 1 then return VFail('scroll count did not grow by exactly one')
    do k = 1 to M_N
      c = M_C.k
      if bc.c then if bt.c <> M_T.k then return VFail('a prior scroll was overwritten: ' || c)
    end
    return '{"detail":"placed at unused coordinate; all prior scrolls intact","impl":' || JQuote(IMPL) || ',"verdict":"pass"}'
  end
  /* driver form: cached prior map + event_coord + index_line */
  if \CACHE_SET then return VFail('validate called before init')
  call Explode state
  nn = M_N
  nc. = 0; nt. = ''
  do k = 1 to M_N; c = M_C.k; nc.c = 1; nt.c = M_T.k; end
  cs = JStr(JGet(step, 'coordinate'))
  ev = JStr(JGet(req, 'event_coord'))
  index_line = JStr(JGet(req, 'index_line'))
  text = JStr(JGet(step, 'text'))
  if \nc.cs | nt.cs \== text then return VFail('placed scroll missing or altered')
  do k = 1 to CACHE_N
    c = CACHE_C.k
    if c = INDEX_CS then iterate
    if \nc.c | nt.c \== CACHE_T.k then return VFail('prior scroll overwritten at ' || c)
  end
  do k = 1 to nn
    c = M_C.k
    found = 0
    do j = 1 to CACHE_N
      if CACHE_C.j = c then do; found = 1; leave; end
    end
    if \found & c <> cs & c <> ev then return VFail('unexpected new scroll at ' || c)
  end
  idx = ''
  if nc.INDEX_CS then idx = nt.INDEX_CS
  if right(strip(idx, 'T', '0A'x), length(strip(index_line, 'T', '0A'x))) <> strip(index_line, 'T', '0A'x) then return VFail('index does not record the placement')
  CACHE_N = nn
  do k = 1 to nn; CACHE_C.k = M_C.k; CACHE_T.k = M_T.k; end
  return '{"impl":' || JQuote(IMPL) || ',"verdict":"pass"}'

VerifyFail: procedure expose IMPL
  parse arg n, msg
  return '{"first_failure":{"detail":' || JQuote(msg) || '},"impl":' || JQuote(IMPL) || ',"placements_checked":' || n || ',"verdict":"fail"}'

DoVerify: procedure expose IMPL INDEX_CS KEYS_CS KH_CS M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC. JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN TMPDIR
  parse arg state, pubkeys
  call Explode state
  sm. = 0; st. = ''
  do k = 1 to M_N; c = M_C.k; sm.c = 1; st.c = M_T.k; end
  if \sm.KEYS_CS | st.KEYS_CS = '' then return VerifyFail(0, 'no public-keys scroll at 1.1.1/1.1.1/1.1.2')
  keys_text = st.KEYS_CS
  if TrimBoth(pubkeys) <> TrimBoth(keys_text) then return VerifyFail(0, 'supplied pubkeys do not match the inscribed keys scroll')
  if \sm.KH_CS then return VerifyFail(0, 'no keys-hash scroll at 1.1.1/1.1.1/1.1.3')
  if strip(st.KH_CS) <> Sha256Hex(keys_text) then return VerifyFail(0, 'keys-hash scroll does not match the keys scroll')
  /* index: coord -> line fields */
  idx. = 0; idxline. = ''
  if sm.INDEX_CS then do
    rest = st.INDEX_CS
    do while rest <> ''
      parse var rest line '0A'x rest
      line = strip(line)
      if line = '' | left(line, 1) = '#' then iterate
      if words(line) <> 4 then return VerifyFail(0, 'malformed index line: ' || line)
      c = word(line, 2); idx.c = 1; idxline.c = line
    end
  end
  checked = 0
  seen. = 0
  prev_hash = ''
  seq = 0
  do forever
    seq = seq + 1
    ev_cs = '1.1.1/1.1.1/2.1.' || seq
    if \sm.ev_cs then leave
    ev = JParse(st.ev_cs)
    if ev = 0 then return VerifyFail(checked, 'event ' || seq || ' is not JSON')
    bodyn = JGet(ev, 'body')
    if bodyn = 0 then return VerifyFail(checked, 'event ' || seq || ' lacks a body object')
    prevn = JGet(ev, 'prev')
    if seq = 1 then do
      if JT.prevn <> 'null' then return VerifyFail(checked, 'event 1 prev is not null')
    end
    else do
      if JT.prevn <> 'str' | JStr(prevn) <> prev_hash then return VerifyFail(checked, 'event chain broken at seq ' || seq)
    end
    prev_hash = Sha256Hex(JCanon(bodyn))
    if \JHas(bodyn, 'type') | JStr(JGet(bodyn, 'type')) <> 'placement' then iterate
    flist = 'coord text_sha256 file_sha256 att'
    do fi = 1 to words(flist)
      f = word(flist, fi)
      if \JHas(bodyn, f) then return VerifyFail(checked, 'event ' || seq || ' lacks ' || f)
    end
    cs = JStr(JGet(bodyn, 'coord'))
    text_hash = JStr(JGet(bodyn, 'text_sha256'))
    file_hash = JStr(JGet(bodyn, 'file_sha256'))
    att_b64 = JStr(JGet(bodyn, 'att'))
    turn_raw = JNum(JGet(bodyn, 'turn'))
    actor = JStr(JGet(bodyn, 'actor'))
    if seen.cs then return VerifyFail(checked, 'coordinate reused at ' || cs)
    if \sm.cs then return VerifyFail(checked, 'placement missing at ' || cs)
    if Sha256Hex(st.cs) <> text_hash then return VerifyFail(checked, 'placement hash mismatch at ' || cs)
    if \idx.cs then return VerifyFail(checked, 'index mismatch at ' || cs)
    il = idxline.cs
    if word(il, 3) <> text_hash | word(il, 1) <> turn_raw | word(il, 4) <> actor then return VerifyFail(checked, 'index mismatch at ' || cs)
    desc = '{"coordinate":' || JQuote(cs) || ',"file_sha256":' || JQuote(file_hash) || ',"scroll_sha256":' || JQuote(text_hash) || ',"turn":' || turn_raw || '}'
    err = VerifySignature(pubkeys, desc, B64Dec(att_b64))
    if err <> '' then return VerifyFail(checked, 'event ' || seq || ' signature: ' || err)
    seen.cs = 1
    checked = checked + 1
  end
  if checked = 0 then return VerifyFail(0, 'no placement events found')
  /* every index coord must have an event (walk index stems) */
  if sm.INDEX_CS then do
    rest = st.INDEX_CS
    do while rest <> ''
      parse var rest line '0A'x rest
      line = strip(line)
      if line = '' | left(line, 1) = '#' then iterate
      c = word(line, 2)
      if \seen.c then return VerifyFail(checked, 'index lists a placement with no event: ' || c)
    end
  end
  return '{"first_failure":null,"impl":' || JQuote(IMPL) || ',"placements_checked":' || checked || ',"verdict":"pass"}'

TrimBoth: procedure
  parse arg s
  do 2
    s = strip(s, 'B', ' ')
    s = strip(s, 'B', '09'x)
    s = strip(s, 'B', '0D'x)
    s = strip(s, 'B', '0A'x)
  end
  return s
