program test_phext;
{ Test suite for libphext-delphi -- plain assertions, no dependencies.
  Run: test_phext [fixtures_dir] -- fixtures are directories containing
  input.phext (the libphext-rs conformance fixtures); each must round
  trip byte-identically (normalize(input) = input) and normalize must
  be idempotent. Also covers the coordinate-preserving REMOVE rule,
  DynamicPhext and TransitivePhext equivalence with the string API. }
{$mode objfpc}{$H+}
uses SysUtils, Classes, phext;

var
  Checks, Failures: Integer;

procedure Ok(Cond: Boolean; const Name: RawByteString);
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failures);
    WriteLn(StdErr, 'FAIL: ', Name);
  end;
end;

procedure Eq(const A, B, Name: RawByteString);
begin
  Ok(A = B, Name + ' (got len ' + IntToStr(Length(A)) +
     ', want len ' + IntToStr(Length(B)) + ')');
end;

function C(const S: RawByteString): TCoord;
begin Result := ParseCoord(S); end;

function ReadFileBytes(const Path: RawByteString): RawByteString;
var FS: TFileStream;
begin
  FS := TFileStream.Create(Path, fmOpenRead);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

procedure FindFixtures(const Dir: RawByteString;
  Files: TStringList);
var
  SR: TSearchRec;
begin
  if FindFirst(Dir + '/*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        FindFixtures(Dir + '/' + SR.Name, Files)
      else if SR.Name = 'input.phext' then
        Files.Add(Dir + '/' + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

var
  Sc: TScrollArray;
  Buf, Out: RawByteString;
  Dyn: TDynStore;
  Trn: TTransStore;
  Files: TStringList;
  I, Identical, Idem: Integer;
  Data: RawByteString;
begin
  Checks := 0; Failures := 0;
  { coordinate }
  Eq(CoordStr(C('1.2.3/4.5.6/7.8.9')), '1.2.3/4.5.6/7.8.9', 'coord format');
  Ok(CoordCmp(C('1.1.1/1.1.1/1.1.1'), C('1.1.1/1.1.1/1.1.2')) < 0, 'order scroll');
  Ok(CoordCmp(C('2.1.1/1.1.1/1.1.1'), C('1.9.9/9.9.9/9.9.9')) > 0, 'order library');
  try
    C('0.1.1/1.1.1/1.1.1'); Ok(False, 'coord rejects 0');
  except Ok(True, 'coord rejects 0'); end;
  try
    C('1.1/1.1.1/1.1.1'); Ok(False, 'coord rejects short');
  except Ok(True, 'coord rejects short'); end;

  { phokenize }
  Sc := Phokenize('hello');
  Ok(Length(Sc) = 1, 'one scroll');
  Eq(CoordStr(Sc[0].Coord), '1.1.1/1.1.1/1.1.1', 'first coord');
  Eq(Sc[0].Text, 'hello', 'first text');
  Sc := Phokenize('a' + #$17 + 'b' + #$17#$17 + 'c' + #$0A + 'line2');
  Ok(Length(Sc) = 3, 'scroll breaks');
  Eq(CoordStr(Sc[1].Coord), '1.1.1/1.1.1/1.1.2', 'second coord');
  Eq(CoordStr(Sc[2].Coord), '1.1.1/1.1.1/1.1.4', 'gap coord advance');
  Eq(Sc[2].Text, 'c' + #$0A + 'line2', 'newline is ordinary text');
  Sc := Phokenize('x' + #$01 + 'y');
  Eq(CoordStr(Sc[1].Coord), '2.1.1/1.1.1/1.1.1', 'library break resets');
  Sc := Phokenize('x' + #$18 + 'y');
  Eq(CoordStr(Sc[1].Coord), '1.1.1/1.1.1/1.2.1', 'section break');
  Ok(Length(Phokenize('')) = 0, 'empty buffer');
  Sc := Phokenize('a' + #$00#$FF + 'b');
  Ok(Length(Sc) = 1, 'binary text is one scroll');
  Ok(Length(Sc[0].Text) = 4, 'binary text preserved');

  { round trip }
  Buf := 'alpha' + #$17 + 'beta' + #$18 + 'gamma' + #$01 + 'delta';
  Eq(Dephokenize(Phokenize(Buf)), Buf, 'round trip sample');
  Eq(Normalize(Normalize(#$17#$17 + 'lead')), Normalize(#$17#$17 + 'lead'),
     'normalize idempotent');

  { fetch incl. gaps }
  Buf := 'one' + #$17 + 'two' + #$17#$17 + 'four';
  Eq(Fetch(Buf, C('1.1.1/1.1.1/1.1.1')), 'one', 'fetch 1');
  Eq(Fetch(Buf, C('1.1.1/1.1.1/1.1.4')), 'four', 'fetch 4');
  Eq(Fetch(Buf, C('1.1.1/1.1.1/1.1.3')), '', 'gap fetch is empty');
  Eq(Fetch(Buf, C('9.9.9/9.9.9/9.9.9')), '', 'far gap fetch is empty');
  Eq(Fetch('', C('1.1.1/1.1.1/1.1.1')), '', 'fetch empty buffer');

  { insert: existing prepended }
  Out := Insert('base', C('1.1.1/1.1.1/1.1.1'), '+more');
  Eq(Fetch(Out, C('1.1.1/1.1.1/1.1.1')), 'base+more', 'insert appends after existing');
  Out := Insert('', C('1.1.1/1.1.1/1.1.3'), 'new');
  Eq(Out, #$17#$17 + 'new', 'insert at gap emits breaks');
  Out := Insert('a' + #$17 + 'c', C('1.1.1/1.1.1/1.1.2'), 'b');
  Eq(Fetch(Out, C('1.1.1/1.1.1/1.1.2')), 'cb', 'insert merges at existing');

  { replace / remove -- REMOVE IS COORDINATE-PRESERVING }
  Out := Replace('old' + #$17 + 'keep', C('1.1.1/1.1.1/1.1.1'), 'new');
  Eq(Out, 'new' + #$17 + 'keep', 'replace overwrites');
  Out := Remove('a' + #$17 + 'b' + #$17 + 'c', C('1.1.1/1.1.1/1.1.2'));
  Eq(Out, 'a' + #$17#$17 + 'c', 'remove leaves a gap (no renumbering)');
  Eq(Fetch(Out, C('1.1.1/1.1.1/1.1.2')), '', 'removed coordinate reads empty');
  Eq(Fetch(Out, C('1.1.1/1.1.1/1.1.3')), 'c', 'neighbour keeps its coordinate');
  Eq(Fetch(Out, C('1.1.1/1.1.1/1.1.1')), 'a', 'earlier neighbour unchanged');
  Ok(Length(Remove('only', C('1.1.1/1.1.1/1.1.1'))) = 0, 'remove sole scroll');
  Eq(Remove('a', C('5.5.5/5.5.5/5.5.5')), 'a', 'remove gap is a no-op');

  { DynamicPhext equivalence }
  Dyn := TDynStore.Create('a' + #$17 + 'b' + #$17 + 'c');
  try
    Eq(Dyn.Fetch(C('1.1.1/1.1.1/1.1.2')), 'b', 'dyn fetch');
    Dyn.Insert(C('1.1.1/1.1.1/1.1.2'), '!');
    Eq(Dyn.Fetch(C('1.1.1/1.1.1/1.1.2')), 'b!', 'dyn insert merges');
    Dyn.Replace(C('1.1.1/1.1.1/1.1.5'), 'deep');
    Dyn.Remove(C('1.1.1/1.1.1/1.1.1'));
    Eq(Dyn.Fetch(C('1.1.1/1.1.1/1.1.1')), '', 'dyn remove is a gap');
    Eq(Dyn.Fetch(C('1.1.1/1.1.1/1.1.3')), 'c', 'dyn neighbour unshifted');
    Buf := 'b!' + #$17 + 'c';
    Buf := Insert(Buf, C('1.1.1/1.1.1/1.1.5'), 'deep');
    { string path: a removed from the same sequence }
    Buf := Remove(Insert(Insert('a' + #$17 + 'b' + #$17 + 'c',
      C('1.1.1/1.1.1/1.1.2'), '!'), C('1.1.1/1.1.1/1.1.5'), 'deep'),
      C('1.1.1/1.1.1/1.1.1'));
    Eq(Dyn.Serialize, Buf, 'dyn serialize = string path');
    Ok(Dyn.Capacity >= Dyn.Count, 'dyn capacity >= count');
  finally
    Dyn.Free;
  end;

  { TransitivePhext equivalence }
  Trn := TTransStore.Create('a' + #$17 + 'b' + #$17 + 'c');
  try
    Eq(Trn.Fetch(C('1.1.1/1.1.1/1.1.3')), 'c', 'trans fetch');
    Trn.Insert(C('1.1.1/1.1.1/1.1.2'), '!');
    Trn.Replace(C('2.1.1/1.1.1/1.1.1'), 'lib2');
    Trn.Remove(C('1.1.1/1.1.1/1.1.1'));
    Eq(Trn.Fetch(C('1.1.1/1.1.1/1.1.1')), '', 'trans remove is a gap');
    Eq(Trn.Fetch(C('1.1.1/1.1.1/1.1.3')), 'c', 'trans neighbour unshifted');
    Eq(Trn.Serialize, #$17 + 'b!' + #$17 + 'c' + #$01 + 'lib2',
      'trans serialize = string path');
  finally
    Trn.Free;
  end;

  { fixtures }
  if ParamCount >= 1 then
  begin
    Files := TStringList.Create;
    try
      FindFixtures(ParamStr(1), Files);
      Files.Sort;
      Identical := 0; Idem := 0;
      for I := 0 to Files.Count - 1 do
      begin
        Data := ReadFileBytes(Files[I]);
        if Normalize(Data) = Data then Inc(Identical)
        else WriteLn(StdErr, 'fixture round-trip differs: ', Files[I]);
        if Normalize(Normalize(Data)) = Normalize(Data) then Inc(Idem);
      end;
      WriteLn('fixtures: ', Identical, '/', Files.Count,
              ' byte-identical, ', Idem, '/', Files.Count,
              ' normalize-idempotent');
      Ok(Identical = Files.Count, 'fixtures 16/16 byte-identical');
      Ok(Files.Count = 16, 'fixture count is 16');
    finally
      Files.Free;
    end;
  end;

  WriteLn('delphi suite: ', Checks, ' checks, ', Failures, ' failures');
  if Failures > 0 then Halt(1);
end.
