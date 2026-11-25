IMPLEMENTATION MODULE BStr;

FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM SYSTEM IMPORT ADDRESS, TSIZE;

TYPE
  CharArr = ARRAY [0..2000000000] OF CHAR;
  CharPtr = POINTER TO CharArr;
  BytesRec = RECORD
    len, cap : CARDINAL;
    data : CharPtr;
  END;
  Bytes = POINTER TO BytesRec;

PROCEDURE Ptr (b : Bytes) : CharPtr;
BEGIN
  RETURN b^.data;
END Ptr;

PROCEDURE DataAddr (b : Bytes) : ADDRESS;
BEGIN
  RETURN ADDRESS(b^.data);
END DataAddr;

PROCEDURE Ensure (b : Bytes; need : CARDINAL);
  VAR newcap : CARDINAL; nd : CharPtr; i : CARDINAL;
BEGIN
  IF need <= b^.cap THEN RETURN END;
  newcap := b^.cap;
  IF newcap = 0 THEN newcap := 64 END;
  WHILE newcap < need DO newcap := newcap * 2 END;
  ALLOCATE(nd, newcap);
  IF b^.data <> NIL THEN
    i := 0;
    WHILE i < b^.len DO
      nd^[i] := b^.data^[i];
      INC(i);
    END;
    DEALLOCATE(b^.data, b^.cap);
  END;
  b^.data := nd;
  b^.cap := newcap;
END Ensure;

PROCEDURE New () : Bytes;
  VAR b : Bytes;
BEGIN
  NEW(b);
  b^.len := 0; b^.cap := 0; b^.data := NIL;
  RETURN b;
END New;

PROCEDURE Dispose (VAR b : Bytes);
BEGIN
  IF b <> NIL THEN
    IF b^.data <> NIL THEN DEALLOCATE(b^.data, b^.cap) END;
    DISPOSE(b);
    b := NIL;
  END;
END Dispose;

PROCEDURE Clear (b : Bytes);
BEGIN
  b^.len := 0;
END Clear;

PROCEDURE Len (b : Bytes) : CARDINAL;
BEGIN
  RETURN b^.len;
END Len;

PROCEDURE Get (b : Bytes; i : CARDINAL) : CHAR;
BEGIN
  RETURN b^.data^[i];
END Get;

PROCEDURE Put (b : Bytes; i : CARDINAL; ch : CHAR);
BEGIN
  Ensure(b, i + 1);
  b^.data^[i] := ch;
  IF i >= b^.len THEN b^.len := i + 1 END;
END Put;

PROCEDURE AppendCh (b : Bytes; ch : CHAR);
BEGIN
  Ensure(b, b^.len + 1);
  b^.data^[b^.len] := ch;
  INC(b^.len);
END AppendCh;

PROCEDURE AppendMem (b : Bytes; a : ADDRESS; n : CARDINAL);
  VAR i : CARDINAL; src : CharPtr;
BEGIN
  IF n = 0 THEN RETURN END;
  Ensure(b, b^.len + n);
  src := CharPtr(a);
  i := 0;
  WHILE i < n DO
    b^.data^[b^.len + i] := src^[i];
    INC(i);
  END;
  INC(b^.len, n);
END AppendMem;

PROCEDURE AppendBytes (b : Bytes; s : Bytes);
BEGIN
  IF s <> NIL THEN AppendMem(b, s^.data, s^.len) END;
END AppendBytes;

PROCEDURE AppendStrN (b : Bytes; s : ARRAY OF CHAR; n : CARDINAL);
  VAR i : CARDINAL;
BEGIN
  i := 0;
  WHILE i < n DO AppendCh(b, s[i]); INC(i) END;
END AppendStrN;

PROCEDURE AppendStr (b : Bytes; s : ARRAY OF CHAR);
  VAR i : CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] <> 0C) DO
    AppendCh(b, s[i]);
    INC(i);
  END;
END AppendStr;

PROCEDURE Copy (s : Bytes) : Bytes;
  VAR b : Bytes;
BEGIN
  b := New();
  AppendBytes(b, s);
  RETURN b;
END Copy;

PROCEDURE FromStr (s : ARRAY OF CHAR) : Bytes;
  VAR b : Bytes;
BEGIN
  b := New();
  AppendStr(b, s);
  RETURN b;
END FromStr;

PROCEDURE EqualStr (a : Bytes; s : ARRAY OF CHAR) : BOOLEAN;
  VAR i : CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] <> 0C) DO
    IF (i >= a^.len) OR (Get(a, i) <> s[i]) THEN RETURN FALSE END;
    INC(i);
  END;
  RETURN i = a^.len;
END EqualStr;

PROCEDURE Equal (a, b : Bytes) : BOOLEAN;
  VAR i : CARDINAL;
BEGIN
  IF a^.len <> b^.len THEN RETURN FALSE END;
  i := 0;
  WHILE i < a^.len DO
    IF Get(a, i) <> Get(b, i) THEN RETURN FALSE END;
    INC(i);
  END;
  RETURN TRUE;
END Equal;

PROCEDURE Compare (a, b : Bytes) : INTEGER;
  VAR i, n : CARDINAL;
BEGIN
  n := a^.len;
  IF b^.len < n THEN n := b^.len END;
  i := 0;
  WHILE i < n DO
    IF ORD(Get(a, i)) < ORD(Get(b, i)) THEN RETURN -1 END;
    IF ORD(Get(a, i)) > ORD(Get(b, i)) THEN RETURN 1 END;
    INC(i);
  END;
  IF a^.len < b^.len THEN RETURN -1 END;
  IF a^.len > b^.len THEN RETURN 1 END;
  RETURN 0;
END Compare;

PROCEDURE AppendHexByte (out : Bytes; ch : CHAR);
  VAR v, d : CARDINAL;
BEGIN
  v := ORD(ch);
  d := v DIV 16;
  IF d < 10 THEN AppendCh(out, CHR(ORD('0') + d))
  ELSE AppendCh(out, CHR(ORD('a') + d - 10)) END;
  d := v MOD 16;
  IF d < 10 THEN AppendCh(out, CHR(ORD('0') + d))
  ELSE AppendCh(out, CHR(ORD('a') + d - 10)) END;
END AppendHexByte;

PROCEDURE AppendCardinal (out : Bytes; v : CARDINAL);
  VAR digits : ARRAY [0..19] OF CHAR; n, i : CARDINAL;
BEGIN
  IF v = 0 THEN AppendCh(out, '0'); RETURN END;
  n := 0;
  WHILE v > 0 DO
    digits[n] := CHR(ORD('0') + (v MOD 10));
    v := v DIV 10;
    INC(n);
  END;
  i := n;
  WHILE i > 0 DO
    DEC(i);
    AppendCh(out, digits[i]);
  END;
END AppendCardinal;

PROCEDURE ParseCardinal (b : Bytes; i : CARDINAL; VAR v : CARDINAL; VAR j : CARDINAL) : BOOLEAN;
  VAR start : CARDINAL; ch : CHAR;
BEGIN
  start := i;
  v := 0;
  j := i;
  WHILE (j < b^.len) AND (Get(b, j) >= '0') AND (Get(b, j) <= '9') DO
    v := v * 10 + (ORD(Get(b, j)) - ORD('0'));
    INC(j);
  END;
  RETURN j > start;
END ParseCardinal;

END BStr.
