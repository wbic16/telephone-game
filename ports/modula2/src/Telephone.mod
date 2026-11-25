MODULE Telephone;
(* Exocortical Telephone Game CLI (contract v2) for the Modula-2
   libphext port. Wire: one JSON request in, one JSON response out;
   "serve" loops over lines. GZ1 framing for lines over 8 KB via the
   system gzip/base64 tools on temp files. sha256 via sha256sum(1),
   base64 via base64(1) (crypto utilities, not phext logic); PGP via
   subprocess gpg with key home ~/telephone-modula2/gnupg
   (TELEPHONE_GNUPGHOME overrides). All phext operations use this
   port's own Phext module. *)

FROM SYSTEM IMPORT ADDRESS, ADR;
IMPORT BStr, Phext, Json;
FROM BStr IMPORT Bytes;
FROM Phext IMPORT Coord;
FROM libc IMPORT open, read, write, close, system, getenv, getpid;
FROM Args IMPORT GetArg, Narg;

CONST
  IMPL = "modula2";
  INDEXCS = "1.1.1/1.1.1/1.1.1";
  KEYSCS = "1.1.1/1.1.1/1.1.2";
  KHCS = "1.1.1/1.1.1/1.1.3";
  KEYUID = "libphext telephone modula2";

VAR
  tmpdir : Bytes;
  tmpCounter : CARDINAL;
  serving : BOOLEAN;
  cacheSet : BOOLEAN;
  cacheMap : Phext.Map;
  inBuf : Bytes;
  inPos : CARDINAL;

(* ---------- basic helpers ---------- *)

PROCEDURE BS (s : ARRAY OF CHAR) : Bytes;
BEGIN
  RETURN BStr.FromStr(s);
END BS;

PROCEDURE Z (b : Bytes) : Bytes;
  VAR z : Bytes;
BEGIN
  z := BStr.Copy(b);
  BStr.AppendCh(z, 0C);
  RETURN z;
END Z;

PROCEDURE StartsWith (b : Bytes; prefix : ARRAY OF CHAR) : BOOLEAN;
  VAR i : CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(prefix)) AND (prefix[i] <> 0C) DO
    IF (i >= BStr.Len(b)) OR (BStr.Get(b, i) <> prefix[i]) THEN RETURN FALSE END;
    INC(i);
  END;
  RETURN TRUE;
END StartsWith;

PROCEDURE Contains (b : Bytes; needle : ARRAY OF CHAR) : BOOLEAN;
  VAR i, j, nl : CARDINAL; ok : BOOLEAN;
BEGIN
  nl := 0;
  WHILE (nl <= HIGH(needle)) AND (needle[nl] <> 0C) DO INC(nl) END;
  IF nl = 0 THEN RETURN TRUE END;
  i := 0;
  WHILE i + nl <= BStr.Len(b) DO
    ok := TRUE;
    FOR j := 0 TO nl - 1 DO
      IF BStr.Get(b, i + j) <> needle[j] THEN ok := FALSE END;
    END;
    IF ok THEN RETURN TRUE END;
    INC(i);
  END;
  RETURN FALSE;
END Contains;

PROCEDURE Slice (b : Bytes; from, upto : CARDINAL) : Bytes;
  VAR out : Bytes; k : CARDINAL;
BEGIN
  out := BStr.New();
  k := from;
  WHILE k < upto DO BStr.AppendCh(out, BStr.Get(b, k)); INC(k) END;
  RETURN out;
END Slice;

PROCEDURE TrimBoth (s : Bytes) : Bytes;
  VAR lo, hi : CARDINAL; ch : CHAR;
BEGIN
  lo := 0; hi := BStr.Len(s);
  WHILE lo < hi DO
    ch := BStr.Get(s, lo);
    IF (ch = ' ') OR (ch = CHR(9)) OR (ch = CHR(10)) OR (ch = CHR(13)) THEN INC(lo)
    ELSE RETURN Slice(s, lo, hi) END;
  END;
  RETURN BStr.New();
END TrimBoth;

PROCEDURE TrimTrail (s : Bytes) : Bytes;
  VAR hi : CARDINAL; ch : CHAR;
BEGIN
  hi := BStr.Len(s);
  WHILE hi > 0 DO
    ch := BStr.Get(s, hi - 1);
    IF (ch = ' ') OR (ch = CHR(9)) OR (ch = CHR(10)) OR (ch = CHR(13)) THEN DEC(hi)
    ELSE RETURN Slice(s, 0, hi) END;
  END;
  RETURN BStr.New();
END TrimTrail;

(* Split into whitespace-separated words (space/tab runs). *)
PROCEDURE SplitWords (s : Bytes; VAR words : ARRAY OF Bytes; maxw : CARDINAL) : CARDINAL;
  VAR i, n : CARDINAL; start : CARDINAL; ch : CHAR; inword : BOOLEAN;
BEGIN
  n := 0; i := 0; inword := FALSE; start := 0;
  WHILE i < BStr.Len(s) DO
    ch := BStr.Get(s, i);
    IF (ch = ' ') OR (ch = CHR(9)) THEN
      IF inword THEN
        IF n < maxw THEN words[n] := Slice(s, start, i); INC(n) END;
        inword := FALSE;
      END;
    ELSE
      IF NOT inword THEN start := i; inword := TRUE END;
    END;
    INC(i);
  END;
  IF inword AND (n < maxw) THEN words[n] := Slice(s, start, BStr.Len(s)); INC(n) END;
  RETURN n;
END SplitWords;

PROCEDURE Env (name : ARRAY OF CHAR) : Bytes;
  VAR nb, out : Bytes; a : ADDRESS; i : CARDINAL;
      ptr : POINTER TO ARRAY [0..2000000000] OF CHAR;
BEGIN
  out := BStr.New();
  nb := BS(name);
  BStr.AppendCh(nb, 0C);
  a := getenv(BStr.DataAddr(nb));
  BStr.Dispose(nb);
  IF a = NIL THEN RETURN out END;
  ptr := a;
  i := 0;
  WHILE ptr^[i] <> 0C DO
    BStr.AppendCh(out, ptr^[i]);
    INC(i);
  END;
  RETURN out;
END Env;

(* ---------- file / shell helpers ---------- *)

PROCEDURE TmpPath (tag : ARRAY OF CHAR) : Bytes;
  VAR p : Bytes;
BEGIN
  INC(tmpCounter);
  p := BStr.Copy(tmpdir);
  BStr.AppendCh(p, '/');
  BStr.AppendStr(p, tag);
  BStr.AppendCh(p, '-');
  BStr.AppendCardinal(p, tmpCounter);
  RETURN p;
END TmpPath;

PROCEDURE WriteFile (path : Bytes; data : Bytes) : BOOLEAN;
  VAR z : Bytes; fd : INTEGER; off : CARDINAL; n : LONGINT;
      chunk : Bytes; rc : INTEGER;
BEGIN
  z := Z(path);
  fd := open(BStr.DataAddr(z), 577, 420);
  BStr.Dispose(z);
  IF fd < 0 THEN RETURN FALSE END;
  off := 0;
  WHILE off < BStr.Len(data) DO
    chunk := Slice(data, off, BStr.Len(data));
    n := write(fd, BStr.DataAddr(chunk), BStr.Len(chunk));
    BStr.Dispose(chunk);
    IF n <= 0 THEN rc := close(fd); RETURN FALSE END;
    off := off + VAL(CARDINAL, n);
  END;
  rc := close(fd);
  RETURN TRUE;
END WriteFile;

PROCEDURE ReadFile (path : Bytes) : Bytes;
  VAR z : Bytes; fd : INTEGER; b : Bytes;
      buf : ARRAY [0..65535] OF CHAR; n : LONGINT; rc : INTEGER;
BEGIN
  z := Z(path);
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

PROCEDURE ShellRun (cmd : Bytes) : INTEGER;
  VAR z : Bytes; rc : INTEGER;
BEGIN
  z := Z(cmd);
  rc := system(BStr.DataAddr(z));
  BStr.Dispose(z);
  IF rc = -1 THEN RETURN -1 END;
  RETURN rc DIV 256;
END ShellRun;

PROCEDURE ShellCapture (cmd : Bytes) : Bytes;
  VAR full, out, res : Bytes; rc : INTEGER;
BEGIN
  out := TmpPath("cap");
  full := BStr.Copy(cmd);
  BStr.AppendStr(full, " > ");
  BStr.AppendBytes(full, out);
  BStr.AppendStr(full, " 2>/dev/null");
  rc := ShellRun(full);
  BStr.Dispose(full);
  res := ReadFile(out);
  RETURN res;
END ShellCapture;

PROCEDURE ShellQuiet (cmd : Bytes) : INTEGER;
  VAR full : Bytes; rc : INTEGER;
BEGIN
  full := BStr.Copy(cmd);
  BStr.AppendStr(full, " >/dev/null 2>&1");
  rc := ShellRun(full);
  BStr.Dispose(full);
  RETURN rc;
END ShellQuiet;

PROCEDURE RmFiles (a : Bytes);
  VAR cmd : Bytes; rc : INTEGER;
BEGIN
  cmd := BS("rm -rf ");
  BStr.AppendBytes(cmd, a);
  rc := ShellQuiet(cmd);
  BStr.Dispose(cmd);
END RmFiles;

PROCEDURE Sha256Hex (data : Bytes) : Bytes;
  VAR f, cmd, txt, hex : Bytes; words : ARRAY [0..3] OF Bytes; nw : CARDINAL;
BEGIN
  f := TmpPath("sha");
  IF NOT WriteFile(f, data) THEN RETURN BStr.New() END;
  cmd := BS("sha256sum ");
  BStr.AppendBytes(cmd, f);
  txt := ShellCapture(cmd);
  BStr.Dispose(cmd);
  nw := SplitWords(txt, words, 4);
  IF nw >= 1 THEN hex := words[0] ELSE hex := BStr.New() END;
  RmFiles(f);
  RETURN hex;
END Sha256Hex;

PROCEDURE B64Enc (data : Bytes) : Bytes;
  VAR f, cmd, txt : Bytes;
BEGIN
  f := TmpPath("b64");
  IF NOT WriteFile(f, data) THEN RETURN BStr.New() END;
  cmd := BS("base64 -w0 ");
  BStr.AppendBytes(cmd, f);
  txt := ShellCapture(cmd);
  BStr.Dispose(cmd);
  RmFiles(f);
  RETURN TrimTrail(txt);
END B64Enc;

PROCEDURE B64Dec (s : Bytes) : Bytes;
  VAR f, cmd, d : Bytes;
BEGIN
  f := TmpPath("b64d");
  IF NOT WriteFile(f, s) THEN RETURN BStr.New() END;
  cmd := BS("base64 -d ");
  BStr.AppendBytes(cmd, f);
  d := ShellCapture(cmd);
  BStr.Dispose(cmd);
  RmFiles(f);
  RETURN d;
END B64Dec;

PROCEDURE GzUnframe (b64 : Bytes) : Bytes;
  VAR f, cmd, d : Bytes;
BEGIN
  f := TmpPath("gz");
  IF NOT WriteFile(f, b64) THEN RETURN BStr.New() END;
  cmd := BS("base64 -d ");
  BStr.AppendBytes(cmd, f);
  BStr.AppendStr(cmd, " | gzip -dc");
  d := ShellCapture(cmd);
  BStr.Dispose(cmd);
  RmFiles(f);
  RETURN d;
END GzUnframe;

PROCEDURE GzFrame (data : Bytes) : Bytes;
  VAR f, cmd, txt, out : Bytes;
BEGIN
  f := TmpPath("gzf");
  IF NOT WriteFile(f, data) THEN RETURN BStr.New() END;
  cmd := BS("gzip -c ");
  BStr.AppendBytes(cmd, f);
  BStr.AppendStr(cmd, " | base64 -w0");
  txt := ShellCapture(cmd);
  BStr.Dispose(cmd);
  RmFiles(f);
  out := BS("GZ1:");
  BStr.AppendBytes(out, TrimTrail(txt));
  RETURN out;
END GzFrame;

(* ---------- gpg ---------- *)

PROCEDURE GpgHome () : Bytes;
  VAR h : Bytes;
BEGIN
  h := Env("TELEPHONE_GNUPGHOME");
  IF BStr.Len(h) > 0 THEN RETURN h END;
  h := Env("HOME");
  BStr.AppendStr(h, "/telephone-modula2/gnupg");
  RETURN h;
END GpgHome;

PROCEDURE GpgPrepare (home : Bytes);
  VAR cmd : Bytes; rc : INTEGER;
BEGIN
  cmd := BS("mkdir -p ");
  BStr.AppendBytes(cmd, home);
  rc := ShellQuiet(cmd);
  BStr.Dispose(cmd);
  cmd := BS("chmod 700 ");
  BStr.AppendBytes(cmd, home);
  rc := ShellQuiet(cmd);
  BStr.Dispose(cmd);
END GpgPrepare;

PROCEDURE Gpg (args : Bytes; infile : Bytes) : Bytes;
  VAR home, cmd, out, res : Bytes; rc : INTEGER;
BEGIN
  home := GpgHome();
  GpgPrepare(home);
  cmd := BS("GNUPGHOME=");
  BStr.AppendBytes(cmd, home);
  BStr.AppendStr(cmd, " gpg --batch --yes --pinentry-mode loopback --passphrase '' ");
  BStr.AppendBytes(cmd, args);
  IF BStr.Len(infile) > 0 THEN
    BStr.AppendStr(cmd, " < ");
    BStr.AppendBytes(cmd, infile);
  END;
  res := ShellCapture(cmd);
  BStr.Dispose(cmd);
  RETURN res;
END Gpg;

PROCEDURE DoKeygen () : Bytes;
  VAR listing, pub, resp, a : Bytes;
BEGIN
  a := BS("--list-keys --with-colons");
  listing := Gpg(a, BStr.New());
  BStr.Dispose(a);
  IF NOT Contains(listing, "pub:") THEN
    a := BS("--quick-generate-key '");
    BStr.AppendStr(a, KEYUID);
    BStr.AppendStr(a, "' ed25519 sign never");
    pub := Gpg(a, BStr.New());
    BStr.Dispose(a);
  END;
  (* check for a pub: line properly below *)
  a := BS("--armor --export '");
  BStr.AppendStr(a, KEYUID);
  BStr.AppendStr(a, "'");
  pub := Gpg(a, BStr.New());
  BStr.Dispose(a);
  IF (BStr.Len(pub) = 0) OR (BStr.Get(pub, BStr.Len(pub) - 1) <> CHR(10)) THEN
    BStr.AppendCh(pub, CHR(10));
  END;
  resp := BS('{"impl":');
  Json.QuoteStr(IMPL, resp);
  BStr.AppendStr(resp, ',"pubkey":');
  Json.Quote(pub, resp);
  BStr.AppendCh(resp, '}');
  RETURN resp;
END DoKeygen;

PROCEDURE DetachSign (data : Bytes) : Bytes;
  VAR f, sig, home, cmd, d : Bytes; rc : INTEGER;
BEGIN
  f := TmpPath("sign");
  sig := BStr.Copy(f);
  BStr.AppendStr(sig, ".asc");
  IF NOT WriteFile(f, data) THEN RETURN BStr.New() END;
  home := GpgHome();
  GpgPrepare(home);
  cmd := BS("GNUPGHOME=");
  BStr.AppendBytes(cmd, home);
  BStr.AppendStr(cmd, " gpg --batch --yes --pinentry-mode loopback --passphrase '' --detach-sign --armor -u '");
  BStr.AppendStr(cmd, KEYUID);
  BStr.AppendStr(cmd, "' --output ");
  BStr.AppendBytes(cmd, sig);
  BStr.AppendCh(cmd, ' ');
  BStr.AppendBytes(cmd, f);
  rc := ShellQuiet(cmd);
  BStr.Dispose(cmd);
  d := ReadFile(sig);
  RmFiles(f);
  RmFiles(sig);
  RETURN d;
END DetachSign;

(* Returns empty Bytes on success, else an error message. *)
PROCEDURE VerifySignature (pubkeys, data, signature : Bytes) : Bytes;
  VAR td, gh, cmd : Bytes; rc, rc1, rc2 : INTEGER;
BEGIN
  td := TmpPath("verify");
  gh := BStr.Copy(td);
  BStr.AppendStr(gh, "/gnupg");
  cmd := BS("mkdir -p ");
  BStr.AppendBytes(cmd, gh);
  rc := ShellQuiet(cmd);
  BStr.Dispose(cmd);
  cmd := BS("chmod 700 ");
  BStr.AppendBytes(cmd, gh);
  rc := ShellQuiet(cmd);
  BStr.Dispose(cmd);
  cmd := BStr.Copy(td); BStr.AppendStr(cmd, "/keys.asc");
  IF NOT WriteFile(cmd, pubkeys) THEN END;
  BStr.Dispose(cmd);
  cmd := BStr.Copy(td); BStr.AppendStr(cmd, "/data");
  IF NOT WriteFile(cmd, data) THEN END;
  BStr.Dispose(cmd);
  cmd := BStr.Copy(td); BStr.AppendStr(cmd, "/sig.asc");
  IF NOT WriteFile(cmd, signature) THEN END;
  BStr.Dispose(cmd);
  cmd := BS("GNUPGHOME=");
  BStr.AppendBytes(cmd, gh);
  BStr.AppendStr(cmd, " gpg --batch --yes --import ");
  BStr.AppendBytes(cmd, td);
  BStr.AppendStr(cmd, "/keys.asc");
  rc1 := ShellQuiet(cmd);
  BStr.Dispose(cmd);
  cmd := BS("GNUPGHOME=");
  BStr.AppendBytes(cmd, gh);
  BStr.AppendStr(cmd, " gpg --batch --yes --verify ");
  BStr.AppendBytes(cmd, td);
  BStr.AppendStr(cmd, "/sig.asc ");
  BStr.AppendBytes(cmd, td);
  BStr.AppendStr(cmd, "/data");
  rc2 := ShellQuiet(cmd);
  BStr.Dispose(cmd);
  RmFiles(td);
  IF rc1 <> 0 THEN RETURN BS("gpg import failed") END;
  IF rc2 <> 0 THEN RETURN BS("gpg verify failed") END;
  RETURN BStr.New();
END VerifySignature;

(* ---------- JSON request helpers ---------- *)

PROCEDURE JStrOf (v : Json.JVal) : Bytes;
  VAR b : Bytes;
BEGIN
  b := Json.StrVal(v);
  IF b = NIL THEN RETURN BStr.New() END;
  RETURN b;
END JStrOf;

PROCEDURE JNumRaw (v : Json.JVal) : Bytes;
BEGIN
  RETURN JStrOf(v);
END JNumRaw;

PROCEDURE ReqState (req : Json.JVal) : Bytes;
  VAR n : Json.JVal;
BEGIN
  n := Json.Get(req, "state");
  IF n = 0 THEN n := Json.Get(req, "state_b64") END;
  IF n = 0 THEN RETURN BStr.New() END;
  RETURN B64Dec(JStrOf(n));
END ReqState;

PROCEDURE CoordOf (cs : Bytes; VAR c : Coord) : BOOLEAN;
BEGIN
  RETURN Phext.CoordParse(cs, c);
END CoordOf;

PROCEDURE FetchCs (m : Phext.Map; cs : Bytes) : Bytes;
  VAR c : Coord; t : Bytes;
BEGIN
  IF NOT CoordOf(cs, c) THEN RETURN NIL END;
  t := Phext.MapFetch(m, c);
  RETURN t;
END FetchCs;

(* ---------- game logic (mirrors the reference ports) ---------- *)

PROCEDURE EchoValue (ping : Json.JVal) : Bytes;
  VAR game, round, nonce, data : Bytes; g : Json.JVal;
BEGIN
  game := BStr.New(); round := BStr.New(); nonce := BStr.New();
  g := Json.Get(ping, "game");
  IF g <> 0 THEN game := JStrOf(g) END;
  g := Json.Get(ping, "round");
  IF g <> 0 THEN
    IF Json.TypeOf(g) = Json.JNum THEN round := JNumRaw(g) ELSE round := JStrOf(g) END;
  ELSE
    g := Json.Get(ping, "turn");
    IF g <> 0 THEN round := JNumRaw(g) END;
  END;
  g := Json.Get(ping, "nonce");
  IF g <> 0 THEN nonce := JStrOf(g) END;
  data := BS(IMPL);
  BStr.AppendCh(data, '|');
  BStr.AppendBytes(data, game);
  BStr.AppendCh(data, '|');
  BStr.AppendBytes(data, round);
  BStr.AppendCh(data, '|');
  BStr.AppendBytes(data, nonce);
  RETURN Sha256Hex(data);
END EchoValue;

PROCEDURE HexByteVal (hex : Bytes; off : CARDINAL) : CARDINAL;
  VAR v, d : CARDINAL; ch : CHAR;
BEGIN
  v := 0;
  FOR d := 0 TO 1 DO
    ch := BStr.Get(hex, off + d);
    v := v * 16;
    IF (ch >= '0') AND (ch <= '9') THEN v := v + (ORD(ch) - ORD('0'))
    ELSIF (ch >= 'a') AND (ch <= 'f') THEN v := v + (ORD(ch) - ORD('a')) + 10
    ELSIF (ch >= 'A') AND (ch <= 'F') THEN v := v + (ORD(ch) - ORD('A')) + 10
    END;
  END;
  RETURN v;
END HexByteVal;

PROCEDURE ElectWinner (position : Bytes; cands : Json.JVal; turn : LONGINT) : Bytes;
  VAR seed, hex, joined : Bytes; i, n : CARDINAL; item : Json.JVal;
BEGIN
  joined := BStr.New();
  n := Json.ArrLen(cands);
  i := 0;
  WHILE i < n DO
    IF i > 0 THEN BStr.AppendCh(joined, ',') END;
    item := Json.ArrItem(cands, i);
    BStr.AppendBytes(joined, JStrOf(item));
    INC(i);
  END;
  seed := BStr.Copy(position);
  BStr.AppendCh(seed, CHR(VAL(CARDINAL, turn MOD 256)));
  BStr.AppendBytes(seed, joined);
  hex := Sha256Hex(seed);
  IF n = 0 THEN RETURN BStr.New() END;
  RETURN JStrOf(Json.ArrItem(cands, HexByteVal(hex, 0) MOD n));
END ElectWinner;

PROCEDURE Wrap999 (v : CARDINAL) : CARDINAL;
BEGIN
  RETURN ((v - 1) MOD 999) + 1;
END Wrap999;

PROCEDURE NextCoord (VAR c : Coord);
  VAR d : INTEGER;
BEGIN
  d := 8;
  WHILE d >= 0 DO
    IF c[d] < 999 THEN
      c[d] := c[d] + 1;
      RETURN;
    END;
    c[d] := 1;
    DEC(d);
  END;
END NextCoord;

PROCEDURE IsReserved (c : Coord) : BOOLEAN;
  VAR o : Coord; i : CARDINAL;
BEGIN
  FOR i := 0 TO 8 DO o[i] := 1 END;
  IF Phext.CoordEq(c, o) THEN RETURN TRUE END;
  o[8] := 2;
  IF Phext.CoordEq(c, o) THEN RETURN TRUE END;
  o[8] := 3;
  IF Phext.CoordEq(c, o) THEN RETURN TRUE END;
  RETURN FALSE;
END IsReserved;

PROCEDURE ChooseAdventure (state, position : Bytes; turn : LONGINT) : Bytes;
  VAR m : Phext.Map; seed, hex, resp, text, cs : Bytes;
      c : Coord; b1, b2, dim : CARDINAL;
BEGIN
  m := Phext.NewMap();
  Phext.Explode(state, m);
  seed := BStr.Copy(position);
  BStr.AppendCh(seed, CHR(VAL(CARDINAL, turn MOD 256)));
  BStr.AppendBytes(seed, state);
  hex := Sha256Hex(seed);
  b1 := HexByteVal(hex, 2);
  b2 := HexByteVal(hex, 4);
  IF NOT CoordOf(position, c) THEN
    Phext.DisposeMap(m);
    RETURN BS('{"error":"bad position"}');
  END;
  dim := b1 MOD 9;
  c[dim] := Wrap999(c[dim] + 1 + (b2 MOD 3));
  WHILE (Phext.MapFind(m, c) >= 0) OR IsReserved(c) DO
    NextCoord(c);
  END;
  cs := Phext.CoordStr(c);
  text := BS(IMPL);
  BStr.AppendStr(text, " turn ");
  IF turn >= 0 THEN BStr.AppendCardinal(text, VAL(CARDINAL, turn)) END;
  BStr.AppendStr(text, " at ");
  BStr.AppendBytes(text, cs);
  resp := BS('{"coordinate":');
  Json.Quote(cs, resp);
  BStr.AppendStr(resp, ',"op":"insert","text":');
  Json.Quote(text, resp);
  BStr.AppendCh(resp, '}');
  Phext.DisposeMap(m);
  RETURN resp;
END ChooseAdventure;

PROCEDURE ApplyStep (state : Bytes; step : Json.JVal) : Bytes;
  VAR op, csB, text, m2 : Bytes; m : Phext.Map; c : Coord;
      out, resp : Bytes; empty : Bytes;
BEGIN
  op := JStrOf(Json.Get(step, "op"));
  csB := JStrOf(Json.Get(step, "coordinate"));
  text := JStrOf(Json.Get(step, "text"));
  IF BStr.EqualStr(op, "fetch") THEN
    IF NOT CoordOf(csB, c) THEN RETURN BS('{"error":"bad coordinate"}') END;
    out := Phext.Fetch(state, c);
    resp := BS('{"fetch_sha256":');
    Json.Quote(Sha256Hex(out), resp);
    BStr.AppendStr(resp, ',"state_b64":');
    Json.Quote(B64Enc(state), resp);
    BStr.AppendStr(resp, ',"state_sha256":');
    Json.Quote(Sha256Hex(state), resp);
    BStr.AppendCh(resp, '}');
    RETURN resp;
  END;
  m := Phext.NewMap();
  Phext.Explode(state, m);
  IF CoordOf(csB, c) THEN
    IF BStr.EqualStr(op, "insert") THEN Phext.MapUpdate(m, c, text, FALSE)
    ELSIF BStr.EqualStr(op, "replace") THEN Phext.MapUpdate(m, c, text, TRUE)
    ELSIF BStr.EqualStr(op, "remove") THEN
      empty := BStr.New();
      Phext.MapUpdate(m, c, empty, TRUE);
      BStr.Dispose(empty);
    END;
  END;
  out := BStr.New();
  Phext.Implode(m, out);
  Phext.DisposeMap(m);
  resp := BS('{"fetch_sha256":null,"state_b64":');
  Json.Quote(B64Enc(out), resp);
  BStr.AppendStr(resp, ',"state_sha256":');
  Json.Quote(Sha256Hex(out), resp);
  BStr.AppendCh(resp, '}');
  RETURN resp;
END ApplyStep;

PROCEDURE VFail (detail : Bytes) : Bytes;
  VAR resp : Bytes;
BEGIN
  resp := BS('{"detail":');
  Json.Quote(detail, resp);
  BStr.AppendStr(resp, ',"impl":');
  Json.QuoteStr(IMPL, resp);
  BStr.AppendStr(resp, ',"verdict":"fail"}');
  RETURN resp;
END VFail;

PROCEDURE VFailS (detail : ARRAY OF CHAR) : Bytes;
BEGIN
  RETURN VFail(BS(detail));
END VFailS;

PROCEDURE MapEq (a, b : Phext.Map) : BOOLEAN;
  VAR i : CARDINAL; ca, cb : Coord;
BEGIN
  IF Phext.MapCount(a) <> Phext.MapCount(b) THEN RETURN FALSE END;
  i := 0;
  WHILE i < Phext.MapCount(a) DO
    Phext.MapCoordAt(a, i, ca);
    Phext.MapCoordAt(b, i, cb);
    IF NOT Phext.CoordEq(ca, cb) THEN RETURN FALSE END;
    IF NOT BStr.Equal(Phext.MapTextAt(a, i), Phext.MapTextAt(b, i)) THEN RETURN FALSE END;
    INC(i);
  END;
  RETURN TRUE;
END MapEq;

PROCEDURE DoValidate (req : Json.JVal) : Bytes;
  VAR step : Json.JVal; op, state : Bytes;
      csB, text, evB, indexLine, detail : Bytes;
      priorStateNode : Json.JVal;
      prior, curT, priorT : Bytes; pm, sm : Phext.Map; c : Coord;
      i : CARDINAL; cc : Coord; t, idxT, idxTrim, lineTrim : Bytes;
BEGIN
  step := Json.Get(req, "step");
  op := JStrOf(Json.Get(step, "op"));
  state := ReqState(req);
  priorStateNode := Json.Get(req, "prior_state");
  IF priorStateNode <> 0 THEN
    (* prior_state form *)
    IF NOT BStr.EqualStr(op, "insert") THEN RETURN VFailS("step op is not insert") END;
    csB := JStrOf(Json.Get(step, "coordinate"));
    text := JStrOf(Json.Get(step, "text"));
    IF NOT CoordOf(csB, c) THEN RETURN VFailS("bad coordinate") END;
    curT := Phext.Fetch(state, c);
    IF NOT BStr.Equal(curT, text) THEN
      detail := BS("placed scroll absent or content differs at ");
      BStr.AppendBytes(detail, csB);
      RETURN VFail(detail);
    END;
    prior := B64Dec(JStrOf(priorStateNode));
    priorT := Phext.Fetch(prior, c);
    IF BStr.Len(priorT) <> 0 THEN RETURN VFailS("coordinate was not unused in the prior state") END;
    pm := Phext.NewMap();
    Phext.Explode(prior, pm);
    sm := Phext.NewMap();
    Phext.Explode(state, sm);
    IF Phext.MapCount(sm) <> Phext.MapCount(pm) + 1 THEN
      Phext.DisposeMap(pm); Phext.DisposeMap(sm);
      RETURN VFailS("scroll count did not grow by exactly one");
    END;
    i := 0;
    WHILE i < Phext.MapCount(pm) DO
      Phext.MapCoordAt(pm, i, cc);
      IF Phext.MapFind(sm, cc) < 0 THEN
        Phext.DisposeMap(pm); Phext.DisposeMap(sm);
        RETURN VFailS("a prior scroll vanished");
      END;
      IF NOT BStr.Equal(Phext.MapTextAt(pm, i), Phext.MapFetch(sm, cc)) THEN
        detail := BS("a prior scroll was overwritten: ");
        BStr.AppendBytes(detail, Phext.CoordStr(cc));
        Phext.DisposeMap(pm); Phext.DisposeMap(sm);
        RETURN VFail(detail);
      END;
      INC(i);
    END;
    Phext.DisposeMap(pm); Phext.DisposeMap(sm);
    RETURN BS('{"detail":"placed at unused coordinate; all prior scrolls intact","impl":"modula2","verdict":"pass"}');
  END;
  (* driver form: cached prior map + event_coord + index_line *)
  IF NOT cacheSet THEN RETURN VFailS("validate called before init") END;
  sm := Phext.NewMap();
  Phext.Explode(state, sm);
  csB := JStrOf(Json.Get(step, "coordinate"));
  evB := JStrOf(Json.Get(req, "event_coord"));
  indexLine := JStrOf(Json.Get(req, "index_line"));
  text := JStrOf(Json.Get(step, "text"));
  t := FetchCs(sm, csB);
  IF (t = NIL) OR NOT BStr.Equal(t, text) THEN
    Phext.DisposeMap(sm);
    RETURN VFailS("placed scroll missing or altered");
  END;
  i := 0;
  WHILE i < Phext.MapCount(cacheMap) DO
    Phext.MapCoordAt(cacheMap, i, cc);
    IF NOT BStr.EqualStr(Phext.CoordStr(cc), INDEXCS) THEN
      t := Phext.MapFetch(sm, cc);
      IF (t = NIL) OR NOT BStr.Equal(t, Phext.MapTextAt(cacheMap, i)) THEN
        detail := BS("prior scroll overwritten at ");
        BStr.AppendBytes(detail, Phext.CoordStr(cc));
        Phext.DisposeMap(sm);
        RETURN VFail(detail);
      END;
    END;
    INC(i);
  END;
  i := 0;
  WHILE i < Phext.MapCount(sm) DO
    Phext.MapCoordAt(sm, i, cc);
    IF Phext.MapFind(cacheMap, cc) < 0 THEN
      IF NOT BStr.Equal(Phext.CoordStr(cc), csB) AND NOT BStr.Equal(Phext.CoordStr(cc), evB) THEN
        detail := BS("unexpected new scroll at ");
        BStr.AppendBytes(detail, Phext.CoordStr(cc));
        Phext.DisposeMap(sm);
        RETURN VFail(detail);
      END;
    END;
    INC(i);
  END;
  idxT := FetchCs(sm, BS(INDEXCS));
  IF idxT = NIL THEN idxT := BStr.New() END;
  idxTrim := TrimTrail(idxT);
  lineTrim := TrimTrail(indexLine);
  IF (BStr.Len(idxTrim) < BStr.Len(lineTrim))
     OR NOT BStr.Equal(Slice(idxTrim, BStr.Len(idxTrim) - BStr.Len(lineTrim), BStr.Len(idxTrim)), lineTrim) THEN
    Phext.DisposeMap(sm);
    RETURN VFailS("index does not record the placement");
  END;
  Phext.DisposeMap(cacheMap);
  cacheMap := sm;
  RETURN BS('{"impl":"modula2","verdict":"pass"}');
END DoValidate;

PROCEDURE VerifyFail (n : CARDINAL; msg : Bytes) : Bytes;
  VAR resp : Bytes;
BEGIN
  resp := BS('{"first_failure":{"detail":');
  Json.Quote(msg, resp);
  BStr.AppendStr(resp, '},"impl":');
  Json.QuoteStr(IMPL, resp);
  BStr.AppendStr(resp, ',"placements_checked":');
  BStr.AppendCardinal(resp, n);
  BStr.AppendStr(resp, ',"verdict":"fail"}');
  RETURN resp;
END VerifyFail;

PROCEDURE VerifyFailS (n : CARDINAL; msg : ARRAY OF CHAR) : Bytes;
BEGIN
  RETURN VerifyFail(n, BS(msg));
END VerifyFailS;

(* Split text into lines on \n; calls LineProc per trimmed line via a
   global-free design: returns count and fills arrays. *)
PROCEDURE DoVerify (state, pubkeys : Bytes) : Bytes;
  VAR m, seen, idxm : Phext.Map;
      keysT, khT, idxT, t : Bytes;
      checked, seq : CARDINAL;
      prevHash, evCs, evText : Bytes;
      ev, body, prevN : Json.JVal; jok : BOOLEAN;
      csB, textHash, fileHash, attB64, turnRaw, actor : Bytes;
      desc, err, sigData, canon : Bytes;
      il : Bytes; words : ARRAY [0..7] OF Bytes; nw : CARDINAL;
      li, lj, lstart : CARDINAL; line : Bytes;
      c : Coord; resp : Bytes;
BEGIN
  m := Phext.NewMap();
  Phext.Explode(state, m);
  keysT := FetchCs(m, BS(KEYSCS));
  IF (keysT = NIL) OR (BStr.Len(keysT) = 0) THEN
    RETURN VerifyFailS(0, "no public-keys scroll at 1.1.1/1.1.1/1.1.2");
  END;
  IF NOT BStr.Equal(TrimBoth(pubkeys), TrimBoth(keysT)) THEN
    RETURN VerifyFailS(0, "supplied pubkeys do not match the inscribed keys scroll");
  END;
  khT := FetchCs(m, BS(KHCS));
  IF khT = NIL THEN
    RETURN VerifyFailS(0, "no keys-hash scroll at 1.1.1/1.1.1/1.1.3");
  END;
  IF NOT BStr.Equal(TrimBoth(khT), Sha256Hex(keysT)) THEN
    RETURN VerifyFailS(0, "keys-hash scroll does not match the keys scroll");
  END;
  idxm := Phext.NewMap();
  idxT := FetchCs(m, BS(INDEXCS));
  IF idxT <> NIL THEN
    li := 0;
    WHILE li < BStr.Len(idxT) DO
      lstart := li;
      WHILE (li < BStr.Len(idxT)) AND (BStr.Get(idxT, li) <> CHR(10)) DO INC(li) END;
      line := TrimBoth(Slice(idxT, lstart, li));
      INC(li);
      IF (BStr.Len(line) > 0) AND (BStr.Get(line, 0) <> '#') THEN
        nw := SplitWords(line, words, 8);
        IF nw <> 4 THEN
          resp := BS("malformed index line: ");
          BStr.AppendBytes(resp, line);
          RETURN VerifyFail(0, resp);
        END;
        IF CoordOf(words[1], c) THEN
          Phext.MapUpdate(idxm, c, line, TRUE);
        END;
      END;
    END;
  END;
  seen := Phext.NewMap();
  checked := 0;
  prevHash := BStr.New();
  seq := 0;
  LOOP
    INC(seq);
    evCs := BS("1.1.1/1.1.1/2.1.");
    BStr.AppendCardinal(evCs, seq);
    evText := FetchCs(m, evCs);
    IF evText = NIL THEN EXIT END;
    ev := Json.Parse(evText, jok);
    IF NOT jok THEN
      resp := BS("event ");
      BStr.AppendCardinal(resp, seq);
      BStr.AppendStr(resp, " is not JSON");
      RETURN VerifyFail(checked, resp);
    END;
    body := Json.Get(ev, "body");
    IF body = 0 THEN
      resp := BS("event ");
      BStr.AppendCardinal(resp, seq);
      BStr.AppendStr(resp, " lacks a body object");
      RETURN VerifyFail(checked, resp);
    END;
    prevN := Json.Get(ev, "prev");
    IF seq = 1 THEN
      IF NOT Json.IsNull(prevN) THEN
        RETURN VerifyFailS(checked, "event 1 prev is not null");
      END;
    ELSE
      IF (Json.TypeOf(prevN) <> Json.JStr) OR NOT BStr.Equal(JStrOf(prevN), prevHash) THEN
        resp := BS("event chain broken at seq ");
        BStr.AppendCardinal(resp, seq);
        RETURN VerifyFail(checked, resp);
      END;
    END;
    (* prev_hash for the next event = sha256 of canonical body *)
    canon := BStr.New();
    Json.Canon(body, canon);
    prevHash := Sha256Hex(canon);
    BStr.Dispose(canon);
    IF (Json.Get(body, "type") = 0) OR NOT BStr.EqualStr(JStrOf(Json.Get(body, "type")), "placement") THEN
      (* not a placement event: continue the chain walk *)
    ELSE
      IF (Json.Get(body, "coord") = 0) OR (Json.Get(body, "text_sha256") = 0)
         OR (Json.Get(body, "file_sha256") = 0) OR (Json.Get(body, "att") = 0) THEN
        resp := BS("event ");
        BStr.AppendCardinal(resp, seq);
        BStr.AppendStr(resp, " lacks placement fields");
        RETURN VerifyFail(checked, resp);
      END;
      csB := JStrOf(Json.Get(body, "coord"));
      textHash := JStrOf(Json.Get(body, "text_sha256"));
      fileHash := JStrOf(Json.Get(body, "file_sha256"));
      attB64 := JStrOf(Json.Get(body, "att"));
      turnRaw := JNumRaw(Json.Get(body, "turn"));
      actor := JStrOf(Json.Get(body, "actor"));
      IF NOT CoordOf(csB, c) THEN RETURN VerifyFailS(checked, "bad placement coordinate") END;
      IF Phext.MapFind(seen, c) >= 0 THEN
        resp := BS("coordinate reused at ");
        BStr.AppendBytes(resp, csB);
        RETURN VerifyFail(checked, resp);
      END;
      t := Phext.MapFetch(m, c);
      IF t = NIL THEN
        resp := BS("placement missing at ");
        BStr.AppendBytes(resp, csB);
        RETURN VerifyFail(checked, resp);
      END;
      IF NOT BStr.Equal(Sha256Hex(t), textHash) THEN
        resp := BS("placement hash mismatch at ");
        BStr.AppendBytes(resp, csB);
        RETURN VerifyFail(checked, resp);
      END;
      il := Phext.MapFetch(idxm, c);
      IF il = NIL THEN
        resp := BS("index mismatch at ");
        BStr.AppendBytes(resp, csB);
        RETURN VerifyFail(checked, resp);
      END;
      nw := SplitWords(il, words, 8);
      IF (nw <> 4) OR NOT BStr.Equal(words[2], textHash)
         OR NOT BStr.Equal(words[0], turnRaw) OR NOT BStr.Equal(words[3], actor) THEN
        resp := BS("index mismatch at ");
        BStr.AppendBytes(resp, csB);
        RETURN VerifyFail(checked, resp);
      END;
      desc := BS('{"coordinate":');
      Json.Quote(csB, desc);
      BStr.AppendStr(desc, ',"file_sha256":');
      Json.Quote(fileHash, desc);
      BStr.AppendStr(desc, ',"scroll_sha256":');
      Json.Quote(textHash, desc);
      BStr.AppendStr(desc, ',"turn":');
      BStr.AppendBytes(desc, turnRaw);
      BStr.AppendCh(desc, '}');
      sigData := B64Dec(attB64);
      err := VerifySignature(pubkeys, desc, sigData);
      IF BStr.Len(err) > 0 THEN
        resp := BS("event ");
        BStr.AppendCardinal(resp, seq);
        BStr.AppendStr(resp, " signature: ");
        BStr.AppendBytes(resp, err);
        RETURN VerifyFail(checked, resp);
      END;
      Phext.MapUpdate(seen, c, BS("x"), TRUE);
      INC(checked);
    END;
  END;
  IF checked = 0 THEN RETURN VerifyFailS(0, "no placement events found") END;
  (* every index coord must have an event *)
  IF idxT <> NIL THEN
    li := 0;
    WHILE li < BStr.Len(idxT) DO
      lstart := li;
      WHILE (li < BStr.Len(idxT)) AND (BStr.Get(idxT, li) <> CHR(10)) DO INC(li) END;
      line := TrimBoth(Slice(idxT, lstart, li));
      INC(li);
      IF (BStr.Len(line) > 0) AND (BStr.Get(line, 0) <> '#') THEN
        nw := SplitWords(line, words, 8);
        IF (nw >= 2) AND CoordOf(words[1], c) THEN
          IF Phext.MapFind(seen, c) < 0 THEN
            resp := BS("index lists a placement with no event: ");
            BStr.AppendBytes(resp, words[1]);
            RETURN VerifyFail(checked, resp);
          END;
        END;
      END;
    END;
  END;
  resp := BS('{"first_failure":null,"impl":');
  Json.QuoteStr(IMPL, resp);
  BStr.AppendStr(resp, ',"placements_checked":');
  BStr.AppendCardinal(resp, checked);
  BStr.AppendStr(resp, ',"verdict":"pass"}');
  RETURN resp;
END DoVerify;

(* ---------- dispatch ---------- *)

PROCEDURE HandleLine (line0 : Bytes) : Bytes;
  VAR line, resp, cmd : Bytes;
      req, node : Json.JVal; jok : BOOLEAN;
      state, pos : Bytes; turn : LONGINT;
      canon, e : Bytes;
BEGIN
  line := line0;
  IF StartsWith(line, "GZ1:") THEN
    line := GzUnframe(Slice(line, 4, BStr.Len(line)));
  END;
  req := Json.Parse(line, jok);
  IF NOT jok THEN RETURN BS('{"error":"parse error"}') END;
  node := Json.Get(req, "cmd");
  IF node = 0 THEN RETURN BS('{"error":"no cmd"}') END;
  cmd := JStrOf(node);
  IF BStr.EqualStr(cmd, "id") THEN
    resp := BS('{"impl":');
    Json.QuoteStr(IMPL, resp);
    BStr.AppendCh(resp, '}');
    RETURN resp;
  ELSIF BStr.EqualStr(cmd, "echo") THEN
    resp := BS('{"echo":');
    Json.Quote(EchoValue(Json.Get(req, "ping")), resp);
    BStr.AppendStr(resp, ',"impl":');
    Json.QuoteStr(IMPL, resp);
    BStr.AppendCh(resp, '}');
    RETURN resp;
  ELSIF BStr.EqualStr(cmd, "elect") THEN
    pos := JStrOf(Json.Get(req, "position"));
    turn := Json.IntVal(Json.Get(req, "turn"));
    resp := BS('{"elect":');
    Json.Quote(ElectWinner(pos, Json.Get(req, "candidates"), turn), resp);
    BStr.AppendCh(resp, '}');
    RETURN resp;
  ELSIF BStr.EqualStr(cmd, "choose") THEN
    state := B64Dec(JStrOf(Json.Get(req, "state")));
    pos := JStrOf(Json.Get(req, "position"));
    turn := Json.IntVal(Json.Get(req, "turn"));
    RETURN ChooseAdventure(state, pos, turn);
  ELSIF BStr.EqualStr(cmd, "apply") THEN
    state := ReqState(req);
    RETURN ApplyStep(state, Json.Get(req, "step"));
  ELSIF BStr.EqualStr(cmd, "keygen") THEN
    RETURN DoKeygen();
  ELSIF BStr.EqualStr(cmd, "attest") THEN
    canon := BStr.New();
    Json.Canon(Json.Get(req, "descriptor"), canon);
    resp := BS('{"signature":');
    Json.Quote(DetachSign(canon), resp);
    BStr.AppendCh(resp, '}');
    RETURN resp;
  ELSIF BStr.EqualStr(cmd, "init") THEN
    state := ReqState(req);
    IF cacheSet THEN Phext.DisposeMap(cacheMap) END;
    cacheMap := Phext.NewMap();
    Phext.Explode(state, cacheMap);
    cacheSet := TRUE;
    RETURN BS('{"impl":"modula2","verdict":"pass"}');
  ELSIF BStr.EqualStr(cmd, "validate") THEN
    RETURN DoValidate(req);
  ELSIF BStr.EqualStr(cmd, "verify") THEN
    state := ReqState(req);
    RETURN DoVerify(state, JStrOf(Json.Get(req, "pubkeys")));
  END;
  resp := BS('{"error":');
  e := BS("unknown cmd ");
  BStr.AppendBytes(e, cmd);
  Json.Quote(e, resp);
  BStr.AppendCh(resp, '}');
  RETURN resp;
END HandleLine;

PROCEDURE WriteOut (data : Bytes);
  VAR off : CARDINAL; n : LONGINT; chunk : Bytes;
BEGIN
  off := 0;
  WHILE off < BStr.Len(data) DO
    chunk := Slice(data, off, BStr.Len(data));
    n := write(1, BStr.DataAddr(chunk), BStr.Len(chunk));
    BStr.Dispose(chunk);
    IF n <= 0 THEN RETURN END;
    off := off + VAL(CARDINAL, n);
  END;
END WriteOut;

PROCEDURE EmitLine (out : Bytes);
  VAR framed, nl : Bytes;
BEGIN
  IF serving AND (BStr.Len(out) > 8192) THEN
    framed := GzFrame(out);
    WriteOut(framed);
  ELSE
    WriteOut(out);
  END;
  nl := BStr.New();
  BStr.AppendCh(nl, CHR(10));
  WriteOut(nl);
END EmitLine;

(* Read one line (without the trailing \n) from stdin, buffered.
   Returns FALSE at end of input with no data. *)
PROCEDURE ReadLine (VAR line : Bytes) : BOOLEAN;
  VAR i : CARDINAL; buf : ARRAY [0..16383] OF CHAR; n : LONGINT;
BEGIN
  LOOP
    i := inPos;
    WHILE i < BStr.Len(inBuf) DO
      IF BStr.Get(inBuf, i) = CHR(10) THEN
        line := Slice(inBuf, inPos, i);
        inPos := i + 1;
        RETURN TRUE;
      END;
      INC(i);
    END;
    (* no complete line buffered: compact and read more *)
    IF inPos > 0 THEN
      inBuf := Slice(inBuf, inPos, BStr.Len(inBuf));
      inPos := 0;
    END;
    n := read(0, ADR(buf), 16384);
    IF n <= 0 THEN
      IF BStr.Len(inBuf) > inPos THEN
        line := Slice(inBuf, inPos, BStr.Len(inBuf));
        inPos := BStr.Len(inBuf);
        RETURN TRUE;
      END;
      RETURN FALSE;
    END;
    BStr.AppendMem(inBuf, ADR(buf), VAL(CARDINAL, n));
  END;
END ReadLine;

PROCEDURE Main;
  VAR arg : ARRAY [0..255] OF CHAR; got : BOOLEAN;
      line, all, data : Bytes; buf : ARRAY [0..16383] OF CHAR; n : LONGINT;
      cmd : Bytes; rc : INTEGER;
BEGIN
  tmpdir := BS("/tmp/telephone-modula2-");
  BStr.AppendCardinal(tmpdir, VAL(CARDINAL, getpid()));
  cmd := BS("mkdir -p ");
  BStr.AppendBytes(cmd, tmpdir);
  rc := ShellQuiet(cmd);
  tmpCounter := 0;
  serving := FALSE;
  cacheSet := FALSE;
  cacheMap := NIL;
  inBuf := BStr.New();
  inPos := 0;
  IF (Narg() >= 2) THEN
    got := GetArg(arg, 1);
    IF got AND (arg[0] = 's') THEN
      serving := TRUE;
      LOOP
        IF NOT ReadLine(line) THEN EXIT END;
        IF BStr.Len(line) = 0 THEN
          (* blank line: skip *)
        ELSE
          EmitLine(HandleLine(line));
        END;
      END;
      RETURN;
    END;
  END;
  (* one-shot: read all of stdin *)
  all := BStr.New();
  LOOP
    n := read(0, ADR(buf), 16384);
    IF n <= 0 THEN EXIT END;
    BStr.AppendMem(all, ADR(buf), VAL(CARDINAL, n));
  END;
  data := TrimTrail(all);
  IF BStr.Len(data) > 0 THEN
    EmitLine(HandleLine(data));
  END;
END Main;

BEGIN
  Main;
END Telephone.
