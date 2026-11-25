NB. phext.ijs -- libphext core for the J port, 0.6.1 parity with
NB. libphext-py: 9 dimension breaks; a scroll is a maximal run of
NB. non-break bytes; insert concatenates, replace overwrites,
NB. remove is coordinate-preserving (replace "" + normalize).
NB. A scroll map is (coords table n x 9 ; boxed texts).

BRKCH =: (1 31 30 29 28 26 25 24 23) { a.
DIMTAB =: (0 1 2 3 4 5 6 7 8) (1 31 30 29 28 26 25 24 23)} 256 $ _1
NB. Empty boxed vector; multi-box structures are built with , of
NB. single < boxes (NB: ; flattens boxed-array components).
EMPTYB =: 0 $ <''
mkMap =: {{ (<x) , <y }}

splitStr =: {{
  d =. x
  s =. y
  out =. ''
  cur =. ''
  i =. 0
  while. i < #s do.
    ch =. i { s
    if. ch = d do.
      out =. out , <cur
      cur =. ''
    else.
      cur =. cur , ch
    end.
    i =. i + 1
  end.
  out , <cur
}}

NB. y = text; returns boxed lines (LF-split, no trailing empty line).
linesOf =: {{
  s =. y
  if. 0 = #s do. '' return. end.
  pos =. I. s = 10 { a.
  starts =. 0 , pos + 1
  ends =. pos , #s
  if. ({: starts) = #s do.
    starts =. }: starts
    ends =. }: ends
  end.
  out =. ''
  i =. 0
  while. i < #starts do.
    st =. i { starts
    out =. out , < ((i { ends) - st) {. st }. s
    i =. i + 1
  end.
  out
}}

joinWith =: {{
  d =. x
  items =. y
  r =. ''
  i =. 0
  while. i < #items do.
    if. i > 0 do. r =. r , d end.
    r =. r , > i { items
    i =. i + 1
  end.
  r
}}

NB. y = coordinate string; returns 9-vector, or '' on failure.
parseCoord =: {{
  s =. y
  grp =. '/' splitStr s
  if. (#grp) > 3 do. '' return. end.
  c =. 9 # 1
  gi =. 0
  while. gi < #grp do.
    g =. > gi { grp
    parts =. '.' splitStr g
    if. (#parts) > 3 do. '' return. end.
    pi =. 0
    while. pi < #parts do.
      p =. > pi { parts
      if. 0 = #p do. '' return. end.
      if. -. */ p e. '0123456789' do. '' return. end.
      c =. (". p) (< (gi * 3) + pi) } c
      pi =. pi + 1
    end.
    gi =. gi + 1
  end.
  c
}}

NB. y = 9-vector; returns canonical string.
coordStr =: {{
  c =. y
  parts =. ''
  gi =. 0
  while. gi < 3 do.
    grp =. ((gi * 3) + 0 1 2) { c
    parts =. parts , < ('.' joinWith (": each grp))
    gi =. gi + 1
  end.
  '/' joinWith parts
}}

NB. x = coord, y = break dims of one run; returns advanced coord.
NB. A break at dim d increments coord[d] and resets dims > d to 1;
NB. a whole run is applied per dimension: for dim d, breaks at dims
NB. < d reset it, so only d-breaks after the last smaller break count.
applyRun =: {{
  coord =. x
  dims =. y
  if. 0 = #dims do. coord return. end.
  idxs =. i. #dims
  d =. 0
  while. d < 9 do.
    smaller =. idxs #~ dims < d
    q =. _1
    if. #smaller do. q =. {: smaller end.
    cnt =. +/ (dims = d) *. idxs > q
    base =. d { coord
    if. q > _1 do. base =. 1 end.
    coord =. (base + cnt) d } coord
    d =. d + 1
  end.
  coord
}}

NB. y = data; returns (coords ; texts).
explode =: {{
  data =. y
  if. 0 = #data do. (0 9 $ 0) mkMap EMPTYB return. end.
  isb =. data e. BRKCH
  segid =. +/\ isb
  keep =. -. isb
  txt =. keep # data
  tseg =. keep # segid
  uids =. ~. tseg
  NB. boxed segment texts via a fret vector at segment starts
  if. #txt do.
    starts =. I. (}. tseg) ~: }: tseg
    fret =. 1 (0 , starts + 1) } (#txt) $ 0
    texts =. fret <;.1 txt
  else.
    texts =. EMPTYB
  end.
  bdims =. DIMTAB {~ a. i. isb # data
  coords =. 0 9 $ 0
  coord =. 9 # 1
  prevk =. 0
  ui =. 0
  while. ui < #uids do.
    k =. ui { uids
    run =. (k - prevk) {. prevk }. bdims
    coord =. coord applyRun run
    coords =. coords , coord
    prevk =. k
    ui =. ui + 1
  end.
  coords mkMap texts
}}

NB. y = (coords ; texts); returns the buffer.
implode =: {{
  'CO TX' =. y
  nn =. 0 { $ CO
  prev =. 9 # 1
  pieces =. EMPTYB
  i =. 0
  while. i < nn do.
    c =. i { CO
    f =. (prev ~: c) i. 1
    if. f < 9 do.
      pieces =. pieces , < ((c {~ f) - prev {~ f) # f { BRKCH
      d =. f + 1
      while. d < 9 do.
        pieces =. pieces , < ((d { c) - 1) # d { BRKCH
        d =. d + 1
      end.
    end.
    pieces =. pieces , < > i { TX
    prev =. c
    i =. i + 1
  end.
  ; pieces
}}

NB. x = (coords ; texts), y = coord; returns row index or n.
mfind =: {{
  'CO TX' =. x
  (y -:"1 CO) i. 1
}}

NB. x = (coords ; texts), y = (coord ; text ; overwrite 0/1).
mupdate =: {{
  'CO TX' =. x
  'c text ow' =. y
  nn =. 0 { $ CO
  idx =. (c -:"1 CO) i. 1
  if. idx < nn do.
    if. ow do.
      if. 0 = #text do.
        CO =. (idx {. CO) , (idx + 1) }. CO
        TX =. (idx {. TX) , (idx + 1) }. TX
      else.
        TX =. (<text) idx } TX
      end.
    else.
      if. #text do.
        TX =. (< (> idx { TX) , text) idx } TX
      end.
    end.
    CO mkMap TX return.
  end.
  if. 0 = #text do. CO mkMap TX return. end.
  CO2 =. CO , c
  TX2 =. TX , <text
  ord =. /: CO2
  (ord { CO2) mkMap (ord { TX2)
}}

NB. Buffer API: each takes/returns raw buffers.
bufFetch =: {{
  'CO TX' =. explode x
  idx =. (y -:"1 CO) i. 1
  if. idx < 0 { $ CO do. > idx { TX else. '' end.
}}
bufInsert =: {{
  'data c text' =. y
  implode (explode data) mupdate (c ; text ; 0)
}}
bufReplace =: {{
  'data c text' =. y
  implode (explode data) mupdate (c ; text ; 1)
}}
bufRemove =: {{
  'data c' =. y
  implode (explode data) mupdate (c ; '' ; 1)
}}
bufNormalize =: {{
  implode explode y
}}

NB. ---- DynamicPhext: (coords ; texts ; cap ; resizes ; copied) ----
dynNew =: (<(0 9 $ 0)) , (<EMPTYB) , (<1) , (<0) , <0
dynUpdate =: {{
  'CO TX cap rs cp' =. x
  'c text ow' =. y
  nn =. 0 { $ CO
  idx =. (c -:"1 CO) i. 1
  if. idx < nn do.
    if. ow do.
      if. 0 = #text do.
        CO =. (idx {. CO) , (idx + 1) }. CO
        TX =. (idx {. TX) , (idx + 1) }. TX
        nn =. nn - 1
        if. (cap > 1) *. nn <: <. cap % 4 do.
          cap =. 1 >. <. cap % 2
          rs =. rs + 1
          cp =. cp + nn
        end.
      else.
        TX =. (<text) idx } TX
      end.
    else.
      if. #text do.
        TX =. (< (> idx { TX) , text) idx } TX
      end.
    end.
    ((<CO) , (<TX) , (<cap) , (<rs) , <cp) return.
  end.
  if. 0 = #text do. ((<CO) , (<TX) , (<cap) , (<rs) , <cp) return. end.
  if. nn = cap do.
    cap =. 2 * cap
    rs =. rs + 1
    cp =. cp + nn
  end.
  CO2 =. CO , c
  TX2 =. TX , <text
  ord =. /: CO2
  (<(ord { CO2)) , (<(ord { TX2)) , (<cap) , (<rs) , <cp
}}
dynFetch =: {{
  'CO TX cap rs cp' =. x
  idx =. (y -:"1 CO) i. 1
  if. idx < 0 { $ CO do. > idx { TX else. '' end.
}}
dynLen =: {{ 0 { $ > 0 { y }}
dynSerialize =: {{
  'CO TX cap rs cp' =. y
  implode CO mkMap TX
}}

NB. ---- TransitivePhext: trie of (keys ; kids ; text ; has) nodes ----
trnNewNode =: (<(i. 0)) , (<EMPTYB) , (<'') , <0
trnUpdate =: {{
  'keys kids text has' =. x
  'path txt ow' =. y
  if. 0 = #path do.
    if. ow do.
      if. 0 = #txt do.
        ((<keys) , (<kids) , (<'') , <0) return.
      else.
        ((<keys) , (<kids) , (<txt) , <1) return.
      end.
    else.
      if. 0 = #txt do. x return. end.
      if. has do.
        ((<keys) , (<kids) , (<(text , txt)) , <1) return.
      else.
        ((<keys) , (<kids) , (<txt) , <1) return.
      end.
    end.
  end.
  k =. {. path
  rest =. }. path
  idx =. keys i. k
  if. idx < #keys do.
    kid =. > idx { kids
    kid =. kid trnUpdate (rest ; txt ; ow)
    ((<keys) , (<((<kid) idx } kids)) , (<text) , <has) return.
  end.
  NB. absent: creating is harmless even for a no-op leaf op because
  NB. empty nodes never serialize.
  kid =. trnNewNode trnUpdate (rest ; txt ; ow)
  keys2 =. keys , k
  kids2 =. kids , <kid
  ord =. /: keys2
  (<(ord { keys2)) , (<(ord { kids2)) , (<text) , <has
}}
trnFetch =: {{
  'keys kids text has' =. x
  path =. y
  if. 0 = #path do.
    if. has do. text else. '' end.
    return.
  end.
  idx =. keys i. {. path
  if. idx < #keys do.
    (> idx { kids) trnFetch }. path
  else.
    ''
  end.
}}
trnHas =: {{
  'keys kids text has' =. x
  path =. y
  if. 0 = #path do. has return. end.
  idx =. keys i. {. path
  if. idx < #keys do.
    (> idx { kids) trnHas }. path
  else.
    0
  end.
}}
NB. DFS collect into globals TC (coords flat) and TT (texts boxed).
trnCollect =: {{
  'keys kids text has' =. x
  depth =. y
  if. depth = 9 do.
    if. has do.
      TC =: TC , TPREFIX
      TT =: TT , <text
    end.
    return.
  end.
  i =. 0
  while. i < #keys do.
    TPREFIX =: (i { keys) depth } TPREFIX
    (> i { kids) trnCollect depth + 1
    i =. i + 1
  end.
  return.
}}
trnSerialize =: {{
  TC =: i. 0
  TT =: EMPTYB
  TPREFIX =: 9 # 1
  y trnCollect 0
  implode (((#TT) , 9) $ TC) mkMap TT
}}
trnLen =: {{
  TC =: i. 0
  TT =: EMPTYB
  TPREFIX =: 9 # 1
  y trnCollect 0
  #TT
}}
trnDepth =: 9
