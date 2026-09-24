unit TeacherHash;
{$mode objfpc}{$H+}
// SHA-256 arithmetic is modulo 2^32. Other teacher units retain overflow checks.
{$Q-}{$R-}
interface
uses Classes, SysUtils;
function HashFile(const Path: string): string;
function HashText(const Text: RawByteString): string;
implementation
type THash = record
  H: array[0..7] of cardinal;
  B: array[0..63] of byte;
  Used: integer;
  Count: QWord;
end;
const K: array[0..63] of cardinal = (
 $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
 $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
 $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
 $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
 $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
 $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
 $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
 $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2);
function R(V: cardinal; N: byte): cardinal; inline;
begin Result := (V shr N) or (V shl (32-N)) end;
procedure Init(out C: THash);
begin
  FillChar(C,SizeOf(C),0);
  C.H[0]:=$6a09e667; C.H[1]:=$bb67ae85; C.H[2]:=$3c6ef372; C.H[3]:=$a54ff53a;
  C.H[4]:=$510e527f; C.H[5]:=$9b05688c; C.H[6]:=$1f83d9ab; C.H[7]:=$5be0cd19;
end;
procedure Block(var C: THash);
var W: array[0..63] of cardinal; A,B,D,E,F,G,H,J,T1,T2: cardinal; I: integer;
begin
  for I:=0 to 15 do W[I]:=(cardinal(C.B[I*4]) shl 24) or
    (cardinal(C.B[I*4+1]) shl 16) or (cardinal(C.B[I*4+2]) shl 8) or C.B[I*4+3];
  for I:=16 to 63 do W[I]:=W[I-16]+(R(W[I-15],7) xor R(W[I-15],18) xor (W[I-15] shr 3))+
    W[I-7]+(R(W[I-2],17) xor R(W[I-2],19) xor (W[I-2] shr 10));
  A:=C.H[0]; B:=C.H[1]; D:=C.H[2]; E:=C.H[3]; F:=C.H[4]; G:=C.H[5]; H:=C.H[6]; J:=C.H[7];
  for I:=0 to 63 do begin
    T1:=J+(R(F,6) xor R(F,11) xor R(F,25))+((F and G) xor ((not F) and H))+K[I]+W[I];
    T2:=(R(A,2) xor R(A,13) xor R(A,22))+((A and B) xor (A and D) xor (B and D));
    J:=H; H:=G; G:=F; F:=E+T1; E:=D; D:=B; B:=A; A:=T1+T2;
  end;
  Inc(C.H[0],A); Inc(C.H[1],B); Inc(C.H[2],D); Inc(C.H[3],E);
  Inc(C.H[4],F); Inc(C.H[5],G); Inc(C.H[6],H); Inc(C.H[7],J);
end;
procedure Update(var C: THash; const Data; Len: integer);
var P: PByte; N: integer;
begin
  P:=@Data; Inc(C.Count,Len);
  while Len>0 do begin
    N:=64-C.Used; if N>Len then N:=Len;
    Move(P^,C.B[C.Used],N); Inc(C.Used,N); Inc(P,N); Dec(Len,N);
    if C.Used=64 then begin Block(C); C.Used:=0 end;
  end;
end;
function Finish(var C: THash): string;
var I: integer; LengthBits: QWord; B: byte;
begin
  LengthBits:=C.Count*8; B:=$80; Update(C,B,1); B:=0;
  while C.Used<>56 do Update(C,B,1);
  for I:=7 downto 0 do begin B:=byte(LengthBits shr (I*8)); Update(C,B,1) end;
  Result:=''; for I:=0 to 7 do Result:=Result+LowerCase(IntToHex(C.H[I],8));
end;
function HashFile(const Path: string): string;
var F: TFileStream; C: THash; Buffer: array[0..65535] of byte; N: integer;
begin
  Init(C); F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
  try repeat N:=F.Read(Buffer,SizeOf(Buffer)); if N>0 then Update(C,Buffer,N) until N=0;
  finally F.Free end;
  Result:=Finish(C);
end;
function HashText(const Text: RawByteString): string;
var C: THash;
begin Init(C); if Length(Text)>0 then Update(C,Text[1],Length(Text)); Result:=Finish(C) end;
end.
