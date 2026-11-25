unit phext;
{ libphext-delphi -- Object Pascal (Free Pascal) port of libphext, 0.6.1
  parity. Semantics normative from libphext-py: a phext is a byte buffer;
  nine dimension-break bytes walk a 9-component coordinate; scroll text
  is a maximal run of non-break bytes (newline $0A is ordinary text).
  All buffers are RawByteString; byte identity is preserved throughout.
  REMOVE is coordinate-preserving: the removed coordinate reads "",
  neighbours do not shift (remove = replace with "" then normalize). }
{$mode objfpc}{$H+}
interface

uses SysUtils;

type
  TCoord = array[0..8] of Int64;
  TScroll = record
    Coord: TCoord;
    Text: RawByteString;
  end;
  TScrollArray = array of TScroll;

const
  DimBreaks: array[0..8] of Byte =
    ($01, $1F, $1E, $1D, $1C, $1A, $19, $18, $17);

function CoordStr(const C: TCoord): RawByteString;
function ParseCoord(const S: RawByteString): TCoord;
function CoordEq(const A, B: TCoord): Boolean;
function CoordCmp(const A, B: TCoord): Integer; { -1, 0, 1 lexicographic }
function RootCoord: TCoord;
function BreakDim(B: Byte): Integer; { -1 if not a break }
function Phokenize(const Buf: RawByteString): TScrollArray;
function Dephokenize(Stack: TScrollArray): RawByteString;
function Normalize(const Buf: RawByteString): RawByteString;
function Fetch(const Buf: RawByteString; const C: TCoord): RawByteString;
function Update(const Buf: RawByteString; const C: TCoord;
  const Text: RawByteString; Overwrite: Boolean): RawByteString;
function Insert(const Buf: RawByteString; const C: TCoord;
  const Text: RawByteString): RawByteString;
function Replace(const Buf: RawByteString; const C: TCoord;
  const Text: RawByteString): RawByteString;
function Remove(const Buf: RawByteString; const C: TCoord): RawByteString;
{ DynamicPhext: capacity-managed dynamic array store (double on full,
  shrink at quarter-full). TransitivePhext: 9-level branching hash map
  (nested string->node maps via sorted dynamic arrays per level is NOT
  used here; the transitive store is a recursive record tree). }
type
  TDynStore = class
  private
    FItems: TScrollArray;
    FN, FCap: Integer;
    procedure GrowIfFull;
    procedure ShrinkIfSparse;
    function FindIdx(const C: TCoord; out Found: Boolean): Integer;
  public
    ResizeCount, ElementsCopied: Integer;
    constructor Create(const Buf: RawByteString);
    function Count: Integer;
    function Capacity: Integer;
    function Fetch(const C: TCoord): RawByteString;
    procedure Insert(const C: TCoord; const Text: RawByteString);
    procedure Replace(const C: TCoord; const Text: RawByteString);
    procedure Remove(const C: TCoord);
    function Serialize: RawByteString;
  end;

  TNode = class
    IsLeaf: Boolean;
    LeafText: RawByteString;
    Keys: array of Int64;
    Kids: array of TNode;
    function FindKid(K: Int64; CreateIt: Boolean): TNode;
  end;

  TTransStore = class
  private
    FRoot: TNode;
    FN: Integer;
    function Walk(const C: TCoord; CreateIt: Boolean): TNode;
    procedure Collect(Node: TNode; Depth: Integer; var Prefix: TCoord;
      var OutArr: TScrollArray);
  public
    constructor Create(const Buf: RawByteString);
    destructor Destroy; override;
    function Count: Integer;
    function Fetch(const C: TCoord): RawByteString;
    procedure Insert(const C: TCoord; const Text: RawByteString);
    procedure Replace(const C: TCoord; const Text: RawByteString);
    procedure Remove(const C: TCoord);
    function Serialize: RawByteString;
  end;

implementation

function RootCoord: TCoord;
var i: Integer;
begin
  for i := 0 to 8 do Result[i] := 1;
end;

function CoordEq(const A, B: TCoord): Boolean;
var i: Integer;
begin
  Result := True;
  for i := 0 to 8 do if A[i] <> B[i] then Exit(False);
end;

function CoordCmp(const A, B: TCoord): Integer;
var i: Integer;
begin
  for i := 0 to 8 do
  begin
    if A[i] < B[i] then Exit(-1);
    if A[i] > B[i] then Exit(1);
  end;
  Result := 0;
end;

function CoordStr(const C: TCoord): RawByteString;
begin
  Result := IntToStr(C[0]) + '.' + IntToStr(C[1]) + '.' + IntToStr(C[2]) + '/' +
            IntToStr(C[3]) + '.' + IntToStr(C[4]) + '.' + IntToStr(C[5]) + '/' +
            IntToStr(C[6]) + '.' + IntToStr(C[7]) + '.' + IntToStr(C[8]);
end;

function ParseCoord(const S: RawByteString): TCoord;
var
  Parts: array[0..8] of Int64;
  N, I, Start: Integer;
  Num: Int64;
  Neg: Boolean;
begin
  N := 0; I := 1;
  while I <= Length(S) do
  begin
    Start := I; Num := 0; Neg := False;
    if (I <= Length(S)) and (S[I] = '-') then begin Neg := True; Inc(I); end;
    while (I <= Length(S)) and (S[I] >= '0') and (S[I] <= '9') do
    begin
      Num := Num * 10 + (Ord(S[I]) - Ord('0')); Inc(I);
    end;
    if I = Start then raise Exception.Create('invalid coordinate: ' + S);
    if Neg then Num := -Num;
    if N > 8 then raise Exception.Create('invalid coordinate: ' + S);
    Parts[N] := Num; Inc(N);
    if (I <= Length(S)) and ((S[I] = '.') or (S[I] = '/')) then Inc(I)
    else if I <= Length(S) then raise Exception.Create('invalid coordinate: ' + S);
  end;
  if N <> 9 then raise Exception.Create('invalid coordinate: ' + S);
  for I := 0 to 8 do
  begin
    if Parts[I] < 1 then raise Exception.Create('coordinate components >= 1: ' + S);
    Result[I] := Parts[I];
  end;
end;

function BreakDim(B: Byte): Integer;
var i: Integer;
begin
  for i := 0 to 8 do if DimBreaks[i] = B then Exit(i);
  Result := -1;
end;

procedure ApplyBreak(var C: TCoord; D: Integer);
var k: Integer;
begin
  C[D] := C[D] + 1;
  for k := D + 1 to 8 do C[k] := 1;
end;

function Phokenize(const Buf: RawByteString): TScrollArray;
var
  Coord: TCoord;
  I, D, RunStart: Integer;
  N: Integer;
begin
  Coord := RootCoord;
  SetLength(Result, 0);
  N := 0; RunStart := 1; I := 1;
  while I <= Length(Buf) do
  begin
    D := BreakDim(Ord(Buf[I]));
    if D >= 0 then
    begin
      if I > RunStart then
      begin
        SetLength(Result, N + 1);
        Result[N].Coord := Coord;
        Result[N].Text := Copy(Buf, RunStart, I - RunStart);
        Inc(N);
      end;
      ApplyBreak(Coord, D);
      RunStart := I + 1;
    end;
    Inc(I);
  end;
  if Length(Buf) >= RunStart then
  begin
    SetLength(Result, N + 1);
    Result[N].Coord := Coord;
    Result[N].Text := Copy(Buf, RunStart, Length(Buf) - RunStart + 1);
  end;
end;

function Advance(var Loc: TCoord; const Target: TCoord): RawByteString;
var
  Dim, Lower, J: Integer;
begin
  Result := '';
  if CoordCmp(Loc, Target) >= 0 then Exit;
  Dim := 0;
  while Loc[Dim] = Target[Dim] do Inc(Dim);
  for J := 1 to Target[Dim] - Loc[Dim] do Result := Result + Chr(DimBreaks[Dim]);
  Loc[Dim] := Target[Dim];
  for Lower := Dim + 1 to 8 do Loc[Lower] := 1;
  for Lower := Dim + 1 to 8 do
  begin
    for J := 1 to Target[Lower] - 1 do
      Result := Result + Chr(DimBreaks[Lower]);
    Loc[Lower] := Target[Lower];
  end;
end;

procedure SortScrolls(var A: TScrollArray);
var i, j: Integer; Tmp: TScroll;
begin
  for i := 1 to High(A) do
  begin
    Tmp := A[i]; j := i - 1;
    while (j >= 0) and (CoordCmp(A[j].Coord, Tmp.Coord) > 0) do
    begin
      A[j + 1] := A[j]; Dec(j);
    end;
    A[j + 1] := Tmp;
  end;
end;

function Dephokenize(Stack: TScrollArray): RawByteString;
var
  Loc: TCoord;
  I: Integer;
  Sorted: TScrollArray;
begin
  SetLength(Sorted, Length(Stack));
  for I := 0 to High(Stack) do Sorted[I] := Stack[I];
  SortScrolls(Sorted);
  Loc := RootCoord;
  Result := '';
  for I := 0 to High(Sorted) do
  begin
    if Length(Sorted[I].Text) = 0 then Continue;
    Result := Result + Advance(Loc, Sorted[I].Coord) + Sorted[I].Text;
  end;
end;

function Normalize(const Buf: RawByteString): RawByteString;
begin
  Result := Dephokenize(Phokenize(Buf));
end;

function Fetch(const Buf: RawByteString; const C: TCoord): RawByteString;
var
  Items: TScrollArray;
  I: Integer;
begin
  Items := Phokenize(Buf);
  for I := 0 to High(Items) do
    if CoordEq(Items[I].Coord, C) then Exit(Items[I].Text);
  Result := '';
end;

function Update(const Buf: RawByteString; const C: TCoord;
  const Text: RawByteString; Overwrite: Boolean): RawByteString;
var
  Items, Res: TScrollArray;
  I, N: Integer;
  Appended: Boolean;
  NS: TScroll;
begin
  Items := Phokenize(Buf);
  SetLength(Res, 0); N := 0; Appended := False;
  NS.Coord := C; NS.Text := Text;
  for I := 0 to High(Items) do
  begin
    if (CoordCmp(Items[I].Coord, C) > 0) and (not Appended) then
    begin
      SetLength(Res, N + 1); Res[N] := NS; Inc(N); Appended := True;
    end;
    if CoordEq(Items[I].Coord, C) and (not Appended) then
    begin
      if not Overwrite then NS.Text := Items[I].Text + NS.Text;
      SetLength(Res, N + 1); Res[N] := NS; Inc(N); Appended := True;
      Continue;
    end;
    SetLength(Res, N + 1); Res[N] := Items[I]; Inc(N);
  end;
  if not Appended then
  begin
    SetLength(Res, N + 1); Res[N] := NS;
  end;
  { dephokenize inline, preserving order (already sorted) }
  Result := Dephokenize(Res);
end;

function Insert(const Buf: RawByteString; const C: TCoord;
  const Text: RawByteString): RawByteString;
begin
  Result := Update(Buf, C, Text, False);
end;

function Replace(const Buf: RawByteString; const C: TCoord;
  const Text: RawByteString): RawByteString;
begin
  Result := Update(Buf, C, Text, True);
end;

function Remove(const Buf: RawByteString; const C: TCoord): RawByteString;
begin
  Result := Normalize(Update(Buf, C, '', True));
end;

{ ---------------- DynamicPhext ---------------- }

constructor TDynStore.Create(const Buf: RawByteString);
var Items: TScrollArray; I: Integer;
begin
  FCap := 1; SetLength(FItems, FCap); FN := 0;
  ResizeCount := 0; ElementsCopied := 0;
  Items := Phokenize(Buf);
  for I := 0 to High(Items) do
  begin
    GrowIfFull;
    FItems[FN] := Items[I]; Inc(FN);
  end;
end;

function TDynStore.Count: Integer;
begin Result := FN; end;

function TDynStore.Capacity: Integer;
begin Result := FCap; end;

procedure TDynStore.GrowIfFull;
var I: Integer; NewArr: TScrollArray;
begin
  if FN = FCap then
  begin
    SetLength(NewArr, FCap * 2);
    for I := 0 to FN - 1 do NewArr[I] := FItems[I];
    FItems := NewArr; FCap := FCap * 2;
    Inc(ResizeCount); ElementsCopied := ElementsCopied + FN;
  end;
end;

procedure TDynStore.ShrinkIfSparse;
var I: Integer; NewArr: TScrollArray; NewCap: Integer;
begin
  if (FCap > 1) and (FN <= FCap div 4) then
  begin
    NewCap := FCap div 2; if NewCap < 1 then NewCap := 1;
    SetLength(NewArr, NewCap);
    for I := 0 to FN - 1 do NewArr[I] := FItems[I];
    FItems := NewArr; FCap := NewCap;
    Inc(ResizeCount); ElementsCopied := ElementsCopied + FN;
  end;
end;

function TDynStore.FindIdx(const C: TCoord; out Found: Boolean): Integer;
var Lo, Hi, Mid, Cmp: Integer;
begin
  Lo := 0; Hi := FN - 1; Found := False; Result := FN;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    Cmp := CoordCmp(FItems[Mid].Coord, C);
    if Cmp = 0 then begin Found := True; Exit(Mid); end;
    if Cmp < 0 then Lo := Mid + 1 else Hi := Mid - 1;
  end;
  Result := Lo;
end;

function TDynStore.Fetch(const C: TCoord): RawByteString;
var F: Boolean; I: Integer;
begin
  I := FindIdx(C, F);
  if F then Result := FItems[I].Text else Result := '';
end;

procedure TDynStore.Insert(const C: TCoord; const Text: RawByteString);
var F: Boolean; I, J: Integer;
begin
  if Text = '' then Exit;
  I := FindIdx(C, F);
  if F then begin FItems[I].Text := FItems[I].Text + Text; Exit; end;
  GrowIfFull;
  for J := FN downto I + 1 do FItems[J] := FItems[J - 1];
  FItems[I].Coord := C; FItems[I].Text := Text; Inc(FN);
end;

procedure TDynStore.Replace(const C: TCoord; const Text: RawByteString);
var F: Boolean; I, J: Integer;
begin
  if Text = '' then begin Remove(C); Exit; end;
  I := FindIdx(C, F);
  if F then begin FItems[I].Text := Text; Exit; end;
  GrowIfFull;
  for J := FN downto I + 1 do FItems[J] := FItems[J - 1];
  FItems[I].Coord := C; FItems[I].Text := Text; Inc(FN);
end;

procedure TDynStore.Remove(const C: TCoord);
var F: Boolean; I, J: Integer;
begin
  I := FindIdx(C, F);
  if not F then Exit;
  for J := I to FN - 2 do FItems[J] := FItems[J + 1];
  Dec(FN);
  ShrinkIfSparse;
end;

function TDynStore.Serialize: RawByteString;
var Arr: TScrollArray; I: Integer;
begin
  SetLength(Arr, FN);
  for I := 0 to FN - 1 do Arr[I] := FItems[I];
  Result := Dephokenize(Arr);
end;

{ ---------------- TransitivePhext ---------------- }

function TNode.FindKid(K: Int64; CreateIt: Boolean): TNode;
var I: Integer;
begin
  for I := 0 to High(Keys) do
    if Keys[I] = K then Exit(Kids[I]);
  if not CreateIt then Exit(nil);
  SetLength(Keys, Length(Keys) + 1);
  SetLength(Kids, Length(Kids) + 1);
  Kids[High(Kids)] := TNode.Create;
  Keys[High(Keys)] := K;
  Result := Kids[High(Kids)];
end;

constructor TTransStore.Create(const Buf: RawByteString);
var Items: TScrollArray; I: Integer;
begin
  FRoot := TNode.Create; FN := 0;
  Items := Phokenize(Buf);
  for I := 0 to High(Items) do Replace(Items[I].Coord, Items[I].Text);
end;

destructor TTransStore.Destroy;
  procedure FreeNode(N: TNode);
  var I: Integer;
  begin
    if N = nil then Exit;
    for I := 0 to High(N.Kids) do FreeNode(N.Kids[I]);
    N.Free;
  end;
begin
  FreeNode(FRoot);
  inherited Destroy;
end;

function TTransStore.Count: Integer;
begin Result := FN; end;

function TTransStore.Walk(const C: TCoord; CreateIt: Boolean): TNode;
var D: Integer;
begin
  Result := FRoot;
  for D := 0 to 8 do
  begin
    Result := Result.FindKid(C[D], CreateIt);
    if Result = nil then Exit;
  end;
end;

function TTransStore.Fetch(const C: TCoord): RawByteString;
var N: TNode;
begin
  N := Walk(C, False);
  if (N <> nil) and N.IsLeaf then Result := N.LeafText else Result := '';
end;

procedure TTransStore.Insert(const C: TCoord; const Text: RawByteString);
var N: TNode;
begin
  if Text = '' then Exit;
  N := Walk(C, True);
  if N.IsLeaf then N.LeafText := N.LeafText + Text
  else begin N.IsLeaf := True; N.LeafText := Text; Inc(FN); end;
end;

procedure TTransStore.Replace(const C: TCoord; const Text: RawByteString);
var N: TNode;
begin
  if Text = '' then begin Remove(C); Exit; end;
  N := Walk(C, True);
  if not N.IsLeaf then Inc(FN);
  N.IsLeaf := True; N.LeafText := Text;
end;

procedure TTransStore.Remove(const C: TCoord);
var N: TNode;
begin
  N := Walk(C, False);
  if (N <> nil) and N.IsLeaf then
  begin
    N.IsLeaf := False; N.LeafText := ''; Dec(FN);
  end;
end;

procedure TTransStore.Collect(Node: TNode; Depth: Integer;
  var Prefix: TCoord; var OutArr: TScrollArray);
var
  I, J: Integer;
  Order: array of Integer;
  Tmp: Integer;
begin
  if Depth = 9 then
  begin
    if Node.IsLeaf then
    begin
      SetLength(OutArr, Length(OutArr) + 1);
      OutArr[High(OutArr)].Coord := Prefix;
      OutArr[High(OutArr)].Text := Node.LeafText;
    end;
    Exit;
  end;
  SetLength(Order, Length(Node.Keys));
  for I := 0 to High(Order) do Order[I] := I;
  for I := 1 to High(Order) do
  begin
    Tmp := Order[I]; J := I - 1;
    while (J >= 0) and (Node.Keys[Order[J]] > Node.Keys[Tmp]) do
    begin
      Order[J + 1] := Order[J]; Dec(J);
    end;
    Order[J + 1] := Tmp;
  end;
  for I := 0 to High(Order) do
  begin
    Prefix[Depth] := Node.Keys[Order[I]];
    Collect(Node.Kids[Order[I]], Depth + 1, Prefix, OutArr);
  end;
end;

function TTransStore.Serialize: RawByteString;
var
  Arr: TScrollArray;
  Prefix: TCoord;
begin
  SetLength(Arr, 0);
  Prefix := RootCoord;
  Collect(FRoot, 0, Prefix, Arr);
  Result := Dephokenize(Arr);
end;

end.
