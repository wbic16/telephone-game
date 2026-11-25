IMPLEMENTATION MODULE Json;

FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM SYSTEM IMPORT ADDRESS;
IMPORT BStr;
FROM BStr IMPORT Bytes;

CONST MaxNodes = 4000000;

TYPE
  JTypeArr = ARRAY [0..200000000] OF JType;
  JTypePtr = POINTER TO JTypeArr;
  BytesArr = ARRAY [0..200000000] OF Bytes;
  BytesPtr = POINTER TO BytesArr;
  CardArr = ARRAY [0..200000000] OF CARDINAL;
  CardPtr = POINTER TO CardArr;
  BoolArr = ARRAY [0..200000000] OF BOOLEAN;
  BoolPtr = POINTER TO BoolArr;

VAR
  nNodes, capNodes : CARDINAL;
  typ : JTypePtr;
  sval : BytesPtr;
  bval : BoolPtr;
  first : CardPtr;
  cnt : CardPtr;
  nPairs, capPairs : CARDINAL;
  pkey : BytesPtr;
  pval : CardPtr;
  pnext : CardPtr;

  src : Bytes;
  pos : CARDINAL;
  perr : BOOLEAN;

PROCEDURE GrowNodes (need : CARDINAL);
  VAR newcap, i : CARDINAL; nt : JTypePtr; ns : BytesPtr; nb : BoolPtr; nf, nc : CardPtr;
BEGIN
  IF need <= capNodes THEN RETURN END;
  newcap := capNodes;
  IF newcap = 0 THEN newcap := 256 END;
  WHILE newcap < need DO newcap := newcap * 2 END;
  ALLOCATE(nt, newcap * SIZE(JType));
  ALLOCATE(ns, newcap * SIZE(Bytes));
  ALLOCATE(nb, newcap * SIZE(BOOLEAN));
  ALLOCATE(nf, newcap * SIZE(CARDINAL));
  ALLOCATE(nc, newcap * SIZE(CARDINAL));
  IF typ <> NIL THEN
    FOR i := 0 TO nNodes DO
      nt^[i] := typ^[i];
      ns^[i] := sval^[i];
      nb^[i] := bval^[i];
      nf^[i] := first^[i];
      nc^[i] := cnt^[i];
    END;
  END;
  IF typ <> NIL THEN
    DEALLOCATE(typ, capNodes * SIZE(JType));
    DEALLOCATE(sval, capNodes * SIZE(Bytes));
    DEALLOCATE(bval, capNodes * SIZE(BOOLEAN));
    DEALLOCATE(first, capNodes * SIZE(CARDINAL));
    DEALLOCATE(cnt, capNodes * SIZE(CARDINAL));
  END;
  typ := nt; sval := ns; bval := nb; first := nf; cnt := nc;
  capNodes := newcap;
END GrowNodes;

PROCEDURE GrowPairs (need : CARDINAL);
  VAR newcap, i : CARDINAL; nk : BytesPtr; nv, nn : CardPtr;
BEGIN
  IF need <= capPairs THEN RETURN END;
  newcap := capPairs;
  IF newcap = 0 THEN newcap := 256 END;
  WHILE newcap < need DO newcap := newcap * 2 END;
  ALLOCATE(nk, newcap * SIZE(Bytes));
  ALLOCATE(nv, newcap * SIZE(CARDINAL));
  ALLOCATE(nn, newcap * SIZE(CARDINAL));
  IF pkey <> NIL THEN
    FOR i := 0 TO nPairs DO
      nk^[i] := pkey^[i];
      nv^[i] := pval^[i];
      nn^[i] := pnext^[i];
    END;
  END;
  IF pkey <> NIL THEN
    DEALLOCATE(pkey, capPairs * SIZE(Bytes));
    DEALLOCATE(pval, capPairs * SIZE(CARDINAL));
    DEALLOCATE(pnext, capPairs * SIZE(CARDINAL));
  END;
  pkey := nk; pval := nv; pnext := nn;
  capPairs := newcap;
END GrowPairs;

PROCEDURE NewNode (t : JType) : JVal;
BEGIN
  GrowNodes(nNodes + 2);
  INC(nNodes);
  typ^[nNodes] := t;
  sval^[nNodes] := NIL;
  bval^[nNodes] := FALSE;
  first^[nNodes] := 0;
  cnt^[nNodes] := 0;
  RETURN nNodes;
END NewNode;

PROCEDURE AddPair (v : JVal; key : Bytes; val : JVal);
  VAR p, last : CARDINAL;
BEGIN
  GrowPairs(nPairs + 2);
  INC(nPairs);
  p := nPairs;
  pkey^[p] := key;
  pval^[p] := val;
  pnext^[p] := 0;
  IF first^[v] = 0 THEN
    first^[v] := p;
  ELSE
    last := first^[v];
    WHILE pnext^[last] <> 0 DO last := pnext^[last] END;
    pnext^[last] := p;
  END;
  INC(cnt^[v]);
END AddPair;

(* ---------- accessors ---------- *)

PROCEDURE TypeOf (v : JVal) : JType;
BEGIN
  IF v = 0 THEN RETURN JNone END;
  RETURN typ^[v];
END TypeOf;

PROCEDURE IsNull (v : JVal) : BOOLEAN;
BEGIN
  RETURN (v = 0) OR (typ^[v] = JNull) OR (typ^[v] = JNone);
END IsNull;

PROCEDURE StrVal (v : JVal) : Bytes;
BEGIN
  IF (v = 0) OR (sval^[v] = NIL) THEN RETURN NIL END;
  RETURN sval^[v];
END StrVal;

PROCEDURE NumVal (v : JVal) : Bytes;
BEGIN
  RETURN StrVal(v);
END NumVal;

PROCEDURE IntVal (v : JVal) : LONGINT;
  VAR b : Bytes; i : CARDINAL; neg : BOOLEAN; r : LONGINT; ch : CHAR;
BEGIN
  b := StrVal(v);
  IF b = NIL THEN RETURN 0 END;
  r := 0; neg := FALSE; i := 0;
  IF (BStr.Len(b) > 0) AND (BStr.Get(b, 0) = '-') THEN neg := TRUE; i := 1 END;
  WHILE i < BStr.Len(b) DO
    ch := BStr.Get(b, i);
    IF (ch < '0') OR (ch > '9') THEN
      IF neg THEN RETURN -r ELSE RETURN r END;
    END;
    r := r * 10 + VAL(LONGINT, ORD(ch) - ORD('0'));
    INC(i);
  END;
  IF neg THEN RETURN -r ELSE RETURN r END;
END IntVal;

PROCEDURE BoolVal (v : JVal) : BOOLEAN;
BEGIN
  IF v = 0 THEN RETURN FALSE END;
  RETURN bval^[v];
END BoolVal;

PROCEDURE ArrLen (v : JVal) : CARDINAL;
BEGIN
  IF v = 0 THEN RETURN 0 END;
  RETURN cnt^[v];
END ArrLen;

PROCEDURE ObjLen (v : JVal) : CARDINAL;
BEGIN
  RETURN ArrLen(v);
END ObjLen;

PROCEDURE PairAt (v : JVal; i : CARDINAL) : CARDINAL;
  VAR p : CARDINAL;
BEGIN
  p := first^[v];
  WHILE i > 0 DO
    p := pnext^[p];
    DEC(i);
  END;
  RETURN p;
END PairAt;

PROCEDURE ArrItem (v : JVal; i : CARDINAL) : JVal;
BEGIN
  IF v = 0 THEN RETURN 0 END;
  RETURN pval^[PairAt(v, i)];
END ArrItem;

PROCEDURE ObjKey (v : JVal; i : CARDINAL) : Bytes;
BEGIN
  RETURN pkey^[PairAt(v, i)];
END ObjKey;

PROCEDURE ObjVal (v : JVal; i : CARDINAL) : JVal;
BEGIN
  RETURN ArrItem(v, i);
END ObjVal;

PROCEDURE GetB (v : JVal; key : Bytes) : JVal;
  VAR p : CARDINAL;
BEGIN
  IF (v = 0) OR (typ^[v] <> JObj) THEN RETURN 0 END;
  p := first^[v];
  WHILE p <> 0 DO
    IF BStr.Equal(pkey^[p], key) THEN RETURN pval^[p] END;
    p := pnext^[p];
  END;
  RETURN 0;
END GetB;

PROCEDURE Get (v : JVal; key : ARRAY OF CHAR) : JVal;
  VAR kb : Bytes; r : JVal;
BEGIN
  kb := BStr.FromStr(key);
  r := GetB(v, kb);
  BStr.Dispose(kb);
  RETURN r;
END Get;

(* ---------- parser ---------- *)

PROCEDURE SkipWs;
  VAR ch : CHAR;
BEGIN
  WHILE pos < BStr.Len(src) DO
    ch := BStr.Get(src, pos);
    IF (ch = ' ') OR (ch = CHR(9)) OR (ch = CHR(10)) OR (ch = CHR(13)) THEN INC(pos)
    ELSE RETURN END;
  END;
END SkipWs;

PROCEDURE Peek () : CHAR;
BEGIN
  IF pos >= BStr.Len(src) THEN RETURN 0C END;
  RETURN BStr.Get(src, pos);
END Peek;

PROCEDURE HexVal (ch : CHAR) : INTEGER;
BEGIN
  IF (ch >= '0') AND (ch <= '9') THEN RETURN INTEGER(ORD(ch) - ORD('0')) END;
  IF (ch >= 'a') AND (ch <= 'f') THEN RETURN INTEGER(ORD(ch) - ORD('a')) + 10 END;
  IF (ch >= 'A') AND (ch <= 'F') THEN RETURN INTEGER(ORD(ch) - ORD('A')) + 10 END;
  RETURN -1;
END HexVal;

PROCEDURE AppendUtf8 (out : Bytes; cp : CARDINAL);
BEGIN
  IF cp < 128 THEN
    BStr.AppendCh(out, CHR(cp));
  ELSIF cp < 2048 THEN
    BStr.AppendCh(out, CHR(192 + cp DIV 64));
    BStr.AppendCh(out, CHR(128 + cp MOD 64));
  ELSIF cp < 65536 THEN
    BStr.AppendCh(out, CHR(224 + cp DIV 4096));
    BStr.AppendCh(out, CHR(128 + (cp DIV 64) MOD 64));
    BStr.AppendCh(out, CHR(128 + cp MOD 64));
  ELSE
    BStr.AppendCh(out, CHR(240 + cp DIV 262144));
    BStr.AppendCh(out, CHR(128 + (cp DIV 4096) MOD 64));
    BStr.AppendCh(out, CHR(128 + (cp DIV 64) MOD 64));
    BStr.AppendCh(out, CHR(128 + cp MOD 64));
  END;
END AppendUtf8;

PROCEDURE ParseStringRaw () : Bytes;
  VAR out : Bytes; ch, e : CHAR; cp, lo : CARDINAL; i : CARDINAL;
      h : INTEGER;
BEGIN
  out := BStr.New();
  IF Peek() <> '"' THEN perr := TRUE; RETURN out END;
  INC(pos);
  WHILE pos < BStr.Len(src) DO
    ch := BStr.Get(src, pos);
    IF ch = '"' THEN
      INC(pos);
      RETURN out;
    ELSIF ch = '\' THEN
      INC(pos);
      IF pos >= BStr.Len(src) THEN perr := TRUE; RETURN out END;
      e := BStr.Get(src, pos);
      INC(pos);
      CASE e OF
        '"': BStr.AppendCh(out, '"')
      | '\': BStr.AppendCh(out, '\')
      | '/': BStr.AppendCh(out, '/')
      | 'b': BStr.AppendCh(out, CHR(8))
      | 'f': BStr.AppendCh(out, CHR(12))
      | 'n': BStr.AppendCh(out, CHR(10))
      | 'r': BStr.AppendCh(out, CHR(13))
      | 't': BStr.AppendCh(out, CHR(9))
      | 'u':
          cp := 0;
          FOR i := 1 TO 4 DO
            IF pos >= BStr.Len(src) THEN perr := TRUE; RETURN out END;
            h := HexVal(BStr.Get(src, pos));
            IF h < 0 THEN perr := TRUE; RETURN out END;
            cp := cp * 16 + CARDINAL(h);
            INC(pos);
          END;
          IF (cp >= 55296) AND (cp <= 56319) AND (pos + 1 < BStr.Len(src))
             AND (BStr.Get(src, pos) = '\') AND (BStr.Get(src, pos + 1) = 'u') THEN
            lo := 0;
            FOR i := 1 TO 4 DO
              h := HexVal(BStr.Get(src, pos + 1 + i));
              IF h < 0 THEN h := 0 END;
              lo := lo * 16 + CARDINAL(h);
            END;
            IF (lo >= 56320) AND (lo <= 57343) THEN
              cp := 65536 + (cp - 55296) * 1024 + (lo - 56320);
              INC(pos, 6);
            END;
          END;
          AppendUtf8(out, cp);
      ELSE
        perr := TRUE; RETURN out;
      END;
    ELSE
      BStr.AppendCh(out, ch);
      INC(pos);
    END;
  END;
  perr := TRUE;
  RETURN out;
END ParseStringRaw;

VAR parseHook : PROCEDURE () : JVal;

PROCEDURE HookValue () : JVal;
BEGIN
  RETURN parseHook();
END HookValue;

PROCEDURE ParseObject () : JVal;
  VAR v, item : JVal; key : Bytes;
BEGIN
  v := NewNode(JObj);
  INC(pos);  (* { *)
  SkipWs;
  IF Peek() = '}' THEN INC(pos); RETURN v END;
  LOOP
    SkipWs;
    key := ParseStringRaw();
    IF perr THEN RETURN v END;
    SkipWs;
    IF Peek() <> ':' THEN perr := TRUE; RETURN v END;
    INC(pos);
    item := HookValue();
    IF perr THEN RETURN v END;
    AddPair(v, key, item);
    SkipWs;
    IF Peek() = ',' THEN INC(pos)
    ELSIF Peek() = '}' THEN INC(pos); RETURN v
    ELSE perr := TRUE; RETURN v END;
  END;
END ParseObject;

PROCEDURE ParseArray () : JVal;
  VAR v, item : JVal;
BEGIN
  v := NewNode(JArr);
  INC(pos);  (* [ *)
  SkipWs;
  IF Peek() = ']' THEN INC(pos); RETURN v END;
  LOOP
    item := HookValue();
    IF perr THEN RETURN v END;
    AddPair(v, NIL, item);
    SkipWs;
    IF Peek() = ',' THEN INC(pos)
    ELSIF Peek() = ']' THEN INC(pos); RETURN v
    ELSE perr := TRUE; RETURN v END;
  END;
END ParseArray;

PROCEDURE ParseValue () : JVal;
  VAR v : JVal; i : CARDINAL; lit : Bytes;
BEGIN
  SkipWs;
  IF pos >= BStr.Len(src) THEN perr := TRUE; RETURN 0 END;
  CASE Peek() OF
    '{': RETURN ParseObject()
  | '[': RETURN ParseArray()
  | '"':
      v := NewNode(JStr);
      sval^[v] := ParseStringRaw();
      RETURN v;
  | 't':
      IF (pos + 3 < BStr.Len(src)) AND (BStr.Get(src, pos + 1) = 'r')
         AND (BStr.Get(src, pos + 2) = 'u') AND (BStr.Get(src, pos + 3) = 'e') THEN
        INC(pos, 4);
        v := NewNode(JBool);
        bval^[v] := TRUE;
        RETURN v;
      END;
      perr := TRUE; RETURN 0;
  | 'f':
      IF (pos + 4 < BStr.Len(src)) AND (BStr.Get(src, pos + 1) = 'a')
         AND (BStr.Get(src, pos + 2) = 'l') AND (BStr.Get(src, pos + 3) = 's')
         AND (BStr.Get(src, pos + 4) = 'e') THEN
        INC(pos, 5);
        v := NewNode(JBool);
        bval^[v] := FALSE;
        RETURN v;
      END;
      perr := TRUE; RETURN 0;
  | 'n':
      IF (pos + 3 < BStr.Len(src)) AND (BStr.Get(src, pos + 1) = 'u')
         AND (BStr.Get(src, pos + 2) = 'l') AND (BStr.Get(src, pos + 3) = 'l') THEN
        INC(pos, 4);
        RETURN NewNode(JNull);
      END;
      perr := TRUE; RETURN 0;
  ELSE
      (* number *)
      v := NewNode(JNum);
      lit := BStr.New();
      WHILE pos < BStr.Len(src) DO
        IF ((BStr.Get(src, pos) >= '0') AND (BStr.Get(src, pos) <= '9'))
           OR (BStr.Get(src, pos) = '-') OR (BStr.Get(src, pos) = '+')
           OR (BStr.Get(src, pos) = '.') OR (BStr.Get(src, pos) = 'e')
           OR (BStr.Get(src, pos) = 'E') THEN
          BStr.AppendCh(lit, BStr.Get(src, pos));
          INC(pos);
        ELSE
          sval^[v] := lit;
          RETURN v;
        END;
      END;
      sval^[v] := lit;
      RETURN v;
  END;
END ParseValue;

PROCEDURE Parse (s : Bytes; VAR ok : BOOLEAN) : JVal;
  VAR v : JVal;
BEGIN
  src := s;
  pos := 0;
  perr := FALSE;
  nNodes := 0;
  nPairs := 0;
  (* node 0: the null node *)
  GrowNodes(2);
  nNodes := 0;
  typ^[0] := JNone;
  sval^[0] := NIL;
  bval^[0] := FALSE;
  first^[0] := 0;
  cnt^[0] := 0;
  v := ParseValue();
  SkipWs;
  ok := NOT perr;
  RETURN v;
END Parse;

(* ---------- canonical serializer ---------- *)

PROCEDURE Quote (s : Bytes; out : Bytes);
  VAR i : CARDINAL; ch : CHAR; v : CARDINAL;
BEGIN
  BStr.AppendCh(out, '"');
  i := 0;
  WHILE i < BStr.Len(s) DO
    ch := BStr.Get(s, i);
    v := ORD(ch);
    IF ch = '"' THEN BStr.AppendStr(out, '\"')
    ELSIF ch = '\' THEN BStr.AppendStr(out, '\\')
    ELSIF v = 8 THEN BStr.AppendStr(out, '\b')
    ELSIF v = 9 THEN BStr.AppendStr(out, '\t')
    ELSIF v = 10 THEN BStr.AppendStr(out, '\n')
    ELSIF v = 12 THEN BStr.AppendStr(out, '\f')
    ELSIF v = 13 THEN BStr.AppendStr(out, '\r')
    ELSIF (v < 32) OR (v >= 127) THEN
      BStr.AppendStr(out, '\u00');
      BStr.AppendHexByte(out, ch);
    ELSE
      BStr.AppendCh(out, ch);
    END;
    INC(i);
  END;
  BStr.AppendCh(out, '"');
END Quote;

PROCEDURE QuoteStr (s : ARRAY OF CHAR; out : Bytes);
  VAR b : Bytes;
BEGIN
  b := BStr.FromStr(s);
  Quote(b, out);
  BStr.Dispose(b);
END QuoteStr;

PROCEDURE NumCanon (raw : Bytes; out : Bytes);
  (* Game data is integer-only; emit the raw token. (Floats would be
     normalized by Python; the wire protocol uses integers.) *)
BEGIN
  BStr.AppendBytes(out, raw);
END NumCanon;

PROCEDURE Canon (v : JVal; out : Bytes);
  VAR i, j, p : CARDINAL; order : CardPtr; idx : CARDINAL;
BEGIN
  IF v = 0 THEN BStr.AppendStr(out, 'null'); RETURN END;
  CASE typ^[v] OF
    JNull, JNone: BStr.AppendStr(out, 'null')
  | JBool:
      IF bval^[v] THEN BStr.AppendStr(out, 'true')
      ELSE BStr.AppendStr(out, 'false') END;
  | JNum: NumCanon(sval^[v], out)
  | JStr: Quote(sval^[v], out)
  | JArr:
      BStr.AppendCh(out, '[');
      i := 0;
      WHILE i < cnt^[v] DO
        IF i > 0 THEN BStr.AppendCh(out, ',') END;
        Canon(ArrItem(v, i), out);
        INC(i);
      END;
      BStr.AppendCh(out, ']');
  | JObj:
      (* collect pair indices, sort by key bytes *)
      ALLOCATE(order, (cnt^[v] + 1) * SIZE(CARDINAL));
      p := first^[v];
      i := 0;
      WHILE p <> 0 DO
        order^[i] := p;
        INC(i);
        p := pnext^[p];
      END;
      (* insertion sort by key *)
      i := 1;
      WHILE i < cnt^[v] DO
        idx := order^[i];
        j := i;
        WHILE (j > 0) AND (BStr.Compare(pkey^[order^[j - 1]],
                                         pkey^[idx]) > 0) DO
          order^[j] := order^[j - 1];
          DEC(j);
        END;
        order^[j] := idx;
        INC(i);
      END;
      BStr.AppendCh(out, '{');
      i := 0;
      WHILE i < cnt^[v] DO
        IF i > 0 THEN BStr.AppendCh(out, ',') END;
        p := order^[i];
        Quote(pkey^[p], out);
        BStr.AppendCh(out, ':');
        Canon(pval^[p], out);
        INC(i);
      END;
      BStr.AppendCh(out, '}');
      DEALLOCATE(order, (cnt^[v] + 1) * SIZE(CARDINAL));
  END;
END Canon;

BEGIN
  nNodes := 0; capNodes := 0;
  typ := NIL; sval := NIL; bval := NIL; first := NIL; cnt := NIL;
  nPairs := 0; capPairs := 0;
  pkey := NIL; pval := NIL; pnext := NIL;
  src := NIL; pos := 0; perr := FALSE;
  parseHook := ParseValue;
END Json.
