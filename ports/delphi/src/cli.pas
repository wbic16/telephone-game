program cli;
{ Hub-side CLI for libphext-delphi (Exocortical Telephone Game,
  contract v2). Transport: no argument = one JSON object on stdin, one
  JSON response on stdout; argument `serve` = one JSON request per
  line. State travels as base64. Phext logic is this port's own unit
  (phext.pas). SHA-256: FPC fcl-hash sha256 unit. Base64: FPC base64
  unit. JSON parse: fpjson; canonical JSON output is serialized here
  (sorted keys, python ensure_ascii escaping) to match the pinned
  formats byte for byte. PGP: subprocess gpg with per-port GNUPGHOME
  ~/telephone-delphi/keys on the hub. }
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, fpjson, jsonparser, base64, sha256, Process, phext;

const
  IMPL = 'delphi';
  KeyHome = '/home/wbic16/telephone-delphi/keys';
  IndexCoordS = '1.1.1/1.1.1/1.1.1';
  KeysCoordS = '1.1.1/1.1.1/1.1.2';
  KHCoordS = '1.1.1/1.1.1/1.1.3';

var
  CacheMap: TScrollArray;
  CacheOK: Boolean = False;

function Sha256Hex(const Data: RawByteString): RawByteString;
begin
  Result := LowerCase(SHA256Print(SHA256String(Data)));
end;

function B64Enc(const Data: RawByteString): RawByteString;
begin
  Result := EncodeStringBase64(Data);
end;

function B64Dec(const S: RawByteString): RawByteString;
begin
  Result := DecodeStringBase64(S, True);
end;

{ latin-1 convention: bytes <-> JSON text (ruby port's text_to_bytes) }
function TextToBytes(const S: RawByteString): RawByteString;
var
  I, CP, N: Integer;
  B: Byte;
begin
  Result := ''; I := 1;
  while I <= Length(S) do
  begin
    B := Ord(S[I]);
    if B < $80 then begin CP := B; N := 1; end
    else if B >= $F0 then begin CP := ((B and $07) shl 18) or
      ((Ord(S[I+1]) and $3F) shl 12) or ((Ord(S[I+2]) and $3F) shl 6) or
      (Ord(S[I+3]) and $3F); N := 4; end
    else if B >= $E0 then begin CP := ((B and $0F) shl 12) or
      ((Ord(S[I+1]) and $3F) shl 6) or (Ord(S[I+2]) and $3F); N := 3; end
    else begin CP := ((B and $1F) shl 6) or (Ord(S[I+1]) and $3F); N := 2; end;
    if CP < 256 then Result := Result + Chr(CP)
    else Result := Result + Copy(S, I, N);
    Inc(I, N);
  end;
end;

function BytesToText(const Data: RawByteString): RawByteString;
var I: Integer; B: Byte;
begin
  Result := '';
  for I := 1 to Length(Data) do
  begin
    B := Ord(Data[I]);
    if B < $80 then Result := Result + Chr(B)
    else Result := Result + Chr($C0 or (B shr 6)) + Chr($80 or (B and $3F));
  end;
end;

{ ---- canonical JSON: sorted keys, separators , and :, ensure_ascii -- }
function CanonStr(const S: RawByteString): RawByteString;
var
  I, CP, N: Integer;
  B: Byte;
begin
  Result := '"'; I := 1;
  while I <= Length(S) do
  begin
    B := Ord(S[I]);
    if B < $80 then begin CP := B; N := 1; end
    else if B >= $F0 then begin CP := ((B and $07) shl 18) or
      ((Ord(S[I+1]) and $3F) shl 12) or ((Ord(S[I+2]) and $3F) shl 6) or
      (Ord(S[I+3]) and $3F); N := 4; end
    else if B >= $E0 then begin CP := ((B and $0F) shl 12) or
      ((Ord(S[I+1]) and $3F) shl 6) or (Ord(S[I+2]) and $3F); N := 3; end
    else begin CP := ((B and $1F) shl 6) or (Ord(S[I+1]) and $3F); N := 2; end;
    case CP of
      $22: Result := Result + '\"';
      $5C: Result := Result + '\\';
      $0A: Result := Result + '\n';
      $0D: Result := Result + '\r';
      $09: Result := Result + '\t';
      $08: Result := Result + '\b';
      $0C: Result := Result + '\f';
    else
      if (CP >= $20) and (CP < $7F) then Result := Result + Chr(CP)
      else if CP <= $FFFF then
        Result := Result + Format('\u%.4x', [CP])
      else
      begin
        CP := CP - $10000;
        Result := Result + Format('\u%.4x\u%.4x',
          [$D800 + (CP shr 10), $DC00 + (CP and $3FF)]);
      end;
    end;
    Inc(I, N);
  end;
  Result := Result + '"';
end;

function Canon(V: TJSONData): RawByteString;
var
  I: Integer;
  Obj: TJSONObject;
  Arr: TJSONArray;
  Keys: TStringList;
begin
  if V = nil then Exit('null');
  case V.JSONType of
    jtString: Result := CanonStr(V.AsString);
    jtNumber:
      if V is TJSONFloatNumber then
      begin
        if Frac(V.AsFloat) = 0 then Result := IntToStr(Round(V.AsFloat))
        else Result := FloatToStr(V.AsFloat);
      end
      else Result := V.AsString;
    jtBoolean: if V.AsBoolean then Result := 'true' else Result := 'false';
    jtArray:
    begin
      Arr := TJSONArray(V); Result := '[';
      for I := 0 to Arr.Count - 1 do
      begin
        if I > 0 then Result := Result + ',';
        Result := Result + Canon(Arr.Items[I]);
      end;
      Result := Result + ']';
    end;
    jtObject:
    begin
      Obj := TJSONObject(V);
      Keys := TStringList.Create;
      try
        for I := 0 to Obj.Count - 1 do Keys.Add(Obj.Names[I]);
        Keys.Sort;
        Result := '{';
        for I := 0 to Keys.Count - 1 do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + CanonStr(Keys[I]) + ':' +
            Canon(Obj.Find(Keys[I]));
        end;
        Result := Result + '}';
      finally
        Keys.Free;
      end;
    end;
  else
    Result := 'null';
  end;
end;

function JObj: TJSONObject;
begin Result := TJSONObject.Create; end;

function RunCmd(const Cmd: RawByteString; const Args: TStringArray;
  const StdinData: RawByteString; out ExitCode: Integer): RawByteString;
var
  Proc: TProcess;
  MS: TMemoryStream;
  I: Integer;
  Buf: array[0..8191] of Byte;
  N: Integer;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := Cmd;
    for I := 0 to High(Args) do Proc.Parameters.Add(Args[I]);
    Proc.Options := [poUsePipes, poStdErrToOutPut];
    Proc.Execute;
    if Length(StdinData) > 0 then
      Proc.Input.WriteBuffer(StdinData[1], Length(StdinData));
    Proc.CloseInput;
    MS := TMemoryStream.Create;
    try
      repeat
        N := Proc.Output.Read(Buf, SizeOf(Buf));
        if N > 0 then MS.WriteBuffer(Buf, N);
      until N <= 0;
      Proc.WaitOnExit;
      ExitCode := Proc.ExitCode;
      SetLength(Result, MS.Size);
      if MS.Size > 0 then
      begin
        MS.Position := 0;
        MS.ReadBuffer(Result[1], MS.Size);
      end
      else Result := '';
    finally
      MS.Free;
    end;
  finally
    Proc.Free;
  end;
end;

function GpgRun(const Args: array of RawByteString;
  const StdinData: RawByteString; const Home: RawByteString;
  out ExitCode: Integer): RawByteString;
var
  CmdLine: RawByteString;
  I: Integer;
begin
  { gpg is invoked through /bin/sh -c (the COBOL/Fortran ports'
    pattern): a directly exec'd gpg-agent fails key generation for
    GNUPGHOME under /home on the hub ("agent_genkey failed: No such
    file or directory") while the shell route works. All arguments
    are controlled tokens without quotes; data travels via stdin. }
  CmdLine := 'GNUPGHOME=''' + Home + ''' exec gpg --batch';
  for I := 0 to High(Args) do
    CmdLine := CmdLine + ' ''' + Args[I] + '''';
  Result := RunCmd('/bin/sh', TStringArray.Create('-c', CmdLine),
    StdinData, ExitCode);
end;

procedure EnsureKeyHome;
var
  EC: Integer;
begin
  ForceDirectories(KeyHome);
  EC := 0;
  RunCmd('/bin/chmod', TStringArray.Create('700', KeyHome), '', EC);
end;

function EnsureKey: RawByteString;
var
  EC: Integer;
  Listing, Pub: RawByteString;
begin
  EnsureKeyHome;
  Listing := GpgRun(['--list-keys', '--with-colons'], '', KeyHome, EC);
  if Pos('pub:', Listing) = 0 then
    GpgRun(['--pinentry-mode', 'loopback', '--passphrase=',
      '--quick-generate-key', 'telephone-delphi', 'ed25519', 'sign',
      'never'], '', KeyHome, EC);
  Pub := GpgRun(['--armor', '--export', 'telephone-delphi'], '', KeyHome, EC);
  Result := Trim(Pub);
end;

function SignDescriptor(Desc: TJSONData): RawByteString;
var
  EC: Integer;
  Sig: RawByteString;
begin
  EnsureKey;
  Sig := GpgRun(['--pinentry-mode', 'loopback', '--passphrase=',
    '--detach-sign', '--armor', '-u', 'telephone-delphi'],
    Canon(Desc), KeyHome, EC);
  if EC <> 0 then raise Exception.Create('attest signing failed');
  Result := Trim(Sig);
end;

function VerifySignature(const Pubkeys, SigB64: RawByteString;
  const Data: RawByteString): Boolean;
var
  EC: Integer;
  Home, SigFile, DataFile: RawByteString;
  FS: TFileStream;
  Sig: RawByteString;
begin
  Result := False;
  Home := GetTempDir(False) + 'tel-delphi-gpg-' + IntToStr(GetTickCount64);
  ForceDirectories(Home);
  RunCmd('/bin/chmod', TStringArray.Create('700', Home), '', EC);
  try
    GpgRun(['--import'], Pubkeys, Home, EC);
    if EC <> 0 then Exit;
    Sig := B64Dec(SigB64);
    SigFile := Home + '/sig.asc'; DataFile := Home + '/data';
    FS := TFileStream.Create(SigFile, fmCreate);
    try if Length(Sig) > 0 then FS.WriteBuffer(Sig[1], Length(Sig)); finally FS.Free; end;
    FS := TFileStream.Create(DataFile, fmCreate);
    try if Length(Data) > 0 then FS.WriteBuffer(Data[1], Length(Data)); finally FS.Free; end;
    RunCmd('/usr/bin/env', TStringArray.Create(
      'GNUPGHOME=' + Home, 'gpg', '--batch', '--verify', SigFile,
      DataFile), '', EC);
    Result := EC = 0;
  finally
    RunCmd('/bin/rm', TStringArray.Create('-rf', Home), '', EC);
  end;
end;

function StateOf(Req: TJSONObject): RawByteString;
var S: RawByteString;
begin
  S := Req.Get('state', '');
  if S = '' then S := Req.Get('state_b64', '');
  Result := B64Dec(S);
end;

function MapFind(const Map: TScrollArray; const C: TCoord;
  out Text: RawByteString): Boolean;
var I: Integer;
begin
  for I := 0 to High(Map) do
    if CoordEq(Map[I].Coord, C) then
    begin
      Text := Map[I].Text; Exit(True);
    end;
  Result := False; Text := '';
end;

function ApplyStep(const Data: RawByteString; Step: TJSONObject;
  out FetchSha: RawByteString): RawByteString;
var
  Op: RawByteString;
  C: TCoord;
  Map: TScrollArray;
  I: Integer;
  Txt: RawByteString;
  Done: Boolean;
begin
  Op := Step.Get('op', '');
  C := ParseCoord(Step.Get('coordinate', '1.1.1/1.1.1/1.1.1'));
  FetchSha := '';
  if (Op = 'fetch') or (Op = 'navigate') then
  begin
    FetchSha := Sha256Hex(Fetch(Data, C));
    Exit(Data);
  end;
  Map := Phokenize(Data);
  Done := False;
  for I := 0 to High(Map) do
  begin
    if CoordEq(Map[I].Coord, C) then
    begin
      Done := True;
      if Op = 'insert' then
        Map[I].Text := Map[I].Text + TextToBytes(Step.Get('text', ''))
      else if Op = 'replace' then
        Map[I].Text := TextToBytes(Step.Get('text', ''))
      else if Op = 'remove' then
        Map[I].Text := ''
      else raise Exception.Create('unknown op ' + Op);
    end;
  end;
  if not Done then
  begin
    if Op = 'remove' then Exit(Dephokenize(Map));
    SetLength(Map, Length(Map) + 1);
    Map[High(Map)].Coord := C;
    Map[High(Map)].Text := TextToBytes(Step.Get('text', ''));
  end;
  { drop empties (remove semantics) }
  Result := Dephokenize(Map);
  if Op <> 'remove' then
  begin
    { Dephokenize already skips empty scrolls }
  end;
  Txt := '';
end;

function VFail(N: Integer; const Msg: RawByteString): TJSONObject;
var F: TJSONObject;
begin
  Result := JObj;
  Result.Add('impl', IMPL);
  Result.Add('verdict', 'fail');
  Result.Add('placements_checked', N);
  F := JObj; F.Add('detail', Msg);
  Result.Add('first_failure', F);
end;

function VerifyStress(const Data: RawByteString;
  const PubkeysArg: RawByteString): TJSONObject;
var
  Map: TScrollArray;
  KeysText, KHText, IdxText, Txt: RawByteString;
  Events: TScrollArray;
  I, J, Checked: Integer;
  PrevHash: RawByteString;
  PrevSet: Boolean;
  Ev: TJSONData;
  Body: TJSONObject;
  CoordS: RawByteString;
  C: TCoord;
  Desc: TJSONObject;
  TmpEv: TScroll;
  Placements: TStringList;
  Lines: TStringList;
  Parts: TStringList;
begin
  Map := Phokenize(Data);
  if not MapFind(Map, ParseCoord(KeysCoordS), KeysText) then
    KeysText := '';
  if MapFind(Map, ParseCoord(KHCoordS), KHText) then
  begin
    if Sha256Hex(KeysText) <> Trim(KHText) then
      Exit(VFail(0, 'keys-hash scroll does not match keys'));
  end;
  KeysText := BytesToText(KeysText);
  { events at 1.1.1/1.1.1/2.1.<seq> sorted by seq }
  SetLength(Events, 0);
  for I := 0 to High(Map) do
  begin
    C := Map[I].Coord;
    if (C[0] = 1) and (C[1] = 1) and (C[2] = 1) and (C[3] = 1) and
       (C[4] = 1) and (C[5] = 1) and (C[6] = 2) and (C[7] = 1) then
    begin
      SetLength(Events, Length(Events) + 1);
      Events[High(Events)] := Map[I];
    end;
  end;
  { insertion sort by seq }
  for I := 1 to High(Events) do
  begin
    TmpEv := Events[I]; J := I - 1;
    while (J >= 0) and (Events[J].Coord[8] > TmpEv.Coord[8]) do
    begin
      Events[J + 1] := Events[J]; Dec(J);
    end;
    Events[J + 1] := TmpEv;
  end;
  Checked := 0;
  PrevHash := ''; PrevSet := False;
  Placements := TStringList.Create;
  try
    for I := 0 to High(Events) do
    begin
      if Events[I].Coord[8] <> I + 1 then
        Exit(VFail(Checked, 'event seq gap'));
      Ev := GetJSON(Events[I].Text);
      try
        if (Ev.FindPath('prev') = nil) or
           ((not PrevSet) and (Ev.FindPath('prev').JSONType <> jtNull)) or
           (PrevSet and ((Ev.FindPath('prev').JSONType <> jtString) or
             (Ev.FindPath('prev').AsString <> PrevHash))) then
          Exit(VFail(Checked, 'event chain broken'));
        Body := TJSONObject(Ev.FindPath('body'));
        PrevHash := Sha256Hex(Canon(Body));
        PrevSet := True;
        if Body.Get('type', '') = 'placement' then
        begin
          CoordS := Body.Get('coord', '');
          if Placements.IndexOf(CoordS) >= 0 then
            Exit(VFail(Checked, 'coordinate reused'));
          C := ParseCoord(CoordS);
          if not MapFind(Map, C, Txt) then
            Exit(VFail(Checked, 'placement scroll missing'));
          if Sha256Hex(Txt) <> Body.Get('text_sha256', '') then
            Exit(VFail(Checked, 'placement scroll hash mismatch'));
          Desc := JObj;
          Desc.Add('turn', Body.Get('turn', 0));
          Desc.Add('coordinate', CoordS);
          Desc.Add('scroll_sha256', Body.Get('text_sha256', ''));
          Desc.Add('file_sha256', Body.Get('file_sha256', ''));
          if not VerifySignature(KeysText, Body.Get('att', ''),
                   Canon(Desc)) then
          begin
            Desc.Free;
            Exit(VFail(Checked, 'attestation fails'));
          end;
          Desc.Free;
          Placements.Add(CoordS + '=' + Body.Get('text_sha256', ''));
          Inc(Checked);
        end;
      finally
        Ev.Free;
      end;
    end;
    { index check }
    if not MapFind(Map, ParseCoord(IndexCoordS), IdxText) then IdxText := '';
    Lines := TStringList.Create;
    try
      Lines.Text := BytesToText(IdxText);
      J := 0;
      for I := 0 to Lines.Count - 1 do
      begin
        if (Lines[I] = '') or (Lines[I][1] = '#') then Continue;
        Inc(J);
        Parts := TStringList.Create;
        try
          Parts.Delimiter := ' ';
          Parts.DelimitedText := Lines[I];
          if Parts.Count >= 3 then
          begin
            if Placements.IndexOf(Parts[1] + '=' + Parts[2]) < 0 then
              Exit(VFail(Checked, 'index hash mismatch'));
          end;
        finally
          Parts.Free;
        end;
      end;
      if J <> Checked then
        Exit(VFail(Checked, 'index lines != placements'));
    finally
      Lines.Free;
    end;
  finally
    Placements.Free;
  end;
  Result := JObj;
  Result.Add('impl', IMPL);
  Result.Add('verdict', 'pass');
  Result.Add('placements_checked', Checked);
  Result.Add('first_failure', TJSONNull.Create);
end;

function Dispatch(Req: TJSONObject): TJSONData;
var
  Cmd, S, T: RawByteString;
  O: TJSONObject;
  Data: RawByteString;
  Map: TScrollArray;
  I: Integer;
  C: TCoord;
  FS: RawByteString;
  Pool: TStringList;
  Idx: Integer;
  Step, Step2: TJSONObject;
  Prior, NewMap, NewMap2: TScrollArray;
  CC, CC2, EV2: TCoord;
  PT, PT2, Bad, Bad2: RawByteString;
  Added: Integer;
  Inner, Inner2: TJSONObject;
  Arr: TScrollArray;
begin
  Cmd := Req.Get('cmd', '');
  if Cmd = 'id' then
  begin
    O := JObj; O.Add('impl', IMPL); Exit(O);
  end
  else if Cmd = 'keygen' then
  begin
    O := JObj; O.Add('impl', IMPL); O.Add('pubkey', EnsureKey); Exit(O);
  end
  else if Cmd = 'echo' then
  begin
    O := JObj; O.Add('impl', IMPL);
    O.Add('echo', Sha256Hex('{"impl":"' + IMPL + '","ping":' +
      Canon(Req.Find('ping')) + '}'));
    Exit(O);
  end
  else if Cmd = 'elect' then
  begin
    { sha256 of "<impl>-elect:<position>:<turn>:<candidates csv>" }
    S := '';
    with Req.Find('candidates') as TJSONArray do
      for I := 0 to Count - 1 do
      begin
        if I > 0 then S := S + ',';
        S := S + Items[I].AsString;
      end;
    T := Sha256Hex(IMPL + '-elect:' + Req.Get('position', '') + ':' +
      IntToStr(Req.Get('turn', 0)) + ':' + S);
    { pool: candidates other than itself }
    O := JObj;
    with Req.Find('candidates') as TJSONArray do
    begin
      S := '';
      for I := 0 to Count - 1 do
        if Items[I].AsString <> IMPL then
        begin
          if S = '' then S := Items[I].AsString;
        end;
      { deterministic pick: first non-self by hash order is overkill;
        use hash mod pool size }
      begin
        { build pool list }
      end;
    end;
    { simpler: recompute pool }
    begin
      Pool := TStringList.Create;
      try
        with Req.Find('candidates') as TJSONArray do
          for I := 0 to Count - 1 do
            if Items[I].AsString <> IMPL then Pool.Add(Items[I].AsString);
        if Pool.Count = 0 then
          with Req.Find('candidates') as TJSONArray do
            for I := 0 to Count - 1 do Pool.Add(Items[I].AsString);
        Idx := StrToInt('$' + Copy(T, 1, 8)) mod Pool.Count;
        O.Add('elect', Pool[Idx]);
      finally
        Pool.Free;
      end;
    end;
    Exit(O);
  end
  else if Cmd = 'choose' then
  begin
    Data := StateOf(Req);
    Map := Phokenize(Data);
    C := ParseCoord(Req.Get('position', '1.1.1/1.1.1/1.1.1'));
    while MapFind(Map, C, T) do C[8] := C[8] + 1;
    O := JObj;
    O.Add('op', 'insert');
    O.Add('coordinate', CoordStr(C));
    O.Add('text', IMPL + ' was here, turn ' + IntToStr(Req.Get('turn', 0)));
    Exit(O);
  end
  else if Cmd = 'apply' then
  begin
    Data := ApplyStep(StateOf(Req),
      TJSONObject(Req.Find('step')), FS);
    O := JObj;
    O.Add('state_b64', B64Enc(Data));
    O.Add('state_sha256', Sha256Hex(Data));
    if FS <> '' then O.Add('fetch_sha256', FS);
    Exit(O);
  end
  else if Cmd = 'attest' then
  begin
    O := JObj;
    O.Add('signature', B64Enc(SignDescriptor(Req.Find('descriptor'))));
    Exit(O);
  end
  else if Cmd = 'init' then
  begin
    CacheMap := Phokenize(StateOf(Req));
    CacheOK := True;
    O := JObj; O.Add('impl', IMPL); O.Add('verdict', 'pass'); Exit(O);
  end
  else if Cmd = 'validate' then
  begin
    Data := StateOf(Req);
    if Req.Find('prior_state') <> nil then
    begin
      { wire form: placed scroll present with step text; no prior
        scroll overwritten; exactly one added scroll }
      Step := TJSONObject(Req.Find('step'));
      CC := ParseCoord(Step.Get('coordinate', ''));
      NewMap := Phokenize(Data);
      Prior := Phokenize(B64Dec(Req.Get('prior_state', '')));
      Bad := '';
      if not MapFind(NewMap, CC, PT) then Bad := 'placed scroll missing'
      else if PT <> TextToBytes(Step.Get('text', '')) then
        Bad := 'placed scroll text != step text'
      else
      begin
        for I := 0 to High(Prior) do
          if not MapFind(NewMap, Prior[I].Coord, PT) or
             (PT <> Prior[I].Text) then
          begin
            Bad := 'prior scroll overwritten'; Break;
          end;
        if Bad = '' then
        begin
          Added := 0;
          for I := 0 to High(NewMap) do
            if not MapFind(Prior, NewMap[I].Coord, PT) then Inc(Added);
          if Added <> 1 then Bad := 'expected exactly one added scroll';
        end;
      end;
      O := JObj; O.Add('impl', IMPL);
      if Bad = '' then O.Add('verdict', 'pass')
      else begin O.Add('verdict', 'fail'); O.Add('detail', Bad); end;
      Exit(O);
    end;
    { driver form: cached map from init }
    if not CacheOK then
    begin
      O := JObj; O.Add('impl', IMPL); O.Add('verdict', 'fail');
      O.Add('detail', 'validate before init'); Exit(O);
    end;
    Step2 := TJSONObject(Req.Find('step'));
    CC2 := ParseCoord(Step2.Get('coordinate', ''));
    EV2 := ParseCoord(Req.Get('event_coord', ''));
    NewMap2 := Phokenize(Data);
    Bad2 := '';
    if not MapFind(NewMap2, CC2, PT2) or
       (PT2 <> TextToBytes(Step2.Get('text', ''))) then
      Bad2 := 'placed scroll missing or altered'
    else
    begin
      for I := 0 to High(CacheMap) do
      begin
        if CoordEq(CacheMap[I].Coord, ParseCoord(IndexCoordS)) then Continue;
        if not MapFind(NewMap2, CacheMap[I].Coord, PT2) or
           (PT2 <> CacheMap[I].Text) then
        begin
          Bad2 := 'prior scroll overwritten'; Break;
        end;
      end;
      if Bad2 = '' then
        for I := 0 to High(NewMap2) do
          if not MapFind(CacheMap, NewMap2[I].Coord, PT2) and
             not CoordEq(NewMap2[I].Coord, CC2) and
             not CoordEq(NewMap2[I].Coord, EV2) then
          begin
            Bad2 := 'unexpected new scroll'; Break;
          end;
      if Bad2 = '' then
      begin
        if not MapFind(NewMap2, ParseCoord(IndexCoordS), PT2) then
          Bad2 := 'index missing'
        else if Pos(Req.Get('index_line', ''), BytesToText(PT2)) = 0 then
          Bad2 := 'index does not record the placement';
      end;
    end;
    O := JObj; O.Add('impl', IMPL);
    if Bad2 = '' then
    begin
      O.Add('verdict', 'pass');
      CacheMap := NewMap2;
    end
    else begin O.Add('verdict', 'fail'); O.Add('detail', Bad2); end;
    Exit(O);
  end
  else if Cmd = 'verify' then
  begin
    Exit(VerifyStress(StateOf(Req), Req.Get('pubkeys', '')));
  end
  else if Cmd = 'fetch' then
  begin
    O := JObj;
    T := Fetch(StateOf(Req), ParseCoord(Req.Get('coordinate', '')));
    O.Add('text_b64', B64Enc(T));
    O.Add('text', BytesToText(T));
    Exit(O);
  end
  else if Cmd = 'explode' then
  begin
    Map := Phokenize(StateOf(Req));
    O := JObj;
    Inner := JObj;
    for I := 0 to High(Map) do
      Inner.Add(CoordStr(Map[I].Coord), B64Enc(Map[I].Text));
    O.Add('map', Inner);
    Exit(O);
  end
  else if Cmd = 'implode' then
  begin
    Inner2 := TJSONObject(Req.Find('map'));
    SetLength(Arr, Inner2.Count);
    for I := 0 to Inner2.Count - 1 do
    begin
      Arr[I].Coord := ParseCoord(Inner2.Names[I]);
      Arr[I].Text := B64Dec(Inner2.Items[I].AsString);
    end;
    Data := Dephokenize(Arr);
    O := JObj;
    O.Add('state_b64', B64Enc(Data));
    O.Add('state_sha256', Sha256Hex(Data));
    Exit(O);
  end
  else if Cmd = 'insert' then
  begin
    Data := StateOf(Req);
    C := ParseCoord(Req.Get('coordinate', ''));
    Map := Phokenize(Data);
    if MapFind(Map, C, T) then
    begin
      O := JObj; O.Add('error', 'coordinate already occupied'); Exit(O);
    end;
    Data := Insert(Data, C, B64Dec(Req.Get('text_b64', '')));
    O := JObj;
    O.Add('state_b64', B64Enc(Data));
    O.Add('state_sha256', Sha256Hex(Data));
    Exit(O);
  end;
  raise Exception.Create('unknown cmd ' + Cmd);
end;

function GzUnframe(const Line: RawByteString): RawByteString;
var
  EC: Integer;
begin
  { Game-scale framing (wave-2 pattern): lines over 8 KB may arrive
    as "GZ1:" + base64(gzip(line)); plain lines pass through. }
  if Copy(Line, 1, 4) = 'GZ1:' then
    Result := RunCmd('/bin/sh',
      TStringArray.Create('-c', 'base64 -d 2>/dev/null | gzip -dc'),
      Copy(Line, 5, Length(Line)), EC)
  else
    Result := Line;
end;

function GzFrame(const Resp: RawByteString): RawByteString;
var
  EC: Integer;
begin
  if Length(Resp) > 8192 then
    Result := 'GZ1:' + Trim(RunCmd('/bin/sh',
      TStringArray.Create('-c', 'gzip -c | base64 -w0'), Resp, EC))
  else
    Result := Resp;
end;

procedure HandleLine(const Line: RawByteString);
var
  Req: TJSONData;
  Out: TJSONData;
  Err: TJSONObject;
begin
  try
    Req := GetJSON(GzUnframe(Line));
    try
      Out := Dispatch(TJSONObject(Req));
      WriteLn(GzFrame(Canon(Out)));
      Out.Free;
    finally
      Req.Free;
    end;
  except
    on E: Exception do
    begin
      Err := JObj;
      Err.Add('error', E.Message);
      WriteLn(Canon(Err));
      Err.Free;
    end;
  end;
  Flush(Output);
end;

var
  Line: RawByteString;
begin
  if (ParamCount >= 1) and (ParamStr(1) = 'serve') then
  begin
    while not EOF do
    begin
      ReadLn(Line);
      if Trim(Line) = '' then Continue;
      HandleLine(Line);
    end;
  end
  else
  begin
    Line := '';
    while not EOF do
    begin
      ReadLn(Line);
      HandleLine(Line);
      Break;
    end;
  end;
end.
