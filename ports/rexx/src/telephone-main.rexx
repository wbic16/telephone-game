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
