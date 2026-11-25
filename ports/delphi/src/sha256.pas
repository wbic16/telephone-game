unit sha256;

{ Native SHA-256 (FIPS 180-4) for libphext-delphi. Debian's FPC
  3.2.2 units do not ship the fcl-hash sha256 unit, so this port
  carries its own, exposing the same interface the FPC unit would:
  SHA256String -> TSHA256Digest, SHA256Print -> hex string. }

{$mode objfpc}{$H+}

interface

type
  TSHA256Digest = array[0..31] of Byte;

function SHA256String(const S: RawByteString): TSHA256Digest;
function SHA256Print(const Digest: TSHA256Digest): string;

implementation

const
  K: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1,
    $923f82a4, $ab1c5ed5, $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174, $e49b69c1, $efbe4786,
    $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147,
    $06ca6351, $14292967, $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85, $a2bfe8a1, $a81a664b,
    $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a,
    $5b9cca4f, $682e6ff3, $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function ROR(x: LongWord; n: Integer): LongWord; inline;
begin
  Result := (x shr n) or (x shl (32 - n));
end;

function SHA256String(const S: RawByteString): TSHA256Digest;
var
  H: array[0..7] of LongWord;
  V: array[0..7] of LongWord;
  W: array[0..63] of LongWord;
  Msg: RawByteString;
  Len, I, J, Blocks, B, T: Integer;
  BitLen: QWord;
  T1, T2, S0, S1, Ch, Maj: LongWord;
begin
  H[0] := $6a09e667; H[1] := $bb67ae85; H[2] := $3c6ef372;
  H[3] := $a54ff53a; H[4] := $510e527f; H[5] := $9b05688c;
  H[6] := $1f83d9ab; H[7] := $5be0cd19;
  Len := Length(S);
  BitLen := QWord(Len) * 8;
  Msg := S;
  SetLength(Msg, ((Len + 9 + 63) div 64) * 64);
  Msg[Len + 1] := #$80;
  for I := Len + 2 to Length(Msg) - 8 do Msg[I] := #0;
  for I := 0 to 7 do
    Msg[Length(Msg) - I] := Chr((BitLen shr (I * 8)) and $FF);
  Blocks := Length(Msg) div 64;
  for B := 0 to Blocks - 1 do
  begin
    for I := 0 to 15 do
    begin
      J := B * 64 + I * 4;
      W[I] := (LongWord(Ord(Msg[J + 1])) shl 24) or
              (LongWord(Ord(Msg[J + 2])) shl 16) or
              (LongWord(Ord(Msg[J + 3])) shl 8) or
              LongWord(Ord(Msg[J + 4]));
    end;
    for I := 16 to 63 do
      W[I] := W[I - 16] +
        (ROR(W[I - 15], 7) xor ROR(W[I - 15], 18) xor (W[I - 15] shr 3)) +
        W[I - 7] +
        (ROR(W[I - 2], 17) xor ROR(W[I - 2], 19) xor (W[I - 2] shr 10));
    for T := 0 to 7 do V[T] := H[T];
    for T := 0 to 63 do
    begin
      S1 := ROR(V[4], 6) xor ROR(V[4], 11) xor ROR(V[4], 25);
      Ch := (V[4] and V[5]) xor ((not V[4]) and V[6]);
      T1 := V[7] + S1 + Ch + K[T] + W[T];
      S0 := ROR(V[0], 2) xor ROR(V[0], 13) xor ROR(V[0], 22);
      Maj := (V[0] and V[1]) xor (V[0] and V[2]) xor (V[1] and V[2]);
      T2 := S0 + Maj;
      V[7] := V[6]; V[6] := V[5]; V[5] := V[4];
      V[4] := V[3] + T1;
      V[3] := V[2]; V[2] := V[1]; V[1] := V[0];
      V[0] := T1 + T2;
    end;
    for T := 0 to 7 do H[T] := H[T] + V[T];
  end;
  for I := 0 to 7 do
  begin
    Result[I * 4] := (H[I] shr 24) and $FF;
    Result[I * 4 + 1] := (H[I] shr 16) and $FF;
    Result[I * 4 + 2] := (H[I] shr 8) and $FF;
    Result[I * 4 + 3] := H[I] and $FF;
  end;
end;

function SHA256Print(const Digest: TSHA256Digest): string;
const
  Hex = '0123456789ABCDEF';
var
  I: Integer;
begin
  Result := '';
  for I := 0 to 31 do
    Result := Result + Hex[Digest[I] shr 4 + 1] + Hex[Digest[I] and $F + 1];
end;

end.
