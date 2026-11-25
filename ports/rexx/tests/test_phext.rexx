/* test-main.rexx -- unit + conformance tests for the REXX libphext
   port (concatenated after phext.rexx). Arg: path of a file listing
   the 16 fixture input.phext paths, or "" to skip fixtures. */
FAILURES = 0
call PhextInit
main:
  parse arg listfile
  sb = '17'x; sc = '18'x
  /* coordinates */
  ok = CoordParse('2.3.4/5.6.7/8.9.10')
  call Check ok & CoordStr() = '2.3.4/5.6.7/8.9.10', 'coord round-trip'
  call Check CoordCmp('1.1.1/1.1.1/1.1.2', '1.1.1/1.1.1/1.1.10') < 0, 'coord order'
  call Check \CoordParse('1.1.1/1.1.1/1.1.0'), 'coord rejects 0'
  call Check \CoordParse('1.1.1/1.1.1'), 'coord rejects short'
  /* basic scroll ops */
  buf = 'alpha' || sb || 'beta' || sc || 'gamma'
  call Check BufFetch(buf, '1.1.1/1.1.1/1.1.1') = 'alpha', 'fetch first'
  call Check BufFetch(buf, '1.1.1/1.1.1/1.1.2') = 'beta', 'fetch scroll 2'
  call Check BufFetch(buf, '1.1.1/1.1.1/1.2.1') = 'gamma', 'fetch section 2 scroll 1'
  call Check BufFetch(buf, '1.1.1/1.1.1/1.1.9') = '', 'fetch gap is empty'
  call Check BufNormalize(buf) = buf, 'normalize idempotent on canonical'
  b2 = BufInsert('', '1.1.1/1.1.1/1.1.2', 'second')
  call Check BufFetch(b2, '1.1.1/1.1.1/1.1.2') = 'second', 'insert creates'
  b2 = BufInsert(b2, '1.1.1/1.1.1/1.1.2', '+more')
  call Check BufFetch(b2, '1.1.1/1.1.1/1.1.2') = 'second+more', 'insert concatenates'
  b2 = BufReplace(b2, '1.1.1/1.1.1/1.1.2', 'replaced')
  call Check BufFetch(b2, '1.1.1/1.1.1/1.1.2') = 'replaced', 'replace overwrites'
  /* remove is coordinate-preserving */
  b3 = 'one' || sb || 'two' || sb || 'three'
  b3r = BufRemove(b3, '1.1.1/1.1.1/1.1.2')
  call Check BufFetch(b3r, '1.1.1/1.1.1/1.1.1') = 'one', 'remove keeps first'
  call Check BufFetch(b3r, '1.1.1/1.1.1/1.1.2') = '', 'remove empties target'
  call Check BufFetch(b3r, '1.1.1/1.1.1/1.1.3') = 'three', 'remove does not shift later scrolls'
  /* gap round-trip */
  gap = BufInsert('', '3.1.4/1.5.9/2.6.5', 'far')
  call Explode gap
  call Check Implode() = gap, 'explode/implode gap round-trip'
  /* DynamicPhext / TransitivePhext equivalence */
  coords = '1.1.1/1.1.1/1.1.1 1.1.1/1.1.1/1.1.2 1.1.1/1.1.1/1.2.1 2.1.1/1.1.1/1.1.1 1.1.1/1.1.1/1.1.3'
  call DynInit
  call TrnInit
  buf = ''
  do i = 1 to words(coords)
    c = word(coords, i)
    buf = BufInsert(buf, c, 'text' || i)
    call DynUpdate c, 'text' || i, 0
    call TrnUpdate c, 'text' || i, 0
    call Check DynSerialize() = buf, 'dynamic == buffer after insert ' || i
    call Check TrnSerialize() = buf, 'transitive == buffer after insert ' || i
  end
  mid = word(coords, 2)
  buf = BufRemove(buf, mid)
  call DynUpdate mid, '', 1
  call TrnUpdate mid, '', 1
  call Check DynSerialize() = buf, 'dynamic == buffer after remove'
  call Check TrnSerialize() = buf, 'transitive == buffer after remove'
  call Check DynFetch(mid) = '' & TrnFetch(mid) = '', 'stores fetch removed as empty'
  call Check D_N = 4 & TR_N = 4, 'store lengths'
  first = word(coords, 1)
  call DynUpdate first, '', 1
  buf = BufRemove(buf, first)
  call Check DynSerialize() = buf, 'dynamic replace-empty removes'
  call Check TrnDepth() = 9, 'transitive depth 9'
  /* fixtures: 16/16 byte-identical round-trips */
  if listfile <> '' then do
    files = ReadFile(listfile)
    n = 0; okc = 0
    do while files <> ''
      parse var files f '0A'x files
      f = strip(f)
      if f = '' then iterate
      n = n + 1
      data = ReadFile(f)
      if length(data) > 200000 then do
        /* large corpus: stream the round-trip to files (string
           concatenation would be quadratic at this size) */
        call Explode data
        call ImplodeToFile '/tmp/rexx-rt1.phext'
        'cmp -s ' f ' /tmp/rexx-rt1.phext'
        rc1 = RC
        data2 = ReadFile('/tmp/rexx-rt1.phext')
        call Explode data2
        call ImplodeToFile '/tmp/rexx-rt2.phext'
        'cmp -s /tmp/rexx-rt1.phext /tmp/rexx-rt2.phext'
        rc2 = RC
        if rc1 = 0 & rc2 = 0 then okc = okc + 1
        else say 'FAIL - fixture round-trip (streamed): ' f
      end
      else do
        call Explode data
        rt = Implode()
        if rt = data & BufNormalize(BufNormalize(data)) = BufNormalize(data) then okc = okc + 1
        else say 'FAIL - fixture round-trip: ' f
      end
    end
    call Check n = 16, 'found 16 fixture inputs (got ' || n || ')'
    call Check okc = 16, 'fixtures round-trip ' || okc || '/16'
  end
  else say 'skip - no fixture list (fixtures check skipped)'
  if FAILURES > 0 then do; say 'FAILURES: ' || FAILURES; exit 1; end
  say 'PASS'
  exit 0

Check: procedure expose FAILURES
  parse arg cond, name
  if cond then say 'ok - ' || name
  else do; say 'FAIL - ' || name; FAILURES = FAILURES + 1; end
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
