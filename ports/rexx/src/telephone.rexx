/* telephone-main.rexx -- Exocortical Telephone Game CLI (contract
   v2) for the REXX libphext port: main part, concatenated after
   phext.rexx and json.rexx. Wire: one JSON request in, one JSON
   response out; "serve" loops over lines. GZ1 framing for lines
   over 8 KB via the system gzip/base64 tools on temp files.
   sha256 via sha256sum(1), base64 via base64(1) (crypto utilities,
   not phext logic); PGP via subprocess gpg with key home
   ~/telephone-rexx/gnupg (TELEPHONE_GNUPGHOME overrides). All phext
   operations use this port's own phext.rexx. */
IMPL = 'rexx'
INDEX_CS = '1.1.1/1.1.1/1.1.1'
KEYS_CS = '1.1.1/1.1.1/1.1.2'
KH_CS = '1.1.1/1.1.1/1.1.3'
KEY_UID = 'libphext telephone rexx'
TMPDIR = '/tmp/telephone-rexx-' || random(1, 99999)
' mkdir -p ' TMPDIR ' >/dev/null 2>&1'
CACHE_SET = 0; CACHE_N = 0
SERVING = 0
call PhextInit

main:
  parse arg mode
  if mode = 'serve' then do
    SERVING = 1
    do forever
      line = linein()
      if line = '' then do
        if lines() = 0 then leave
        iterate
      end
      call EmitLine HandleLine(line)
    end
  end
  else do
    data = ''
    do while lines() > 0
      data = data || linein()
    end
    data = strip(data, 'T', '0A'x)
    data = strip(data, 'T', '0D'x)
    if data <> '' then call EmitLine HandleLine(data)
  end
  exit 0

HandleLine: procedure expose IMPL INDEX_CS KEYS_CS KH_CS KEY_UID TMPDIR CACHE_SET CACHE_N CACHE_C. CACHE_T. M_N M_C. M_T. BREAKS BDIM. JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN PSTR PPOS PLEN D_N D_C. D_T. D_CAP D_RESIZE D_COPIED TR. TR_N TR_C. BRK. P_N P. ALLB OUTB CD. PC.
  parse arg line
  if substr(line, 1, 4) = 'GZ1:' then line = GzUnframe(substr(line, 5))
  req = JParse(line)
  if req = 0 then return '{"error":"parse error"}'
  cmdnode = JGet(req, 'cmd')
  if cmdnode = 0 then return '{"error":"no cmd"}'
  cmd = JStr(cmdnode)
  select
    when cmd = 'id' then resp = '{"impl":' || JQuote(IMPL) || '}'
    when cmd = 'echo' then do
      ping = JGet(req, 'ping')
      resp = '{"echo":' || JQuote(EchoValue(ping)) || ',"impl":' || JQuote(IMPL) || '}'
    end
    when cmd = 'elect' then do
      pos = JStr(JGet(req, 'position'))
      turn = JNum(JGet(req, 'turn'))
      cands = JGet(req, 'candidates')
      n = JAC.cands
      list = ''
      do k = 1 to n
        item = JA.cands.k
        list = list JStr(item)
      end
      list = strip(list)
      resp = '{"elect":' || JQuote(ElectWinner(pos, list, turn)) || '}'
    end
    when cmd = 'choose' then do
      state = B64Dec(JStr(JGet(req, 'state')))
      pos = JStr(JGet(req, 'position'))
      turn = JNum(JGet(req, 'turn'))
      resp = ChooseAdventure(state, pos, turn)
    end
    when cmd = 'apply' then do
      state = ReqState(req)
      step = JGet(req, 'step')
      resp = ApplyStep(state, step)
    end
    when cmd = 'keygen' then resp = DoKeygen()
    when cmd = 'attest' then do
      desc = JGet(req, 'descriptor')
      sig = DetachSign(JCanon(desc))
      resp = '{"signature":' || JQuote(sig) || '}'
    end
    when cmd = 'init' then do
      state = ReqState(req)
      call Explode state
      CACHE_N = M_N
      do k = 1 to M_N; CACHE_C.k = M_C.k; CACHE_T.k = M_T.k; end
      CACHE_SET = 1
      resp = '{"impl":' || JQuote(IMPL) || ',"verdict":"pass"}'
    end
    when cmd = 'validate' then resp = DoValidate(req)
    when cmd = 'verify' then do
      state = ReqState(req)
      pubkeys = JStr(JGet(req, 'pubkeys'))
      resp = DoVerify(state, pubkeys)
    end
    otherwise resp = '{"error":' || JQuote('unknown cmd ' || cmd) || '}'
  end
  return resp

EmitLine: procedure expose TMPDIR SERVING
  parse arg out
  if SERVING & length(out) > 8192 then out = GzFrame(out)
  call lineout , out
  return

ReqState: procedure expose TMPDIR JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN
  parse arg req
  n = JGet(req, 'state')
  if n = 0 then n = JGet(req, 'state_b64')
  if n = 0 then return ''
  return B64Dec(JStr(n))

/* ---------- file / shell helpers ---------- */
TmpPath: procedure expose TMPDIR
  parse arg tag
  return TMPDIR || '/' || tag || '-' || random(1, 99999) || '-' || time('S')

WriteFile: procedure
  parse arg path, data
  call charout path, data, 1
  call stream path, 'C', 'CLOSE'
  return

ReadFile: procedure
  parse arg path
  n = stream(path, 'C', 'QUERY SIZE')
  if n = '' | n = 0 then do
    call stream path, 'C', 'CLOSE'
    return ''
  end
  d = charin(path, 1, n)
  call stream path, 'C', 'CLOSE'
  return d

ShellToFile: procedure
  parse arg cmd, outfile
  cmd || ' > ' || outfile || ' 2>/dev/null'
  return ReadFile(outfile)

Sha256Hex: procedure expose TMPDIR
  parse arg data
  f = TmpPath('sha'); o = f || '.out'
  call WriteFile f, data
  'sha256sum ' f ' > ' o ' 2>/dev/null'
  txt = ReadFile(o)
  'rm -f ' f o
  parse var txt hex .
  return hex

B64Enc: procedure expose TMPDIR
  parse arg data
  f = TmpPath('b64'); o = f || '.out'
  call WriteFile f, data
  'base64 -w0 ' f ' > ' o ' 2>/dev/null'
  txt = ReadFile(o)
  'rm -f ' f o
  return strip(txt, 'T', '0A'x)

B64Dec: procedure expose TMPDIR
  parse arg s
  f = TmpPath('b64d'); o = f || '.out'
  call WriteFile f, s
  'base64 -d ' f ' > ' o ' 2>/dev/null'
  d = ReadFile(o)
  'rm -f ' f o
  return d

GzUnframe: procedure expose TMPDIR
  parse arg b64
  f = TmpPath('gz'); o = f || '.out'
  call WriteFile f, b64
  'base64 -d ' f ' | gzip -dc > ' o ' 2>/dev/null'
  d = ReadFile(o)
  'rm -f ' f o
  return d

GzFrame: procedure expose TMPDIR
  parse arg data
  f = TmpPath('gzf'); o = f || '.out'
  call WriteFile f, data
  'gzip -c ' f ' | base64 -w0 > ' o ' 2>/dev/null'
  txt = ReadFile(o)
  'rm -f ' f o
  return 'GZ1:' || strip(txt, 'T', '0A'x)

/* ---------- gpg ---------- */
GpgHome: procedure
  h = value('TELEPHONE_GNUPGHOME',, 'ENVIRONMENT')
  if h <> '' then return h
  return value('HOME',, 'ENVIRONMENT') || '/telephone-rexx/gnupg'

Gpg: procedure expose TMPDIR
  parse arg args, infile
  home = GpgHome()
  'mkdir -p ' home ' >/dev/null 2>&1'
  'chmod 700 ' home ' >/dev/null 2>&1'
  o = TmpPath('gpg')
  if infile = '' then
    'GNUPGHOME='home' gpg --batch --yes --pinentry-mode loopback --passphrase "" ' args ' > ' o ' 2>/dev/null'
  else
    'GNUPGHOME='home' gpg --batch --yes --pinentry-mode loopback --passphrase "" ' args ' < ' infile ' > ' o ' 2>/dev/null'
  d = ReadFile(o)
  'rm -f ' o
  return d

DoKeygen: procedure expose KEY_UID IMPL TMPDIR
  listing = Gpg('--list-keys --with-colons', '')
  if pos('pub:', listing) = 0 then
    call Gpg '--quick-generate-key "'KEY_UID'" ed25519 sign never', ''
  pub = Gpg('--armor --export "'KEY_UID'"', '')
  if right(pub, 1) <> '0A'x then pub = pub || '0A'x
  return '{"impl":' || JQuote(IMPL) || ',"pubkey":' || JQuote(pub) || '}'

DetachSign: procedure expose KEY_UID TMPDIR
  parse arg data
  f = TmpPath('sign'); sig = f || '.asc'
  call WriteFile f, data
  home = GpgHome()
  'mkdir -p ' home ' >/dev/null 2>&1'
  'GNUPGHOME='home' gpg --batch --yes --pinentry-mode loopback --passphrase "" --detach-sign --armor -u "'KEY_UID'" --output ' sig ' ' f ' >/dev/null 2>&1'
  d = ReadFile(sig)
  'rm -f ' f sig
  return d

VerifySignature: procedure expose TMPDIR
  parse arg pubkeys, data, signature
  td = TmpPath('verify')
  'mkdir -p ' || td || '/gnupg >/dev/null 2>&1'
  'chmod 700 ' || td || '/gnupg >/dev/null 2>&1'
  call WriteFile td || '/keys.asc', pubkeys
  call WriteFile td || '/data', data
  call WriteFile td || '/sig.asc', signature
  'GNUPGHOME=' || td || '/gnupg gpg --batch --yes --import ' || td || '/keys.asc >/dev/null 2>&1'
  rc1 = RC
  'GNUPGHOME=' || td || '/gnupg gpg --batch --yes --verify ' || td || '/sig.asc ' || td || '/data >/dev/null 2>&1'
  rc2 = RC
  'rm -rf ' td
  if rc1 <> 0 then return 'gpg import failed'
  if rc2 <> 0 then return 'gpg verify failed'
  return ''

/* ---------- game logic (mirrors the reference ports) ---------- */
EchoValue: procedure expose IMPL TMPDIR JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN
  parse arg ping
  game = ''; round = ''; nonce = ''
  if JHas(ping, 'game') then game = JStr(JGet(ping, 'game'))
  if JHas(ping, 'round') then round = JStr(JGet(ping, 'round'))
  else if JHas(ping, 'turn') then round = JNum(JGet(ping, 'turn'))
  if JHas(ping, 'nonce') then nonce = JStr(JGet(ping, 'nonce'))
  return Sha256Hex(IMPL || '|' || game || '|' || round || '|' || nonce)

ElectWinner: procedure expose TMPDIR
  parse arg position, candidates, turn
  seed = position || d2c(turn // 256) || translate(candidates, ',', ' ')
  hex = Sha256Hex(seed)
  b0 = x2d(substr(hex, 1, 2))
  return word(candidates, (b0 // words(candidates)) + 1)

Wrap999: procedure
  parse arg v
  return ((v - 1) // 999) + 1

NextCoord: procedure
  parse arg cs
  w = translate(cs, ' ', '/.')
  do d = 9 to 1 by -1
    v = word(w, d)
    if v < 999 then return CoordJoin(SetWord(w, d, v + 1))
    w = SetWord(w, d, 1)
  end
  return CoordJoin(w)

CoordJoin: procedure
  parse arg w
  return word(w,1)'.'word(w,2)'.'word(w,3)'/'word(w,4)'.'word(w,5)'.'word(w,6)'/'word(w,7)'.'word(w,8)'.'word(w,9)

ChooseAdventure: procedure expose IMPL INDEX_CS KEYS_CS KH_CS M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC. TMPDIR
  parse arg state, position, turn
  call Explode state
  used. = 0
  do k = 1 to M_N; cs = M_C.k; used.cs = 1; end
  used.INDEX_CS = 1; used.KEYS_CS = 1; used.KH_CS = 1
  hex = Sha256Hex(position || d2c(turn // 256) || state)
  b1 = x2d(substr(hex, 3, 2)); b2 = x2d(substr(hex, 5, 2))
  dim = (b1 // 9) + 1
  w = translate(position, ' ', '/.')
  w = SetWord(w, dim, Wrap999(word(w, dim) + 1 + (b2 // 3)))
  cand = CoordJoin(w)
  do while used.cand
    cand = NextCoord(cand)
  end
  text = IMPL || ' turn ' || turn || ' at ' || cand
  return '{"coordinate":' || JQuote(cand) || ',"op":"insert","text":' || JQuote(text) || '}'

ApplyStep: procedure expose M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC. TMPDIR JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN
  parse arg state, step
  op = JStr(JGet(step, 'op'))
  cs = JStr(JGet(step, 'coordinate'))
  text = JStr(JGet(step, 'text'))
  fetch_hash = 'null'
  if op = 'fetch' then do
    return '{"fetch_sha256":' || JQuote(Sha256Hex(BufFetch(state, cs))) || ',"state_b64":' || JQuote(B64Enc(state)) || ',"state_sha256":' || JQuote(Sha256Hex(state)) || '}'
  end
  call Explode state
  select
    when op = 'insert' then call MapUpdate cs, text, 0
    when op = 'replace' then call MapUpdate cs, text, 1
    when op = 'remove' then call MapUpdate cs, '', 1
    otherwise nop
  end
  outf = TmpPath('applied')
  call ImplodeToFile outf
  b64txt = ShellToFile('base64 -w0 ' || outf, outf || '.b64')
  b64txt = strip(b64txt, 'T', '0A'x)
  shatxt = ShellToFile('sha256sum ' || outf, outf || '.sha')
  parse var shatxt newsha .
  'rm -f ' outf outf || '.b64' outf || '.sha'
  return '{"fetch_sha256":' || fetch_hash || ',"state_b64":"' || b64txt || '","state_sha256":"' || newsha || '"}'
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
/* phext.rexx -- libphext core for the REXX (Regina) port, 0.6.1 parity.
   Byte semantics mirror libphext-py phext.py: 9 dimension breaks
   (library 01, shelf 1F, series 1E, collection 1D, volume 1C, book 1A,
   chapter 19, section 18, scroll 17); a scroll is a maximal run of
   non-break bytes; insert concatenates, replace overwrites, remove is
   coordinate-preserving (replace "" + normalize: later scrolls do NOT
   shift). Map representation: stems M_N, M_C.1..M_N (coordinate
   strings "a.b.c/d.e.f/g.h.i", ascending), M_T.1..M_N (scroll texts).
   This file is a routines part-file: the port's programs (test and
   telephone CLI) are built by concatenating it with their main part,
   the classic-REXX substitute for a module system. */
PhextInit: procedure expose BREAKS BDIM. BRK. ALLB OUTB CD. PC.
  BREAKS = '011F1E1D1C1A191817'x
  BDIM. = ''
  do i = 1 to 9
    BRK.i = substr(BREAKS, i, 1)
    bc = c2d(BRK.i)
    BDIM.bc = i - 1
  end
  /* translate tables mapping every break byte to \x01 (itself a
     break, so masked \x01 positions are exactly the break positions) */
  ALLB = ''
  OUTB = ''
  do i = 0 to 255
    ALLB = ALLB || d2c(i)
    bc = i
    if BDIM.bc = '' then OUTB = OUTB || d2c(i)
    else OUTB = OUTB || '01'x
  end
  return

CoordParse: procedure expose C.
  parse arg s
  C.0 = 0
  s2 = translate(s, ' ', '/.')
  if words(s2) <> 9 then return 0
  do i = 1 to 9
    w = word(s2, i)
    if \datatype(w, 'W') then return 0
    if w < 1 then return 0
    C.i = w + 0
  end
  C.0 = 9
  return 1

CoordStr: procedure expose C.
  return C.1'.'C.2'.'C.3'/'C.4'.'C.5'.'C.6'/'C.7'.'C.8'.'C.9

CoordCmp: procedure
  parse arg a, b
  a2 = translate(a, ' ', '/.'); b2 = translate(b, ' ', '/.')
  do i = 1 to 9
    av = word(a2, i) + 0; bv = word(b2, i) + 0
    if av < bv then return -1
    if av > bv then return 1
  end
  return 0

Explode: procedure expose M_N M_C. M_T. BREAKS BDIM. BRK. ALLB OUTB CD. PC. PC.
  /* Block scan: verify()/pos() cost in Regina is proportional to the
     length of the string searched (argument copy), so the phext is
     scanned in 8 KB blocks over a translate-masked copy (every break
     byte masked to \x01); runs are carried across block boundaries
     via the open/pending state. */
  parse arg data
  M_N = 0
  do j = 1 to 9; CD.j = 1; end
  marker = '01'x
  open = 0
  pending = ''
  L = length(data)
  base = 0
  do while base < L
    /* substr pads with spaces past the end of the string: request
       only the bytes that remain */
    block = substr(data, base + 1, min(8192, L - base))
    blen = length(block)
    masked = translate(block, OUTB, ALLB)
    i = 1
    do while i <= blen
      nb = verify(masked, marker, 'M', i)
      if nb = 0 then nb = blen + 1
      if nb > i then do
        seg = substr(block, i, nb - i)
        if open then pending = pending || seg
        else do
          pending = seg
          open = 1
          do j = 1 to 9; PC.j = CD.j; end
        end
      end
      if nb = blen + 1 then leave
      if open then do
        M_N = M_N + 1
        M_C.M_N = PC.1'.'PC.2'.'PC.3'/'PC.4'.'PC.5'.'PC.6'/'PC.7'.'PC.8'.'PC.9
        M_T.M_N = pending
        open = 0
        pending = ''
      end
      bc = c2d(substr(block, nb, 1))
      d = BDIM.bc
      dd = d + 1
      CD.dd = CD.dd + 1
      do j = dd + 1 to 9; CD.j = 1; end
      i = nb + 1
    end
    base = base + blen
  end
  if open then do
    M_N = M_N + 1
    M_C.M_N = PC.1'.'PC.2'.'PC.3'/'PC.4'.'PC.5'.'PC.6'/'PC.7'.'PC.8'.'PC.9
    M_T.M_N = pending
  end
  return

CoordOf: procedure
  parse arg coord
  return word(coord,1)'.'word(coord,2)'.'word(coord,3)'/'word(coord,4)'.'word(coord,5)'.'word(coord,6)'/'word(coord,7)'.'word(coord,8)'.'word(coord,9)

ApplyBreak: procedure
  parse arg coord, d
  out = ''
  do i = 1 to 9
    v = word(coord, i)
    if i = d + 1 then v = v + 1
    if i > d + 1 then v = 1
    out = out v
  end
  return strip(out)

ImplodePieces: procedure expose M_N M_C. M_T. BREAKS P_N P.
  P_N = 0
  loc = '1 1 1 1 1 1 1 1 1'
  do k = 1 to M_N
    if M_T.k == '' then iterate
    tgt = translate(M_C.k, ' ', '/.')
    if CoordListCmp(loc, tgt) < 0 then do
      dim = 0
      do i = 1 to 9
        if word(loc, i) = word(tgt, i) then dim = i
        else leave
      end
      /* dim = count of equal leading components (0-based break dim) */
      P_N = P_N + 1; P.P_N = copies(substr(BREAKS, dim + 1, 1), word(tgt, dim + 1) - word(loc, dim + 1))
      newloc = ''
      do i = 1 to 9
        if i <= dim then newloc = newloc word(loc, i)
        else if i = dim + 1 then newloc = newloc word(tgt, i)
        else newloc = newloc 1
      end
      loc = strip(newloc)
      do j = dim + 2 to 9
        P_N = P_N + 1; P.P_N = copies(substr(BREAKS, j, 1), word(tgt, j) - 1)
        loc = SetWord(loc, j, word(tgt, j))
      end
    end
    P_N = P_N + 1; P.P_N = M_T.k
  end
  return

Implode: procedure expose M_N M_C. M_T. BREAKS P_N P.
  call ImplodePieces
  out = ''
  do k = 1 to P_N
    out = out || P.k
  end
  return out

/* Streaming implode for large maps: writes the pieces with charout
   instead of building one string (REXX concatenation is quadratic). */
ImplodeToFile: procedure expose M_N M_C. M_T. BREAKS P_N P.
  parse arg path
  'rm -f ' path
  call ImplodePieces
  call charout path, '', 1
  do k = 1 to P_N
    call charout path, P.k
  end
  call stream path, 'C', 'CLOSE'
  return

SetWord: procedure
  parse arg lst, idx, val
  out = ''
  do i = 1 to words(lst)
    if i = idx then out = out val
    else out = out word(lst, i)
  end
  return strip(out)

CoordListCmp: procedure
  parse arg a, b
  do i = 1 to 9
    if word(a, i) + 0 < word(b, i) + 0 then return -1
    if word(a, i) + 0 > word(b, i) + 0 then return 1
  end
  return 0

MapFind: procedure expose M_N M_C. M_T.
  parse arg cs
  do k = 1 to M_N
    if M_C.k = cs then return k
  end
  return 0

MapFetch: procedure expose M_N M_C. M_T.
  parse arg cs
  k = MapFind(cs)
  if k = 0 then return ''
  return M_T.k

/* overwrite=1: replace; overwrite=0: insert (concatenate old||new).
   Empty text with overwrite removes; empty insert is a no-op. */
MapUpdate: procedure expose M_N M_C. M_T.
  parse arg cs, text, overwrite
  k = MapFind(cs)
  if text == '' then do
    if overwrite & k > 0 then do
      do j = k to M_N - 1
        n = j + 1; M_C.j = M_C.n; M_T.j = M_T.n
      end
      M_N = M_N - 1
    end
    return
  end
  if k > 0 then do
    if overwrite then M_T.k = text
    else M_T.k = M_T.k || text
    return
  end
  /* insert in ascending coordinate order */
  pos = M_N + 1
  do j = 1 to M_N
    if CoordCmp(M_C.j, cs) > 0 then do; pos = j; leave; end
  end
  do j = M_N to pos by -1
    n = j + 1; M_C.n = M_C.j; M_T.n = M_T.j
  end
  M_C.pos = cs; M_T.pos = text; M_N = M_N + 1
  return

BufFetch: procedure expose M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC.
  parse arg data, cs
  call Explode data
  return MapFetch(cs)

BufInsert: procedure expose M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC.
  parse arg data, cs, text
  call Explode data
  call MapUpdate cs, text, 0
  return Implode()

BufReplace: procedure expose M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC.
  parse arg data, cs, text
  call Explode data
  call MapUpdate cs, text, 1
  return Implode()

BufRemove: procedure expose M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC.
  parse arg data, cs
  call Explode data
  call MapUpdate cs, '', 1
  return Implode()

BufNormalize: procedure expose M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC.
  parse arg data
  call Explode data
  return Implode()

/* ---- DynamicPhext: capacity-managed dynamic array store (CLRS
   quarter-full shrink), semantics identical to the buffer API. ---- */
DynInit: procedure expose D_N D_C. D_T. D_CAP D_RESIZE D_COPIED
  D_N = 0; D_CAP = 1; D_RESIZE = 0; D_COPIED = 0
  return

DynResize: procedure expose D_N D_C. D_T. D_CAP D_RESIZE D_COPIED
  parse arg newcap
  D_CAP = newcap; D_RESIZE = D_RESIZE + 1; D_COPIED = D_COPIED + D_N
  return

DynUpdate: procedure expose D_N D_C. D_T. D_CAP D_RESIZE D_COPIED
  parse arg cs, text, overwrite
  k = 0
  do j = 1 to D_N
    if D_C.j = cs then do; k = j; leave; end
  end
  if text == '' then do
    if overwrite & k > 0 then do
      do j = k to D_N - 1
        n = j + 1; D_C.j = D_C.n; D_T.j = D_T.n
      end
      D_N = D_N - 1
      if D_CAP > 1 & D_N <= D_CAP % 4 then call DynResize max(1, D_CAP % 2)
    end
    return
  end
  if k > 0 then do
    if overwrite then D_T.k = text
    else D_T.k = D_T.k || text
    return
  end
  if D_N = D_CAP then call DynResize D_CAP * 2
  pos = D_N + 1
  do j = 1 to D_N
    if CoordCmp(D_C.j, cs) > 0 then do; pos = j; leave; end
  end
  do j = D_N to pos by -1
    n = j + 1; D_C.n = D_C.j; D_T.n = D_T.j
  end
  D_C.pos = cs; D_T.pos = text; D_N = D_N + 1
  return

DynFetch: procedure expose D_N D_C. D_T.
  parse arg cs
  do j = 1 to D_N
    if D_C.j = cs then return D_T.j
  end
  return ''

DynSerialize: procedure expose D_N D_C. D_T. M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC.
  M_N = D_N
  do j = 1 to D_N; M_C.j = D_C.j; M_T.j = D_T.j; end
  return Implode()

/* ---- TransitivePhext: branching hash-map store, one stem level per
   dimension (REXX stems are the native branching map). Leaves live in
   TR.<c1>.<c2>...<c9>; a sorted coordinate index is kept for
   serialization, exactly as the Python store walks sorted keys. ---- */
TrnInit: procedure expose TR. TR_N TR_C.
  drop TR.; TR_N = 0
  return

TrnKey: procedure
  parse arg cs
  return 'TR.' || translate(cs, '..', '/.')

TrnUpdate: procedure expose TR. TR_N TR_C.
  parse arg cs, text, overwrite
  key = TrnKey(cs)
  if symbol(key) = 'VAR' then cur = value(key)
  else cur = ''
  if text == '' then do
    if overwrite & cur \== '' then do
      call value key, ''
      k = 0
      do j = 1 to TR_N
        if TR_C.j = cs then do; k = j; leave; end
      end
      if k > 0 then do
        do j = k to TR_N - 1
          n = j + 1; TR_C.j = TR_C.n
        end
        TR_N = TR_N - 1
      end
    end
    return
  end
  if cur \== '' then do
    if overwrite then call value key, text
    else call value key, cur || text
    return
  end
  call value key, text
  pos = TR_N + 1
  do j = 1 to TR_N
    if CoordCmp(TR_C.j, cs) > 0 then do; pos = j; leave; end
  end
  do j = TR_N to pos by -1
    n = j + 1; TR_C.n = TR_C.j
  end
  TR_C.pos = cs; TR_N = TR_N + 1
  return

TrnFetch: procedure expose TR. TR_N TR_C.
  parse arg cs
  key = TrnKey(cs)
  if symbol(key) <> 'VAR' then return ''
  return value(key)

TrnSerialize: procedure expose TR. TR_N TR_C. M_N M_C. M_T. BREAKS BDIM. BRK. P_N P. ALLB OUTB CD. PC.
  M_N = TR_N
  do j = 1 to TR_N; M_C.j = TR_C.j; M_T.j = value(TrnKey(TR_C.j)); end
  return Implode()

TrnDepth: procedure
  return 9
/* json.rexx -- minimal JSON parser + canonical serializer for the
   REXX port (part-file, concatenated into the telephone CLI).
   Node pool: JT.i type, JS.i string value, JNUM.i number text,
   JO.i.k/JOV.i.k object keys/values (k=1..JOC.i), JA.i.k array items
   (k=1..JAC.i). Canonical form matches Python json.dumps with
   sort_keys=True, separators=(",",":"), ensure_ascii=True on the
   ASCII data the game actually carries. */
JParse: procedure expose JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN PSTR PPOS PLEN JSTRERR
  parse arg s
  JN = 0; PSTR = s; PLEN = length(s); PPOS = 1
  call JSkipWs
  r = JParseValue()
  if r = 0 then return 0
  call JSkipWs
  if PPOS <= PLEN then return 0
  return r

JNew: procedure expose JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN
  parse arg t
  JN = JN + 1
  JT.JN = t; JS.JN = ''; JNUM.JN = ''; JOC.JN = 0; JAC.JN = 0
  return JN

JSkipWs: procedure expose PSTR PPOS PLEN
  do while PPOS <= PLEN
    c = substr(PSTR, PPOS, 1)
    if c = ' ' | c = '09'x | c = '0A'x | c = '0D'x then PPOS = PPOS + 1
    else leave
  end
  return

JPeek: procedure expose PSTR PPOS PLEN
  if PPOS > PLEN then return ''
  return substr(PSTR, PPOS, 1)

JParseValue: procedure expose JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN PSTR PPOS PLEN JSTRERR
  c = JPeek()
  if c = '{' then do
    id = JNew('obj'); PPOS = PPOS + 1; call JSkipWs
    if JPeek() = '}' then do; PPOS = PPOS + 1; return id; end
    do forever
      call JSkipWs
      JSTRERR = 0
      k = JParseString()
      if JSTRERR then return 0
      call JSkipWs
      if JPeek() <> ':' then return 0
      PPOS = PPOS + 1; call JSkipWs
      v = JParseValue()
      if v = 0 then return 0
      n = JOC.id + 1; JOC.id = n; JO.id.n = k; JOV.id.n = v
      call JSkipWs
      ch = JPeek()
      if ch = ',' then do; PPOS = PPOS + 1; iterate; end
      if ch = '}' then do; PPOS = PPOS + 1; return id; end
      return 0
    end
  end
  if c = '[' then do
    id = JNew('arr'); PPOS = PPOS + 1; call JSkipWs
    if JPeek() = ']' then do; PPOS = PPOS + 1; return id; end
    do forever
      call JSkipWs
      v = JParseValue()
      if v = 0 then return 0
      n = JAC.id + 1; JAC.id = n; JA.id.n = v
      call JSkipWs
      ch = JPeek()
      if ch = ',' then do; PPOS = PPOS + 1; iterate; end
      if ch = ']' then do; PPOS = PPOS + 1; return id; end
      return 0
    end
  end
  if c = '"' then do
    JSTRERR = 0
    s = JParseString()
    if JSTRERR then return 0
    id = JNew('str'); JS.id = s; return id
  end
  if substr(PSTR, PPOS, 4) = 'true' then do
    id = JNew('bool'); JS.id = 'true'; PPOS = PPOS + 4; return id
  end
  if substr(PSTR, PPOS, 5) = 'false' then do
    id = JNew('bool'); JS.id = 'false'; PPOS = PPOS + 5; return id
  end
  if substr(PSTR, PPOS, 4) = 'null' then do
    id = JNew('null'); PPOS = PPOS + 4; return id
  end
  /* number */
  start = PPOS
  do while PPOS <= PLEN
    ch = substr(PSTR, PPOS, 1)
    if pos(ch, '-+0123456789.eE') > 0 then PPOS = PPOS + 1
    else leave
  end
  if PPOS = start then return 0
  id = JNew('num'); JNUM.id = substr(PSTR, start, PPOS - start)
  return id

/* returns the decoded string; on error sets JSTRERR=1 and returns '' */
JParseString: procedure expose PSTR PPOS PLEN JSTRERR
  if JPeek() <> '"' then do; JSTRERR = 1; return ''; end
  PPOS = PPOS + 1
  out = ''
  specials = '"' || '\'
  do forever
    if PPOS > PLEN then do; JSTRERR = 1; return ''; end
    nb = verify(PSTR, specials, 'M', PPOS)
    if nb = 0 then do; JSTRERR = 1; return ''; end
    if nb > PPOS then out = out || substr(PSTR, PPOS, nb - PPOS)
    c = substr(PSTR, nb, 1)
    if c = '"' then do; PPOS = nb + 1; return out; end
    if nb + 1 > PLEN then do; JSTRERR = 1; return ''; end
    e = substr(PSTR, nb + 1, 1)
    PPOS = nb + 2
    select
      when e = '"' then out = out || '"'
      when e = '\' then out = out || '\'
      when e = '/' then out = out || '/'
      when e = 'b' then out = out || '08'x
      when e = 'f' then out = out || '0C'x
      when e = 'n' then out = out || '0A'x
      when e = 'r' then out = out || '0D'x
      when e = 't' then out = out || '09'x
      when e = 'u' then do
        hex = substr(PSTR, PPOS, 4)
        if length(hex) < 4 | \datatype(hex, 'X') then do; JSTRERR = 1; return ''; end
        PPOS = PPOS + 4
        cp = x2d(hex)
        if cp >= 55296 & cp <= 56319 & substr(PSTR, PPOS, 2) = '\u' then do
          hex2 = substr(PSTR, PPOS + 2, 4)
          if datatype(hex2, 'X') then do
            lo = x2d(hex2)
            if lo >= 56320 & lo <= 57343 then do
              cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
              PPOS = PPOS + 6
            end
          end
        end
        out = out || Utf8Encode(cp)
      end
      otherwise do; JSTRERR = 1; return ''; end
    end
  end

Utf8Encode: procedure
  parse arg cp
  if cp < 128 then return d2c(cp)
  if cp < 2048 then return d2c(192 + (cp % 64)) || d2c(128 + (cp // 64))
  if cp < 65536 then do
    r = cp // 4096
    return d2c(224 + (cp % 4096)) || d2c(128 + (r % 64)) || d2c(128 + (r // 64))
  end
  r = cp // 262144
  r2 = r // 4096
  return d2c(240 + (cp % 262144)) || d2c(128 + (r % 4096)) || d2c(128 + (r2 % 64)) || d2c(128 + (r2 // 64))

JGet: procedure expose JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN
  parse arg id, key
  if id = 0 | JT.id <> 'obj' then return 0
  do k = 1 to JOC.id
    if JO.id.k = key then return JOV.id.k
  end
  return 0

JHas: procedure expose JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN
  parse arg id, key
  return JGet(id, key) <> 0

JStr: procedure expose JT. JS. JNUM.
  parse arg id
  if id = 0 then return ''
  if JT.id = 'str' | JT.id = 'bool' then return JS.id
  if JT.id = 'num' then return JNUM.id
  return ''

JNum: procedure expose JT. JS. JNUM.
  parse arg id
  if id = 0 then return 0
  if JT.id = 'num' then return JNUM.id + 0
  if JT.id = 'str' then return JS.id + 0
  return 0

JCanon: procedure expose JT. JS. JNUM. JO. JOV. JOC. JA. JAC. JN
  parse arg id
  t = JT.id
  select
    when t = 'null' then return 'null'
    when t = 'bool' then return JS.id
    when t = 'num' then return JNumCanon(JNUM.id)
    when t = 'str' then return JQuote(JS.id)
    when t = 'arr' then do
      out = '['
      do k = 1 to JAC.id
        if k > 1 then out = out || ','
        out = out || JCanon(JA.id.k)
      end
      return out || ']'
    end
    when t = 'obj' then do
      /* insertion-sort key indices by byte order */
      n = JOC.id
      idx = ''
      do k = 1 to n; idx = idx k; end
      do a = 1 to n
        do b = a + 1 to n
          ka_i = word(idx, a); kb_i = word(idx, b)
          ka = JO.id.ka_i; kb = JO.id.kb_i
          if kb << ka then do
            tmp = word(idx, a); idx = SetWord(idx, a, word(idx, b)); idx = SetWord(idx, b, tmp)
          end
        end
      end
      out = '{'
      do a = 1 to n
        k = word(idx, a)
        if a > 1 then out = out || ','
        out = out || JQuote(JO.id.k) || ':' || JCanon(JOV.id.k)
      end
      return out || '}'
    end
    otherwise return 'null'
  end

JNumCanon: procedure
  parse arg raw
  /* integers print without decoration; game numbers are integers */
  if datatype(raw, 'W') then return raw + 0
  return raw

JQuote: procedure
  parse arg s
  out = '"'
  do i = 1 to length(s)
    c = substr(s, i, 1); b = c2d(c)
    select
      when c = '"' then out = out || '\"'
      when c = '\' then out = out || '\\'
      when b = 8 then out = out || '\b'
      when b = 9 then out = out || '\t'
      when b = 10 then out = out || '\n'
      when b = 12 then out = out || '\f'
      when b = 13 then out = out || '\r'
      when b < 32 then out = out || '\u' || right(d2x(b), 4, '0')
      when b < 128 then out = out || c
      otherwise out = out || '\u' || right(d2x(b), 4, '0')
    end
  end
  return out || '"'
