program TeacherPrimitives;
{$mode objfpc}{$H+}
uses SysUtils, TeacherIdentity, TeacherHash;
procedure Check(B: boolean; const Msg: string);
begin if not B then raise Exception.Create(Msg) end;
var Id: string; Failed: boolean;
begin
  Check(HashText('')='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855','SHA256 empty');
  Check(HashText('abc')='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad','SHA256 abc');
  Check(HashText(StringOfChar('a',1000000))='cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0','SHA256 million a');
  Id:='550e8400-e29b-41d4-a716-446655440000';
  Check(SessionCode(Id)='kuhiiahctna5jjywirtfkraaaa','UUID vector');
  Check(SessionUUID(SessionCode(Id))=Id,'UUID round trip');
  Check(SessionUUID('77777777777777777777777774')='ffffffff-ffff-ffff-ffff-ffffffffffff','Base32 inverse');
  Failed:=False; try SessionUUID('kuhiiahctna5jjywirtfkraaab') except Failed:=True end; Check(Failed,'Padding bits');
  Failed:=False; try SessionUUID('kuhiiahctna5jjywirtfkraaaA') except Failed:=True end; Check(Failed,'Base32 case');
  Check(SessionCode('ffffffff-ffff-ffff-ffff-ffffffffffff')='77777777777777777777777774','Base32 high bits');
  Check(Length(AudioName(Id,'r',1))=42,'Audio filename length');
  Check(Length(AudioName(Id,'s01',999999))=44,'Station filename length');
  Failed:=False; try AudioName(Id,'r',1000000) except Failed:=True end; Check(Failed,'Part overflow');
  Failed:=False; try AudioName(Id,'s001',1) except Failed:=True end; Check(Failed,'Noncanonical role');
  Failed:=False; try SessionCode('550E8400-e29b-41d4-a716-446655440000') except Failed:=True end; Check(Failed,'Noncanonical UUID');
  Id:=NewSession; Check(Id[15]='4','UUID v4');
  WriteLn('PASS primitive known vectors');
end.
