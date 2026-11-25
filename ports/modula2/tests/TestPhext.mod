MODULE TestPhext;
(* Test suite for the Modula-2 libphext port. Usage:
   TestPhext <fixture-list-file>
   The list file names input.phext fixtures, one per line. *)

FROM SYSTEM IMPORT ADDRESS, ADR;
IMPORT StrIO, NumberIO;
IMPORT Phext, Json;
IMPORT BStr;
FROM BStr IMPORT Bytes;
FROM Phext IMPORT Coord;
FROM libc IMPORT open, read, close, write;
FROM Args IMPORT GetArg, Narg;

VAR
  failures : CARDINAL;

PROCEDURE RawOut (s : ARRAY OF CHAR);
  VAR i : CARDINAL; n : LONGINT;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] <> 0C) DO INC(i) END;
  IF i > 0 THEN n := write(2, ADR(s), i) END;
END RawOut;

PROCEDURE OutLn (s : ARRAY OF CHAR);
BEGIN
  RawOut(s);
  RawOut(CHR(10));
END OutLn;

PROCEDURE Check (cond : BOOLEAN; name : ARRAY OF CHAR);
BEGIN
  IF cond THEN
    RawOut("ok - "); OutLn(name);
  ELSE
    RawOut("FAIL - "); OutLn(name);
    INC(failures);
  END;
END Check;

PROCEDURE CheckBytes (got, want : Bytes; name : ARRAY OF CHAR);
BEGIN
  IF BStr.Equal(got, want) THEN
    Check(TRUE, name);
  ELSE
    RawOut("FAIL - "); RawOut(name);
    RawOut(" (got/want len mismatch)");
    RawOut(CHR(10));
    INC(failures);
  END;
END CheckBytes;

PROCEDURE ReadFile (path : Bytes) : Bytes;
  VAR z : Bytes; fd : INTEGER; b : Bytes;
      buf : ARRAY [0..65535] OF CHAR; n : LONGINT; rc : INTEGER;
BEGIN
  z := BStr.Copy(path);
  BStr.AppendCh(z, 0C);
  fd := open(BStr.DataAddr(z), 0, 0);
  BStr.Dispose(z);
  b := BStr.New();
  IF fd < 0 THEN RETURN b END;
  LOOP
    n := read(fd, ADR(buf), 65536);
    IF n <= 0 THEN EXIT END;
    BStr.AppendMem(b, ADR(buf), VAL(CARDINAL, n));
  END;
  rc := close(fd);
  RETURN b;
END ReadFile;

PROCEDURE BS (s : ARRAY OF CHAR) : Bytes;
BEGIN
  RETURN BStr.FromStr(s);
END BS;

PROCEDURE Slice (b : Bytes; from, upto : CARDINAL) : Bytes;
  VAR out : Bytes; k : CARDINAL;
BEGIN
  out := BStr.New();
  k := from;
  WHILE k < upto DO BStr.AppendCh(out, BStr.Get(b, k)); INC(k) END;
  RETURN out;
END Slice;

PROCEDURE UnitTests;
  VAR buf, t, empty, f : Bytes; c : Coord; ok : BOOLEAN;
      d : Phext.DynStore; tr : Phext.TrnStore;
      coords : ARRAY [0..5] OF Coord; i : CARDINAL;
      ser1, ser2 : Bytes;
      v : Json.JVal; jok : BOOLEAN; canon : Bytes;
BEGIN
  empty := BStr.New();
  ok := Phext.CoordParseStr("1.1.1/1.1.1/1.1.1", c);
  Check(ok AND (c[0] = 1) AND (c[8] = 1), "coord parse origin");
  t := Phext.CoordStr(c);
  Check(BStr.EqualStr(t, "1.1.1/1.1.1/1.1.1"), "coord origin string");
  BStr.Dispose(t);
  ok := Phext.CoordParseStr("2.3.4", c);
  Check(ok AND (c[0] = 2) AND (c[1] = 3) AND (c[2] = 4) AND (c[3] = 1),
        "coord parse partial");
  t := Phext.CoordStr(c);
  Check(BStr.EqualStr(t, "2.3.4/1.1.1/1.1.1"), "coord partial string");
  BStr.Dispose(t);
  ok := Phext.CoordParseStr("10.20.30/40.50.60/70.80.90", c);
  Check(ok AND (c[0] = 10) AND (c[4] = 50) AND (c[8] = 90), "coord parse full");

  buf := BStr.New();
  f := Phext.Fetch(buf, c);
  Check(BStr.Len(f) = 0, "fetch from empty buffer");
  BStr.Dispose(f);

  ok := Phext.CoordParseStr("1.1.1/1.1.1/1.1.1", c);
  t := BS("hello");
  buf := Phext.Insert(buf, c, t);
  BStr.Dispose(t);
  Check(BStr.EqualStr(buf, "hello"), "insert at origin");
  f := Phext.Fetch(buf, c);
  Check(BStr.EqualStr(f, "hello"), "fetch origin");
  BStr.Dispose(f);
  t := BS(" world");
  buf := Phext.Insert(buf, c, t);
  BStr.Dispose(t);
  Check(BStr.EqualStr(buf, "hello world"), "insert concatenates");
  t := BS("bye");
  buf := Phext.Replace(buf, c, t);
  BStr.Dispose(t);
  Check(BStr.EqualStr(buf, "bye"), "replace overwrites");

  ok := Phext.CoordParseStr("1.1.1/1.1.1/1.1.2", c);
  t := BS("second");
  buf := Phext.Insert(buf, c, t);
  BStr.Dispose(t);
  f := Phext.Fetch(buf, c);
  Check(BStr.EqualStr(f, "second"), "fetch second scroll");
  BStr.Dispose(f);
  ok := Phext.CoordParseStr("1.1.1/1.1.1/1.1.1", c);
  buf := Phext.Remove(buf, c);
  Check(NOT BStr.EqualStr(buf, "second"), "remove changes buffer");
  f := Phext.Fetch(buf, c);
  Check(BStr.Len(f) = 0, "removed scroll is gone");
  BStr.Dispose(f);
  ok := Phext.CoordParseStr("1.1.1/1.1.1/1.1.2", c);
  f := Phext.Fetch(buf, c);
  Check(BStr.EqualStr(f, "second"), "remove is coordinate-preserving");
  BStr.Dispose(f);
  t := Phext.Normalize(buf);
  CheckBytes(t, buf, "normalize idempotent on live buffer");
  BStr.Dispose(t);
  BStr.Dispose(buf);

  d := Phext.DynNew();
  tr := Phext.TrnNew();
  buf := BStr.New();
  ok := Phext.CoordParseStr("1.1.1/1.1.1/1.1.1", coords[0]);
  ok := Phext.CoordParseStr("1.1.1/1.1.1/1.1.2", coords[1]);
  ok := Phext.CoordParseStr("1.1.1/1.1.2/1.1.1", coords[2]);
  ok := Phext.CoordParseStr("1.1.2/1.1.1/1.1.1", coords[3]);
  ok := Phext.CoordParseStr("2.1.1/1.1.1/1.1.1", coords[4]);
  ok := Phext.CoordParseStr("1.1.1/1.1.1/2.5.9", coords[5]);
  FOR i := 0 TO 5 DO
    t := BStr.New();
    BStr.AppendStr(t, "scroll-");
    BStr.AppendCardinal(t, i);
    buf := Phext.Insert(buf, coords[i], t);
    Phext.DynUpdate(d, coords[i], t, FALSE);
    Phext.TrnUpdate(tr, coords[i], t, FALSE);
    BStr.Dispose(t);
    ser1 := BStr.New(); Phext.DynSerialize(d, ser1);
    ser2 := BStr.New(); Phext.TrnSerialize(tr, ser2);
    CheckBytes(ser1, buf, "dynamic == buffer");
    CheckBytes(ser2, buf, "transitive == buffer");
    BStr.Dispose(ser1); BStr.Dispose(ser2);
  END;
  Check(Phext.DynLen(d) = 6, "dynamic length");
  Check(Phext.TrnLen(tr) = 6, "transitive length");
  Check(Phext.TrnDepth() = 9, "transitive depth 9");
  buf := Phext.Remove(buf, coords[1]);
  Phext.DynUpdate(d, coords[1], empty, TRUE);
  Phext.TrnUpdate(tr, coords[1], empty, TRUE);
  ser1 := BStr.New(); Phext.DynSerialize(d, ser1);
  ser2 := BStr.New(); Phext.TrnSerialize(tr, ser2);
  CheckBytes(ser1, buf, "dynamic == buffer after remove");
  CheckBytes(ser2, buf, "transitive == buffer after remove");
  BStr.Dispose(ser1); BStr.Dispose(ser2);
  f := Phext.DynFetch(d, coords[2]);
  Check((f <> NIL) AND BStr.EqualStr(f, "scroll-2"), "dynamic fetch");
  f := Phext.TrnFetch(tr, coords[2]);
  Check((f <> NIL) AND BStr.EqualStr(f, "scroll-2"), "transitive fetch");
  Phext.DynDispose(d);
  Phext.TrnDispose(tr);
  BStr.Dispose(buf);
  BStr.Dispose(empty);

  t := BS('{"b":1,"a":[true,null,"x"]}');
  v := Json.Parse(t, jok);
  Check(jok, "json parse");
  canon := BStr.New();
  Json.Canon(v, canon);
  Check(BStr.EqualStr(canon, '{"a":[true,null,"x"],"b":1}'), "json canon sorts keys");
  BStr.Dispose(canon);
  BStr.Dispose(t);
END UnitTests;

PROCEDURE FixtureTests (listPath : Bytes);
  VAR list, data, rt, n1, n2, line : Bytes;
      i, start : CARDINAL; m : Phext.Map;
BEGIN
  list := ReadFile(listPath);
  start := 0;
  FOR i := 0 TO BStr.Len(list) DO
    IF (i = BStr.Len(list)) OR (BStr.Get(list, i) = CHR(10)) THEN
      IF i > start THEN
        line := Slice(list, start, i);
        IF (BStr.Len(line) > 0) AND (BStr.Get(line, BStr.Len(line) - 1) = CHR(13)) THEN
          n1 := Slice(line, 0, BStr.Len(line) - 1);
          BStr.Dispose(line);
          line := n1;
        END;
        data := ReadFile(line);
        m := Phext.NewMap();
        Phext.Explode(data, m);
        rt := BStr.New();
        Phext.Implode(m, rt);
        Phext.DisposeMap(m);
        CheckBytes(rt, data, "fixture round trip");
        n1 := Phext.Normalize(data);
        n2 := Phext.Normalize(n1);
        CheckBytes(n2, n1, "fixture normalize idempotent");
        BStr.Dispose(data); BStr.Dispose(rt);
        BStr.Dispose(n1); BStr.Dispose(n2);
        BStr.Dispose(line);
      END;
      start := i + 1;
    END;
  END;
  BStr.Dispose(list);
END FixtureTests;

VAR
  arg : ARRAY [0..1023] OF CHAR; lp : Bytes; got : BOOLEAN;
BEGIN
  failures := 0;
  UnitTests;
  IF Narg() >= 2 THEN
    got := GetArg(arg, 1);
    IF got THEN
      lp := BStr.FromStr(arg);
      FixtureTests(lp);
      BStr.Dispose(lp);
    END;
  END;
  IF failures = 0 THEN
    OutLn("PASS");
  ELSE
    RawOut("FAILURES"); RawOut(CHR(10));
  END;
END TestPhext.
