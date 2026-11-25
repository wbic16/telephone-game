IMPLEMENTATION MODULE Phext;

FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM SYSTEM IMPORT ADDRESS;
IMPORT BStr;
FROM BStr IMPORT Bytes;

TYPE
  CoordArr = ARRAY [0..200000000] OF Coord;
  CoordPtr = POINTER TO CoordArr;
  BytesArr = ARRAY [0..200000000] OF Bytes;
  BytesPtr = POINTER TO BytesArr;

  Node = POINTER TO NodeRec;
  NodeRec = RECORD
    n, cap : CARDINAL;
    keys : CardPtr;
    kids : NodePtr;
    text : Bytes;
    has : BOOLEAN;
  END;
  CardArr = ARRAY [0..200000000] OF CARDINAL;
  CardPtr = POINTER TO CardArr;
  NodeArr = ARRAY [0..200000000] OF Node;
  NodePtr = POINTER TO NodeArr;

  Map = POINTER TO MapRec;
  DynStore = POINTER TO DynRec;
  TrnStore = POINTER TO TrnRec;
  MapRec = RECORD
    n, cap : CARDINAL;
    coords : CoordPtr;
    texts : BytesPtr;
  END;
  DynRec = RECORD
    n, cap : CARDINAL;
    resizeCount, copied : CARDINAL;
    coords : CoordPtr;
    texts : BytesPtr;
  END;
  TrnRec = RECORD
    root : Node;
    count : CARDINAL;
  END;

VAR
  BrkDim : ARRAY [0..255] OF INTEGER;

PROCEDURE InitBreaks;
  VAR i : INTEGER;
BEGIN
  FOR i := 0 TO 255 DO BrkDim[i] := -1 END;
  BrkDim[1] := 0;    (* library *)
  BrkDim[31] := 1;   (* shelf *)
  BrkDim[30] := 2;   (* series *)
  BrkDim[29] := 3;   (* collection *)
  BrkDim[28] := 4;   (* volume *)
  BrkDim[26] := 5;   (* book *)
  BrkDim[25] := 6;   (* chapter *)
  BrkDim[24] := 7;   (* section *)
  BrkDim[23] := 8;   (* scroll *)
END InitBreaks;

PROCEDURE BreakByte (d : CARDINAL) : CHAR;
BEGIN
  CASE d OF
    0: RETURN CHR(1)
  | 1: RETURN CHR(31)
  | 2: RETURN CHR(30)
  | 3: RETURN CHR(29)
  | 4: RETURN CHR(28)
  | 5: RETURN CHR(26)
  | 6: RETURN CHR(25)
  | 7: RETURN CHR(24)
  ELSE RETURN CHR(23)
  END;
END BreakByte;

(* ---------- coordinates ---------- *)

PROCEDURE CoordCmp (a, b : Coord) : INTEGER;
  VAR i : CARDINAL;
BEGIN
  FOR i := 0 TO 8 DO
    IF a[i] < b[i] THEN RETURN -1 END;
    IF a[i] > b[i] THEN RETURN 1 END;
  END;
  RETURN 0;
END CoordCmp;

PROCEDURE CoordEq (a, b : Coord) : BOOLEAN;
BEGIN
  RETURN CoordCmp(a, b) = 0;
END CoordEq;

PROCEDURE CoordParse (s : Bytes; VAR c : Coord) : BOOLEAN;
  VAR part : ARRAY [0..2] OF Bytes; np, i, j, k : CARDINAL;
      comp : ARRAY [0..2] OF CARDINAL; started : ARRAY [0..2] OF BOOLEAN;
      ch : CHAR;
BEGIN
  FOR i := 0 TO 8 DO c[i] := 1 END;
  np := 0;
  part[0] := BStr.New();
  i := 0;
  WHILE i < BStr.Len(s) DO
    ch := BStr.Get(s, i);
    IF ch = '/' THEN
      INC(np);
      IF np > 2 THEN
        FOR k := 0 TO 2 DO BStr.Dispose(part[k]) END;
        RETURN FALSE;
      END;
      part[np] := BStr.New();
    ELSE
      BStr.AppendCh(part[np], ch);
    END;
    INC(i);
  END;
  FOR i := 0 TO np DO
    comp[0] := 1; comp[1] := 1; comp[2] := 1;
    started[0] := FALSE; started[1] := FALSE; started[2] := FALSE;
    j := 0;
    k := 0;
    WHILE k < BStr.Len(part[i]) DO
      ch := BStr.Get(part[i], k);
      IF ch = '.' THEN
        INC(j);
        IF j > 2 THEN
          FOR k := 0 TO np DO BStr.Dispose(part[k]) END;
          RETURN FALSE;
        END;
      ELSIF (ch >= '0') AND (ch <= '9') THEN
        IF started[j] THEN comp[j] := comp[j] * 10 + (ORD(ch) - ORD('0'))
        ELSE comp[j] := ORD(ch) - ORD('0'); started[j] := TRUE END;
      ELSE
        FOR k := 0 TO np DO BStr.Dispose(part[k]) END;
        RETURN FALSE;
      END;
      INC(k);
    END;
    c[i * 3 + 0] := comp[0];
    c[i * 3 + 1] := comp[1];
    c[i * 3 + 2] := comp[2];
    BStr.Dispose(part[i]);
  END;
  RETURN TRUE;
END CoordParse;

PROCEDURE CoordParseStr (s : ARRAY OF CHAR; VAR c : Coord) : BOOLEAN;
  VAR b : Bytes; ok : BOOLEAN;
BEGIN
  b := BStr.FromStr(s);
  ok := CoordParse(b, c);
  BStr.Dispose(b);
  RETURN ok;
END CoordParseStr;

PROCEDURE CoordToBytes (c : Coord; out : Bytes);
  VAR g, i : CARDINAL;
BEGIN
  FOR g := 0 TO 2 DO
    IF g > 0 THEN BStr.AppendCh(out, '/') END;
    FOR i := 0 TO 2 DO
      IF i > 0 THEN BStr.AppendCh(out, '.') END;
      BStr.AppendCardinal(out, c[g * 3 + i]);
    END;
  END;
END CoordToBytes;

PROCEDURE CoordStr (c : Coord) : Bytes;
  VAR b : Bytes;
BEGIN
  b := BStr.New();
  CoordToBytes(c, b);
  RETURN b;
END CoordStr;

(* ---------- ordered map ---------- *)

PROCEDURE GrowMap (m : Map; need : CARDINAL);
  VAR newcap, i : CARDINAL; nc : CoordPtr; nt : BytesPtr;
BEGIN
  IF need <= m^.cap THEN RETURN END;
  newcap := m^.cap;
  IF newcap = 0 THEN newcap := 8 END;
  WHILE newcap < need DO newcap := newcap * 2 END;
  ALLOCATE(nc, newcap * SIZE(Coord));
  ALLOCATE(nt, newcap * SIZE(Bytes));
  i := 0;
  WHILE i < m^.n DO
    nc^[i] := m^.coords^[i];
    nt^[i] := m^.texts^[i];
    INC(i);
  END;
  IF m^.coords <> NIL THEN DEALLOCATE(m^.coords, m^.cap * SIZE(Coord)) END;
  IF m^.texts <> NIL THEN DEALLOCATE(m^.texts, m^.cap * SIZE(Bytes)) END;
  m^.coords := nc; m^.texts := nt; m^.cap := newcap;
END GrowMap;

PROCEDURE NewMap () : Map;
  VAR m : Map;
BEGIN
  NEW(m);
  m^.n := 0; m^.cap := 0; m^.coords := NIL; m^.texts := NIL;
  RETURN m;
END NewMap;

PROCEDURE DisposeMap (VAR m : Map);
  VAR i : CARDINAL; t : Bytes;
BEGIN
  IF m <> NIL THEN
    i := 0;
    WHILE i < m^.n DO
      t := m^.texts^[i];
      BStr.Dispose(t);
      INC(i);
    END;
    IF m^.coords <> NIL THEN DEALLOCATE(m^.coords, m^.cap * SIZE(Coord)) END;
    IF m^.texts <> NIL THEN DEALLOCATE(m^.texts, m^.cap * SIZE(Bytes)) END;
    DISPOSE(m);
    m := NIL;
  END;
END DisposeMap;

PROCEDURE MapCount (m : Map) : CARDINAL;
BEGIN RETURN m^.n END MapCount;

PROCEDURE MapCoordAt (m : Map; i : CARDINAL; VAR c : Coord);
BEGIN c := m^.coords^[i] END MapCoordAt;

PROCEDURE MapTextAt (m : Map; i : CARDINAL) : Bytes;
BEGIN RETURN m^.texts^[i] END MapTextAt;

PROCEDURE MapFind (m : Map; c : Coord) : INTEGER;
  VAR lo, hi, mid : CARDINAL; cmp : INTEGER;
BEGIN
  lo := 0; hi := m^.n;
  WHILE lo < hi DO
    mid := (lo + hi) DIV 2;
    cmp := CoordCmp(m^.coords^[mid], c);
    IF cmp = 0 THEN RETURN INTEGER(mid) END;
    IF cmp < 0 THEN lo := mid + 1 ELSE hi := mid END;
  END;
  RETURN -1;
END MapFind;

PROCEDURE MapFetch (m : Map; c : Coord) : Bytes;
  VAR idx : INTEGER;
BEGIN
  idx := MapFind(m, c);
  IF idx < 0 THEN RETURN NIL END;
  RETURN m^.texts^[CARDINAL(idx)];
END MapFetch;

PROCEDURE MapDeleteAt (m : Map; idx : CARDINAL);
  VAR i : CARDINAL; t : Bytes;
BEGIN
  t := m^.texts^[idx];
  BStr.Dispose(t);
  i := idx;
  WHILE i + 1 < m^.n DO
    m^.coords^[i] := m^.coords^[i + 1];
    m^.texts^[i] := m^.texts^[i + 1];
    INC(i);
  END;
  DEC(m^.n);
END MapDeleteAt;

PROCEDURE MapUpdate (m : Map; c : Coord; text : Bytes; overwrite : BOOLEAN);
  VAR lo, hi, mid, at : CARDINAL; cmp : INTEGER; old, joined : Bytes;
BEGIN
  lo := 0; hi := m^.n;
  WHILE lo < hi DO
    mid := (lo + hi) DIV 2;
    cmp := CoordCmp(m^.coords^[mid], c);
    IF cmp = 0 THEN
      at := mid;
      IF overwrite THEN
        IF BStr.Len(text) = 0 THEN MapDeleteAt(m, at); RETURN END;
        old := m^.texts^[at];
        BStr.Dispose(old);
        m^.texts^[at] := BStr.Copy(text);
      ELSE
        IF BStr.Len(text) = 0 THEN RETURN END;
        joined := BStr.Copy(m^.texts^[at]);
        BStr.AppendBytes(joined, text);
        old := m^.texts^[at];
        BStr.Dispose(old);
        m^.texts^[at] := joined;
      END;
      RETURN;
    END;
    IF cmp < 0 THEN lo := mid + 1 ELSE hi := mid END;
  END;
  (* insert new at lo *)
  IF BStr.Len(text) = 0 THEN RETURN END;
  GrowMap(m, m^.n + 1);
  at := m^.n;
  WHILE at > lo DO
    m^.coords^[at] := m^.coords^[at - 1];
    m^.texts^[at] := m^.texts^[at - 1];
    DEC(at);
  END;
  m^.coords^[lo] := c;
  m^.texts^[lo] := BStr.Copy(text);
  INC(m^.n);
END MapUpdate;

(* ---------- explode / implode ---------- *)

PROCEDURE Explode (data : Bytes; m : Map);
  VAR c : Coord; i, d : CARDINAL; cur : Bytes; ch : CHAR;
      dim : INTEGER; any : BOOLEAN;
BEGIN
  m^.n := 0;
  FOR i := 0 TO 8 DO c[i] := 1 END;
  cur := BStr.New();
  any := FALSE;
  i := 0;
  WHILE i < BStr.Len(data) DO
    ch := BStr.Get(data, i);
    dim := BrkDim[ORD(ch)];
    IF dim >= 0 THEN
      IF BStr.Len(cur) > 0 THEN
        MapUpdate(m, c, cur, TRUE);
        BStr.Clear(cur);
      END;
      d := CARDINAL(dim);
      c[d] := c[d] + 1;
      FOR d := CARDINAL(dim) + 1 TO 8 DO c[d] := 1 END;
      any := TRUE;
    ELSE
      BStr.AppendCh(cur, ch);
    END;
    INC(i);
  END;
  IF BStr.Len(cur) > 0 THEN MapUpdate(m, c, cur, TRUE) END;
  BStr.Dispose(cur);
END Explode;

PROCEDURE Implode (m : Map; out : Bytes);
  VAR prev : Coord; i, d, f, reps, r : CARDINAL; c : Coord;
BEGIN
  FOR i := 0 TO 8 DO prev[i] := 1 END;
  i := 0;
  WHILE i < m^.n DO
    MapCoordAt(m, i, c);
    IF CoordCmp(prev, c) < 0 THEN
      f := 0;
      WHILE (f <= 8) AND (c[f] = prev[f]) DO INC(f) END;
      IF f <= 8 THEN
        reps := c[f] - prev[f];
        FOR r := 1 TO reps DO BStr.AppendCh(out, BreakByte(f)) END;
        FOR d := f + 1 TO 8 DO
          reps := c[d] - 1;
          FOR r := 1 TO reps DO BStr.AppendCh(out, BreakByte(d)) END;
        END;
      END;
    END;
    BStr.AppendBytes(out, MapTextAt(m, i));
    prev := c;
    INC(i);
  END;
END Implode;

(* ---------- buffer API ---------- *)

PROCEDURE WithMap (data : Bytes; c : Coord; text : Bytes; mode : CARDINAL) : Bytes;
  VAR m : Map; out : Bytes;
BEGIN
  m := NewMap();
  Explode(data, m);
  IF mode = 0 THEN MapUpdate(m, c, text, FALSE)
  ELSIF mode = 1 THEN MapUpdate(m, c, text, TRUE)
  ELSE MapUpdate(m, c, text, TRUE)  (* remove/normalize use replace "" *)
  END;
  IF mode = 3 THEN
    (* normalize: explode already dropped empties; just implode *)
  END;
  out := BStr.New();
  Implode(m, out);
  DisposeMap(m);
  RETURN out;
END WithMap;

PROCEDURE Fetch (data : Bytes; c : Coord) : Bytes;
  VAR m : Map; t : Bytes; out : Bytes;
BEGIN
  m := NewMap();
  Explode(data, m);
  t := MapFetch(m, c);
  IF t = NIL THEN out := BStr.New() ELSE out := BStr.Copy(t) END;
  DisposeMap(m);
  RETURN out;
END Fetch;

PROCEDURE Insert (data : Bytes; c : Coord; text : Bytes) : Bytes;
BEGIN RETURN WithMap(data, c, text, 0) END Insert;

PROCEDURE Replace (data : Bytes; c : Coord; text : Bytes) : Bytes;
BEGIN RETURN WithMap(data, c, text, 1) END Replace;

PROCEDURE Remove (data : Bytes; c : Coord) : Bytes;
  VAR empty : Bytes; r : Bytes;
BEGIN
  empty := BStr.New();
  r := WithMap(data, c, empty, 1);
  BStr.Dispose(empty);
  RETURN r;
END Remove;

PROCEDURE Normalize (data : Bytes) : Bytes;
  VAR m : Map; out : Bytes;
BEGIN
  m := NewMap();
  Explode(data, m);
  out := BStr.New();
  Implode(m, out);
  DisposeMap(m);
  RETURN out;
END Normalize;

(* ---------- DynamicPhext ---------- *)

PROCEDURE DynResize (d : DynStore; newcap : CARDINAL);
  VAR nc : CoordPtr; nt : BytesPtr; i : CARDINAL;
BEGIN
  ALLOCATE(nc, newcap * SIZE(Coord));
  ALLOCATE(nt, newcap * SIZE(Bytes));
  i := 0;
  WHILE i < d^.n DO
    nc^[i] := d^.coords^[i];
    nt^[i] := d^.texts^[i];
    INC(i);
  END;
  INC(d^.copied, d^.n);
  INC(d^.resizeCount);
  IF d^.coords <> NIL THEN DEALLOCATE(d^.coords, d^.cap * SIZE(Coord)) END;
  IF d^.texts <> NIL THEN DEALLOCATE(d^.texts, d^.cap * SIZE(Bytes)) END;
  d^.coords := nc; d^.texts := nt; d^.cap := newcap;
END DynResize;

PROCEDURE DynNew () : DynStore;
  VAR d : DynStore;
BEGIN
  NEW(d);
  d^.n := 0; d^.cap := 0; d^.resizeCount := 0; d^.copied := 0;
  d^.coords := NIL; d^.texts := NIL;
  RETURN d;
END DynNew;

PROCEDURE DynDispose (VAR d : DynStore);
  VAR i : CARDINAL; t : Bytes;
BEGIN
  IF d <> NIL THEN
    i := 0;
    WHILE i < d^.n DO
      t := d^.texts^[i];
      BStr.Dispose(t);
      INC(i);
    END;
    IF d^.coords <> NIL THEN DEALLOCATE(d^.coords, d^.cap * SIZE(Coord)) END;
    IF d^.texts <> NIL THEN DEALLOCATE(d^.texts, d^.cap * SIZE(Bytes)) END;
    DISPOSE(d);
    d := NIL;
  END;
END DynDispose;

PROCEDURE DynFind (d : DynStore; c : Coord) : INTEGER;
  VAR lo, hi, mid : CARDINAL; cmp : INTEGER;
BEGIN
  lo := 0; hi := d^.n;
  WHILE lo < hi DO
    mid := (lo + hi) DIV 2;
    cmp := CoordCmp(d^.coords^[mid], c);
    IF cmp = 0 THEN RETURN INTEGER(mid) END;
    IF cmp < 0 THEN lo := mid + 1 ELSE hi := mid END;
  END;
  RETURN -1;
END DynFind;

PROCEDURE DynMaybeShrink (d : DynStore);
BEGIN
  IF (d^.cap >= 8) AND (d^.n <= d^.cap DIV 4) THEN
    DynResize(d, d^.cap DIV 2);
  END;
END DynMaybeShrink;

PROCEDURE DynUpdate (d : DynStore; c : Coord; text : Bytes; overwrite : BOOLEAN);
  VAR lo, hi, mid, at : CARDINAL; cmp : INTEGER; old, joined : Bytes;
BEGIN
  lo := 0; hi := d^.n;
  WHILE lo < hi DO
    mid := (lo + hi) DIV 2;
    cmp := CoordCmp(d^.coords^[mid], c);
    IF cmp = 0 THEN
      at := mid;
      IF overwrite THEN
        IF BStr.Len(text) = 0 THEN
          old := d^.texts^[at];
          BStr.Dispose(old);
          WHILE at < d^.n - 1 DO
            d^.coords^[at] := d^.coords^[at + 1];
            d^.texts^[at] := d^.texts^[at + 1];
            INC(at);
          END;
          DEC(d^.n);
          DynMaybeShrink(d);
          RETURN;
        END;
        old := d^.texts^[at];
        BStr.Dispose(old);
        d^.texts^[at] := BStr.Copy(text);
      ELSE
        IF BStr.Len(text) = 0 THEN RETURN END;
        joined := BStr.Copy(d^.texts^[at]);
        BStr.AppendBytes(joined, text);
        old := d^.texts^[at];
        BStr.Dispose(old);
        d^.texts^[at] := joined;
      END;
      RETURN;
    END;
    IF cmp < 0 THEN lo := mid + 1 ELSE hi := mid END;
  END;
  IF BStr.Len(text) = 0 THEN RETURN END;
  IF d^.n = d^.cap THEN
    IF d^.cap = 0 THEN DynResize(d, 1) ELSE DynResize(d, d^.cap * 2) END;
  END;
  at := d^.n;
  WHILE at > lo DO
    d^.coords^[at] := d^.coords^[at - 1];
    d^.texts^[at] := d^.texts^[at - 1];
    DEC(at);
  END;
  d^.coords^[lo] := c;
  d^.texts^[lo] := BStr.Copy(text);
  INC(d^.n);
END DynUpdate;

PROCEDURE DynFetch (d : DynStore; c : Coord) : Bytes;
  VAR idx : INTEGER;
BEGIN
  idx := DynFind(d, c);
  IF idx < 0 THEN RETURN NIL END;
  RETURN d^.texts^[CARDINAL(idx)];
END DynFetch;

PROCEDURE DynLen (d : DynStore) : CARDINAL;
BEGIN RETURN d^.n END DynLen;

PROCEDURE DynSerialize (d : DynStore; out : Bytes);
  VAR m : Map; i : CARDINAL; c : Coord;
BEGIN
  m := NewMap();
  i := 0;
  WHILE i < d^.n DO
    c := d^.coords^[i];
    MapUpdate(m, c, d^.texts^[i], TRUE);
    INC(i);
  END;
  Implode(m, out);
  DisposeMap(m);
END DynSerialize;

(* ---------- TransitivePhext ---------- *)

PROCEDURE NewNode () : Node;
  VAR n : Node;
BEGIN
  NEW(n);
  n^.n := 0; n^.cap := 0; n^.keys := NIL; n^.kids := NIL;
  n^.text := NIL; n^.has := FALSE;
  RETURN n;
END NewNode;

PROCEDURE DisposeNode (n : Node);
  VAR i : CARDINAL;
BEGIN
  IF n = NIL THEN RETURN END;
  i := 0;
  WHILE i < n^.n DO DisposeNode(n^.kids^[i]); INC(i) END;
  IF n^.keys <> NIL THEN DEALLOCATE(n^.keys, n^.cap * SIZE(CARDINAL)) END;
  IF n^.kids <> NIL THEN DEALLOCATE(n^.kids, n^.cap * SIZE(Node)) END;
  IF n^.text <> NIL THEN BStr.Dispose(n^.text) END;
  DISPOSE(n);
END DisposeNode;

PROCEDURE NodeChild (n : Node; key : CARDINAL; create : BOOLEAN) : Node;
  VAR lo, hi, mid, at, newcap, i : CARDINAL; cmp : INTEGER;
      nk : CardPtr; nd : NodePtr;
BEGIN
  lo := 0; hi := n^.n;
  WHILE lo < hi DO
    mid := (lo + hi) DIV 2;
    IF n^.keys^[mid] = key THEN RETURN n^.kids^[mid] END;
    IF n^.keys^[mid] < key THEN lo := mid + 1 ELSE hi := mid END;
  END;
  IF NOT create THEN RETURN NIL END;
  IF n^.n = n^.cap THEN
    newcap := n^.cap * 2;
    IF newcap = 0 THEN newcap := 4 END;
    ALLOCATE(nk, newcap * SIZE(CARDINAL));
    ALLOCATE(nd, newcap * SIZE(Node));
    i := 0;
    WHILE i < n^.n DO
      nk^[i] := n^.keys^[i];
      nd^[i] := n^.kids^[i];
      INC(i);
    END;
    IF n^.keys <> NIL THEN DEALLOCATE(n^.keys, n^.cap * SIZE(CARDINAL)) END;
    IF n^.kids <> NIL THEN DEALLOCATE(n^.kids, n^.cap * SIZE(Node)) END;
    n^.keys := nk; n^.kids := nd; n^.cap := newcap;
  END;
  at := n^.n;
  WHILE at > lo DO
    n^.keys^[at] := n^.keys^[at - 1];
    n^.kids^[at] := n^.kids^[at - 1];
    DEC(at);
  END;
  n^.keys^[lo] := key;
  n^.kids^[lo] := NewNode();
  INC(n^.n);
  RETURN n^.kids^[lo];
END NodeChild;

PROCEDURE TrnNew () : TrnStore;
  VAR t : TrnStore;
BEGIN
  NEW(t);
  t^.root := NewNode();
  t^.count := 0;
  RETURN t;
END TrnNew;

PROCEDURE TrnDispose (VAR t : TrnStore);
BEGIN
  IF t <> NIL THEN
    DisposeNode(t^.root);
    DISPOSE(t);
    t := NIL;
  END;
END TrnDispose;

PROCEDURE TrnWalk (t : TrnStore; c : Coord; create : BOOLEAN) : Node;
  VAR n : Node; d : CARDINAL;
BEGIN
  n := t^.root;
  FOR d := 0 TO 8 DO
    n := NodeChild(n, c[d], create);
    IF n = NIL THEN RETURN NIL END;
  END;
  RETURN n;
END TrnWalk;

PROCEDURE TrnUpdate (t : TrnStore; c : Coord; text : Bytes; overwrite : BOOLEAN);
  VAR n : Node; joined : Bytes;
BEGIN
  n := TrnWalk(t, c, TRUE);
  IF overwrite THEN
    IF BStr.Len(text) = 0 THEN
      IF n^.has THEN
        BStr.Dispose(n^.text);
        n^.text := NIL;
        n^.has := FALSE;
        DEC(t^.count);
      END;
      RETURN;
    END;
    IF NOT n^.has THEN INC(t^.count) END;
    IF n^.text <> NIL THEN BStr.Dispose(n^.text) END;
    n^.text := BStr.Copy(text);
    n^.has := TRUE;
  ELSE
    IF BStr.Len(text) = 0 THEN RETURN END;
    IF n^.has THEN
      joined := BStr.Copy(n^.text);
      BStr.AppendBytes(joined, text);
      BStr.Dispose(n^.text);
      n^.text := joined;
    ELSE
      n^.text := BStr.Copy(text);
      n^.has := TRUE;
      INC(t^.count);
    END;
  END;
END TrnUpdate;

PROCEDURE TrnFetch (t : TrnStore; c : Coord) : Bytes;
  VAR n : Node;
BEGIN
  n := TrnWalk(t, c, FALSE);
  IF (n = NIL) OR (NOT n^.has) THEN RETURN NIL END;
  RETURN n^.text;
END TrnFetch;

PROCEDURE TrnLen (t : TrnStore) : CARDINAL;
BEGIN RETURN t^.count END TrnLen;

PROCEDURE TrnCollect (n : Node; depth : CARDINAL; VAR prefix : Coord; m : Map);
  VAR i : CARDINAL;
BEGIN
  IF depth = 9 THEN
    IF n^.has THEN MapUpdate(m, prefix, n^.text, TRUE) END;
    RETURN;
  END;
  i := 0;
  WHILE i < n^.n DO
    prefix[depth] := n^.keys^[i];
    TrnCollect(n^.kids^[i], depth + 1, prefix, m);
    INC(i);
  END;
END TrnCollect;

PROCEDURE TrnSerialize (t : TrnStore; out : Bytes);
  VAR m : Map; prefix : Coord; i : CARDINAL;
BEGIN
  m := NewMap();
  FOR i := 0 TO 8 DO prefix[i] := 1 END;
  TrnCollect(t^.root, 0, prefix, m);
  Implode(m, out);
  DisposeMap(m);
END TrnSerialize;

PROCEDURE TrnDepth () : CARDINAL;
BEGIN RETURN 9 END TrnDepth;

BEGIN
  InitBreaks;
END Phext.
