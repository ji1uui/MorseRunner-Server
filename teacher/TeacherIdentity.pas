unit TeacherIdentity;
{$mode objfpc}{$H+}
interface
uses SysUtils;
function SessionCode(const UUID: string): string;
function SessionUUID(const Code: string): string;
function NewSession: string;
function AudioName(const UUID, Role: string; Part: integer): string;
procedure CheckOutputPath(const Path: string);
implementation
const Alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
function SessionUUID(const Code: string): string;
var I,V,Bits,Acc: integer; Hex: string;
begin
  if Length(Code)<>26 then raise Exception.Create('Invalid Base32 length');
  Hex:=''; Bits:=0; Acc:=0;
  for I:=1 to 26 do begin
    V:=Pos(Code[I],Alphabet)-1;
    if V<0 then raise Exception.Create('Invalid Base32 character');
    Acc:=(Acc shl 5) or V; Inc(Bits,5);
    while Bits>=8 do begin
      Dec(Bits,8); Hex:=Hex+LowerCase(IntToHex(Acc shr Bits,2));
      Acc:=Acc and ((1 shl Bits)-1);
    end;
  end;
  if Acc<>0 then raise Exception.Create('Nonzero Base32 padding bits');
  Result:=Copy(Hex,1,8)+'-'+Copy(Hex,9,4)+'-'+Copy(Hex,13,4)+'-'+Copy(Hex,17,4)+'-'+Copy(Hex,21,12);
end;
function SessionCode(const UUID: string): string;
var S: string; I, V, Bits, Acc: integer;
begin
  if (Length(UUID) <> 36) or (UUID[9] <> '-') or (UUID[14] <> '-') or
     (UUID[19] <> '-') or (UUID[24] <> '-') then
    raise Exception.Create('Invalid canonical UUID');
  S := StringReplace(UUID, '-', '', [rfReplaceAll]);
  if Length(S) <> 32 then raise Exception.Create('Invalid UUID length');
  Result := ''; Bits := 0; Acc := 0;
  for I := 1 to Length(S) do begin
    if not (S[I] in ['0'..'9', 'a'..'f']) then raise Exception.Create('Invalid UUID hex');
    V := Pos(S[I], '0123456789abcdef')-1;
    Acc := (Acc shl 4) or V; Inc(Bits, 4);
    if Bits >= 5 then begin
      Dec(Bits, 5); Result := Result + Alphabet[(Acc shr Bits)+1];
      Acc := Acc and ((1 shl Bits)-1);
    end;
  end;
  if Bits > 0 then Result := Result + Alphabet[(Acc shl (5-Bits))+1];
end;
function NewSession: string;
var G: TGUID;
begin
  if CreateGUID(G) <> 0 then raise Exception.Create('OS UUID generation failed');
  Result := LowerCase(Copy(GUIDToString(G), 2, 36));
  // Do not relabel a time-based GUID as a random UUID.
  if (Result[15] <> '4') or not (Result[20] in ['8','9','a','b']) then
    raise Exception.Create('This OS UUID provider did not return UUID v4');
end;
function AudioName(const UUID, Role: string; Part: integer): string;
var I, N: integer;
begin
  if (Role <> 'r') and (Role <> 'n') then begin
    if (Length(Role) < 3) or (Role[1] <> 's') then raise Exception.Create('Invalid audio role');
    for I := 2 to Length(Role) do
      if not (Role[I] in ['0'..'9']) then raise Exception.Create('Invalid station number');
    if not TryStrToInt(Copy(Role,2,MaxInt),N) or (N < 1) then
      raise Exception.Create('Invalid station number');
    if Role <> 's'+Format('%.2d',[N]) then raise Exception.Create('Noncanonical station number');
  end;
  if (Part < 1) or (Part > 999999) then raise Exception.Create('Part number out of range');
  Result := 'cw_'+SessionCode(UUID)+'_'+Role+'_'+Format('%.6d',[Part])+'.wav';
  if Length(Result) > 64 then raise Exception.Create('Filename too long');
end;
procedure CheckOutputPath(const Path: string);
begin
  // Portable application policy; reserve room for .partial and platform APIs.
  // 240 is a conservative product limit, not a claim about filesystem limits.
  if Length(UTF8Decode(ExpandFileName(Path))) > 240 then
    raise Exception.Create('Output path exceeds portable 240-character budget; choose a shorter directory');
end;
end.
