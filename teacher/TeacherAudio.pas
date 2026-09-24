unit TeacherAudio;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Math, fpjson, TeacherContract, TeacherIdentity, TeacherHash;
type
  TAudioFiles = class
  private
    C: TTeacherConfig;
    Dir, Session: string;
    VerifyOnly: boolean;
    F: TFileStream;
    FileList: TJSONArray;
    AtSample, Total, PartFrames, UsedFrames: Int64;
    Part: integer;
    {$IFDEF TEACHER_FAULT_TEST} WriteCalls: integer; {$ENDIF}
    FilePath: string;
    procedure StartPart;
    procedure ClosePart;
    procedure Bytes(const Buffer; Count: integer);
  public
    constructor Create(const ADir, SessionId: string; const Config: TTeacherConfig;
      SampleCount: Int64; Files: TJSONArray; Compare: boolean);
    destructor Destroy; override;
    procedure Samples(const Buffer; Count: integer);
    procedure Finish;
  end;
procedure RenderEvent(Audio: TAudioFiles; const C: TTeacherConfig; J: TJSONObject);
procedure AddFile(Files: TJSONArray; const Dir, Name: string);
implementation
procedure AddFile(Files: TJSONArray; const Dir, Name: string);
var F: TFileStream; L: Int64;
begin
  F:=TFileStream.Create(Dir+Name,fmOpenRead or fmShareDenyWrite);
  try L:=F.Size finally F.Free end;
  Files.Add(TJSONObject.Create(['path',Name,'byte_count',L,'sha256',HashFile(Dir+Name)]));
end;
constructor TAudioFiles.Create(const ADir, SessionId: string; const Config: TTeacherConfig;
  SampleCount: Int64; Files: TJSONArray; Compare: boolean);
begin
  inherited Create; Dir:=ADir; Session:=SessionId; C:=Config; Total:=SampleCount;
  FileList:=Files; VerifyOnly:=Compare;
end;
destructor TAudioFiles.Destroy;
begin F.Free; inherited Destroy end;
procedure TAudioFiles.Bytes(const Buffer; Count: integer);
var B: array[0..8191] of byte;
begin
  {$IFDEF TEACHER_FAULT_TEST}
  if not VerifyOnly then begin
    Inc(WriteCalls);
    if WriteCalls=StrToIntDef(GetEnvironmentVariable('TEACHER_TEST_FAIL_WRITE'),-1) then
      raise EWriteError.Create('Injected writer failure');
  end;
  {$ENDIF}
  if VerifyOnly then begin
    Require(Count<=SizeOf(B),'Internal PCM buffer overflow');
    F.ReadBuffer(B,Count);
    Require(CompareMem(@Buffer,@B[0],Count),'PCM/header differs from declared source: '+FilePath);
  end else F.WriteBuffer(Buffer,Count);
end;
procedure TAudioFiles.StartPart;
var H: array[0..43] of byte;
  procedure U16(Offset: integer; V: word);
  begin H[Offset]:=V and 255; H[Offset+1]:=V shr 8 end;
  procedure U32(Offset: integer; V: cardinal);
  var I: integer;
  begin for I:=0 to 3 do H[Offset+I]:=(V shr (I*8)) and 255 end;
begin
  Inc(Part); UsedFrames:=0;
  PartFrames:=Min(Int64(C.ChunkSeconds)*Rate,Total-AtSample);
  FilePath:=AudioName(Session,'r',Part); CheckOutputPath(Dir+FilePath);
  if VerifyOnly then F:=TFileStream.Create(Dir+FilePath,fmOpenRead or fmShareDenyWrite)
  else begin
    Require(not FileExists(Dir+FilePath),'Audio path collision');
    F:=TFileStream.Create(Dir+FilePath,fmCreate);
  end;
  FillChar(H,SizeOf(H),0);
  Move('RIFF'[1],H[0],4); Move('WAVEfmt '[1],H[8],8); Move('data'[1],H[36],4);
  U32(4,36+PartFrames*2); U32(16,16); U16(20,1); U16(22,1); U32(24,Rate);
  U32(28,Rate*2); U16(32,2); U16(34,16); U32(40,PartFrames*2);
  Bytes(H,SizeOf(H));
end;
procedure TAudioFiles.ClosePart;
var J: TJSONObject;
begin
  if F=nil then Exit;
  Require(UsedFrames=PartFrames,'Incomplete PCM part');
  Require(F.Position=F.Size,'Extra WAV bytes'); FreeAndNil(F);
  AddFile(FileList,Dir,FilePath); J:=TJSONObject(FileList[FileList.Count-1]);
  J.Add('role','r'); J.Add('station_id',TJSONNull.Create); J.Add('part',Part);
  J.Add('global_start_sample',AtSample-UsedFrames); J.Add('sample_count',UsedFrames);
end;
procedure TAudioFiles.Samples(const Buffer; Count: integer);
var P: PByte; K: integer;
begin
  Require(AtSample+Count<=Total,'Too much PCM'); P:=@Buffer;
  while Count>0 do begin
    if F=nil then StartPart;
    K:=Min(Int64(Count),PartFrames-UsedFrames); K:=Min(K,4096);
    Bytes(P^,K*2); Inc(P,K*2); Inc(AtSample,K); Inc(UsedFrames,K); Dec(Count,K);
    if UsedFrames=PartFrames then ClosePart;
  end;
end;
procedure TAudioFiles.Finish;
begin Require(AtSample=Total,'Missing PCM frames'); Require(F=nil,'Unclosed PCM part') end;
procedure RenderEvent(Audio: TAudioFiles; const C: TTeacherConfig; J: TJSONObject);
var At,First,Last: Int64; K,I,V,Ramp: integer; IsMark: boolean; A: double;
  B: array[0..8191] of byte;
begin
  Require(C.Profile<>'upstream_keyer_legacy','Legacy rendering must preserve original WAV');
  First:=N(J,'start_sample'); Last:=N(J,'end_sample'); At:=First;
  IsMark:=(S(J,'kind')='dit') or (S(J,'kind')='dah'); Ramp:=Round(0.005*Rate);
  while At<Last do begin
    K:=Min(Int64(4096),Last-At);
    for I:=0 to K-1 do begin
      if IsMark then begin
        if At+I-First<Ramp then A:=0.5-0.5*Cos(Pi*(At+I-First)/Ramp) else A:=1;
      end else begin
        if At+I-First<Ramp then A:=0.5+0.5*Cos(Pi*(At+I-First)/Ramp) else A:=0;
      end;
      V:=Round(C.Amplitude*A*Cos(2*Pi*C.Pitch*(At+I)/Rate));
      B[I*2]:=V and 255; B[I*2+1]:=(V shr 8) and 255;
    end;
    Audio.Samples(B,K); Inc(At,K);
  end;
end;
end.
