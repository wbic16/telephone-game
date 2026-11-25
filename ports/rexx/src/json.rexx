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
