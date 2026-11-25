NB. json.ijs -- minimal JSON parser + canonical serializer for the
NB. J port. Nodes are boxed lists: ('null';'') | ('bool';0/1) |
NB. ('num';rawtext) | ('str';text) | ('arr';items) |
NB. ('obj';keys;vals). Canonical form matches Python
NB. json.dumps(sort_keys=True, separators=(",",":"), ensure_ascii=True).

jNull =: 'null' ; ''
jStr =: {{ 'str' ; <y }}
jNum =: {{ 'num' ; <y }}
jBool =: {{ 'bool' ; <y }}
jArr =: {{ 'arr' ; <y }}
jObj =: {{ (< 'obj') , (<x) , <y }}
jTag =: {{ > 0 { y }}
jIsNull =: {{ 'null' -: > 0 { y }}

jGet =: {{
  keys =. 1 {:: x
  i =. keys i. <y
  if. i < #keys do. > (2 {:: x) {~ i else. jNull end.
}}
jStrVal =: {{
  if. 'str' -: > 0 { y do. > 1 { y else. '' end.
}}
jNumVal =: {{
  if. 'num' -: > 0 { y do. ". > 1 { y else. 0 end.
}}
jBoolVal =: {{
  if. 'bool' -: > 0 { y do. > 1 { y else. 0 end.
}}
jHas =: {{
  keys =. 1 {:: x
  (keys i. <y) < #keys
}}
NB. String coercion mirroring the reference ports: str -> text,
NB. num -> raw text, bool -> 'true'/'false', anything else -> ''.
jStrOf =: {{
  tag =. > 0 { y
  if. tag -: 'str' do. > 1 { y return. end.
  if. tag -: 'num' do. > 1 { y return. end.
  if. tag -: 'bool' do.
    if. > 1 { y do. 'true' else. 'false' end.
    return.
  end.
  ''
}}
jNumRaw =: {{
  if. 'num' -: > 0 { y do. > 1 { y else. '0' end.
}}
jArrVal =: {{
  if. 'arr' -: > 0 { y do. > 1 { y else. 0 $ <'' end.
}}

hexVal =: {{
  d =. '0123456789abcdefABCDEF' i. y
  d - 6 * d > 15
}}

NB. ---- parser: globals JSRC, JPOS, JERR ----
jSkipWs =: {{
  while. (JPOS < #JSRC) *. (JPOS { JSRC) e. ' ', 9 10 13 { a. do.
    JPOS =: JPOS + 1
  end.
  0
}}
jPeek =: {{
  if. JPOS < #JSRC do. JPOS { JSRC else. '' end.
}}
jParse =: {{
  JSRC =: y
  JPOS =: 0
  JERR =: 0
  jParseValue ''
}}
jParseValue =: {{
  jSkipWs ''
  ch =. jPeek ''
  if. ch = '{' do. jParseObj '' return. end.
  if. ch = '[' do. jParseArr '' return. end.
  if. ch = '"' do. jStr jParseStr '' return. end.
  if. ch = 't' do.
    if. 'true' -: 4 {. JPOS }. JSRC do.
      JPOS =: JPOS + 4
      jBool 1 return.
    end.
    JERR =: 1
    jNull return.
  end.
  if. ch = 'f' do.
    if. 'false' -: 5 {. JPOS }. JSRC do.
      JPOS =: JPOS + 5
      jBool 0 return.
    end.
    JERR =: 1
    jNull return.
  end.
  if. ch = 'n' do.
    if. 'null' -: 4 {. JPOS }. JSRC do.
      JPOS =: JPOS + 4
      jNull return.
    end.
    JERR =: 1
    jNull return.
  end.
  if. (ch e. '-0123456789') do. jParseNum '' return. end.
  JERR =: 1
  jNull
}}
jParseNum =: {{
  start =. JPOS
  ok =. '-+0123456789.eE'
  while. (JPOS < #JSRC) *. (JPOS { JSRC) e. ok do.
    JPOS =: JPOS + 1
  end.
  jNum (JPOS - start) {. start }. JSRC
}}
NB. Parses a string starting at the opening quote; returns raw text.
jParseStr =: {{
  JPOS =: JPOS + 1
  pieces =. 0 $ <''
  while. 1 do.
    if. JPOS >: #JSRC do.
      JERR =: 1
      '' return.
    end.
    rest =. JPOS }. JSRC
    stops =. I. rest e. '"\'
    if. 0 = #stops do.
      JERR =: 1
      '' return.
    end.
    k =. {. stops
    pieces =. pieces , < k {. rest
    ch =. (JPOS + k) { JSRC
    JPOS =: JPOS + k + 1
    if. ch = '"' do. ; pieces return. end.
    if. JPOS >: #JSRC do.
      JERR =: 1
      '' return.
    end.
    e =. JPOS { JSRC
    JPOS =: JPOS + 1
    if. e = 'n' do. pieces =. pieces , < (10 { a.) continue. end.
    if. e = 't' do. pieces =. pieces , < (9 { a.) continue. end.
    if. e = 'r' do. pieces =. pieces , < (13 { a.) continue. end.
    if. e = 'b' do. pieces =. pieces , < (8 { a.) continue. end.
    if. e = 'f' do. pieces =. pieces , < (12 { a.) continue. end.
    if. e = 'u' do.
      if. (JPOS + 4) > #JSRC do.
        JERR =: 1
        '' return.
      end.
      hex =. 4 {. JPOS }. JSRC
      if. -. */ hex e. '0123456789abcdefABCDEF' do.
        JERR =: 1
        '' return.
      end.
      hv =. 16 #. hexVal hex
      JPOS =: JPOS + 4
      if. (hv >: 55296) *. hv <: 56319 do.
        if. '\u' -: 2 {. JPOS }. JSRC do.
          hex2 =. 4 {. (JPOS + 2) }. JSRC
          if. */ hex2 e. '0123456789abcdefABCDEF' do.
            hv2 =. 16 #. hexVal hex2
            if. (hv2 >: 56320) *. hv2 <: 57343 do.
              hv =. 65536 + ((hv - 55296) * 1024) + hv2 - 56320
              JPOS =: JPOS + 6
            end.
          end.
        end.
      end.
      pieces =. pieces , < utf8enc hv
      continue.
    end.
    pieces =. pieces , <e
  end.
}}
utf8enc =: {{
  cp =. y
  if. cp < 128 do. cp { a. return. end.
  if. cp < 2048 do.
    (192 + <. cp % 64) , (128 + 64 | cp) { a. return.
  end.
  if. cp < 65536 do.
    (224 + <. cp % 4096) , (128 + 64 | <. cp % 64) , (128 + 64 | cp) { a. return.
  end.
  (240 + <. cp % 262144) , (128 + 64 | <. cp % 4096) , (128 + 64 | <. cp % 64) , (128 + 64 | cp) { a.
}}
jParseObj =: {{
  JPOS =: JPOS + 1
  keys =. 0 $ <''
  vals =. 0 $ <''
  jSkipWs ''
  if. (jPeek '') = '}' do.
    JPOS =: JPOS + 1
    keys jObj vals return.
  end.
  while. 1 do.
    jSkipWs ''
    if. (jPeek '') ~: '"' do.
      JERR =: 1
      jNull return.
    end.
    k =. jParseStr ''
    if. JERR do. jNull return. end.
    jSkipWs ''
    if. (jPeek '') ~: ':' do.
      JERR =: 1
      jNull return.
    end.
    JPOS =: JPOS + 1
    vv =. jParseValue ''
    if. JERR do. jNull return. end.
    keys =. keys , <k
    vals =. vals , <vv
    jSkipWs ''
    ch =. jPeek ''
    if. ch = ',' do.
      JPOS =: JPOS + 1
      continue.
    end.
    if. ch = '}' do.
      JPOS =: JPOS + 1
      keys jObj vals return.
    end.
    JERR =: 1
    jNull return.
  end.
}}
jParseArr =: {{
  JPOS =: JPOS + 1
  items =. 0 $ <''
  jSkipWs ''
  if. (jPeek '') = ']' do.
    JPOS =: JPOS + 1
    jArr items return.
  end.
  while. 1 do.
    vv =. jParseValue ''
    if. JERR do. jNull return. end.
    items =. items , <vv
    jSkipWs ''
    ch =. jPeek ''
    if. ch = ',' do.
      JPOS =: JPOS + 1
      continue.
    end.
    if. ch = ']' do.
      JPOS =: JPOS + 1
      jArr items return.
    end.
    JERR =: 1
    jNull return.
  end.
}}

NB. ---- canonical serializer ----
jQuote =: {{
  s =. y
  hexd =. '0123456789abcdef'
  pieces =. <'"'
  i =. 0
  while. i < #s do.
    ch =. i { s
    vv =. a. i. ch
    if. ch = '"' do. pieces =. pieces , <'\"'
    elseif. ch = '\' do. pieces =. pieces , <'\\'
    elseif. vv = 8 do. pieces =. pieces , <'\b'
    elseif. vv = 9 do. pieces =. pieces , <'\t'
    elseif. vv = 10 do. pieces =. pieces , <'\n'
    elseif. vv = 12 do. pieces =. pieces , <'\f'
    elseif. vv = 13 do. pieces =. pieces , <'\r'
    elseif. (vv < 32) +. vv >: 127 do.
      pieces =. pieces , < '\u00' , (hexd {~ <. vv % 16) , (hexd {~ 16 | vv)
    elseif. 1 do. pieces =. pieces , <ch
    end.
    i =. i + 1
  end.
  ; pieces , <'"'
}}
NB. For JSON-safe alphabets (base64, hex, coordinates).
jQuoteSafe =: {{ '"' , y , '"' }}
jCanon =: {{
  tag =. > 0 { y
  if. tag -: 'null' do. 'null' return. end.
  if. tag -: 'bool' do.
    if. > 1 { y do. 'true' else. 'false' end.
    return.
  end.
  if. tag -: 'num' do. > 1 { y return. end.
  if. tag -: 'str' do. jQuote > 1 { y return. end.
  if. tag -: 'arr' do.
    items =. > 1 { y
    '[' , (',' joinWith (jCanon each items)) , ']' return.
  end.
  if. tag -: 'obj' do.
    keys =. 1 {:: y
    vals =. 2 {:: y
    if. 0 = #keys do. '{}' return. end.
    codes =. > a.&i. each keys
    ord =. /: codes
    parts =. ''
    i =. 0
    ks =. ord { keys
    vs =. ord { vals
    while. i < #ks do.
      parts =. parts , < (jQuote > i { ks) , ':' , (jCanon > i { vs)
      i =. i + 1
    end.
    '{' , (',' joinWith parts) , '}' return.
  end.
  ''
}}
NB. Object builder helpers for responses.
jPair =: {{ (<'') , <y }} NB. placeholder (unused)
mkObj =: {{
  NB. y = flat boxed list: (<key) , (<node) , (<key) , (<node) ...
  keys =. 0 $ <''
  vals =. 0 $ <''
  i =. 0
  while. i < #y do.
    keys =. keys , < > i { y
    vals =. vals , < > (i + 1) { y
    i =. i + 2
  end.
  (< 'obj') , (<keys) , <vals
}}
