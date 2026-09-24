unit TeacherLineReader;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils;
type
  TBoundedLineReader = class
  private
    F: TFileStream;
    B: array[0..65535] of byte;
    Used, At: integer;
    function NextByte: integer;
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    function NextLine: string;
    function AtEnd: boolean;
  end;
implementation
constructor TBoundedLineReader.Create(const Path: string);
begin inherited Create; F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite) end;
destructor TBoundedLineReader.Destroy;
begin F.Free; inherited Destroy end;
function TBoundedLineReader.NextByte: integer;
begin
  if At=Used then begin Used:=F.Read(B,SizeOf(B)); At:=0 end;
  if At=Used then Exit(-1);
  Result:=B[At]; Inc(At);
end;
function TBoundedLineReader.AtEnd: boolean;
begin
  if At<Used then Exit(False);
  Used:=F.Read(B,SizeOf(B)); At:=0; Result:=Used=0;
end;
function TBoundedLineReader.NextLine: string;
var Ch,Len,Capacity: integer;
begin
  Capacity:=256; SetLength(Result,Capacity); Len:=0;
  repeat
    Ch:=NextByte;
    if Ch=-1 then raise Exception.Create('Unexpected end of JSONL file');
    if Ch=10 then Break;
    if Ch=13 then raise Exception.Create('JSONL requires LF line endings');
    if Len>=1024*1024 then raise Exception.Create('JSONL record exceeds 1 MiB');
    if Len=Capacity then begin Capacity:=Capacity*2; SetLength(Result,Capacity) end;
    Inc(Len); Result[Len]:=Chr(Ch);
  until False;
  SetLength(Result,Len);
end;
end.
