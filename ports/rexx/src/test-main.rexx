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
