unit TeacherContract;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, fpjson;
const Rate = 22050;
  Allowed = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/.,?=';
type TTeacherConfig = record
  Text, Profile, Mode: string;
  MilliWpm, EndMilliWpm, GapScaleMilli, JitterMilli, Seed: integer;
  Pitch, Amplitude, ChunkSeconds: integer;
end;
function ReadObject(const Path: string): TJSONObject;
function ParseRecordJSON(const Line: string): TJSONData;
procedure ReadBoundedLine(var F: TextFile; out Line: string);
procedure SaveObject(const Path: string; J: TJSONObject);
function Need(J: TJSONObject; const Key: string; Kind: TJSONType): TJSONData;
function S(J: TJSONObject; const Key: string): string;
function SU(J: TJSONObject; const Key: string): string;
function N(J: TJSONObject; const Key: string): Int64;
procedure Require(OK: boolean; const Msg: string);
function LoadConfig(J: TJSONObject; AllowLegacy: boolean = False): TTeacherConfig;
function SchemaFor(const C: TTeacherConfig): string;
function ConfigJSON(const C: TTeacherConfig): TJSONObject;
procedure AddWpm(J: TJSONObject; const Key: string; MilliWpm: integer);
function Pattern(Ch: char): string;
function TableText: string;
implementation
uses jsonparser, jsonscanner, Math, MorseTbl, TeacherSymbols;
function SchemaFor(const C: TTeacherConfig): string;
begin if C.Profile='standard_v2' then Result:='0.3' else Result:='0.2' end;
procedure ReadBoundedLine(var F: TextFile; out Line: string);
var Ch: char; Used: integer;
begin
  SetLength(Line,1024*1024); Used:=0;
  while not EOF(F) do begin
    Read(F,Ch);
    if Ch=#10 then Break;
    Require(Used<Length(Line),'JSONL record exceeds 1 MiB');
    Inc(Used); Line[Used]:=Ch;
  end;
  SetLength(Line,Used);
end;
type
  TJSONMilliWpm = class(TJSONFloatNumber)
  private
    FMilliWpm: integer;
  protected
    function GetAsJSON: TJSONStringType; override;
  public
    constructor Create(MilliWpm: integer);
    function Clone: TJSONData; override;
  end;
constructor TJSONMilliWpm.Create(MilliWpm: integer);
begin inherited Create(Double(MilliWpm)/1000); FMilliWpm:=MilliWpm end;
function TJSONMilliWpm.GetAsJSON: TJSONStringType;
begin
  // Preserve the decimal contract rather than serializing binary rounding noise.
  Result:=IntToStr(FMilliWpm div 1000)+'.'+Format('%.3d',[FMilliWpm mod 1000]);
end;
function TJSONMilliWpm.Clone: TJSONData;
begin Result:=TJSONMilliWpm.Create(FMilliWpm) end;
procedure AddWpm(J: TJSONObject; const Key: string; MilliWpm: integer);
begin J.Add(Key,TJSONMilliWpm.Create(MilliWpm)) end;
procedure Require(OK: boolean; const Msg: string);
begin if not OK then raise Exception.Create(Msg) end;
function Need(J: TJSONObject; const Key: string; Kind: TJSONType): TJSONData;
begin Result:=J.Find(Key); Require((Result<>nil),'Missing field: '+Key);
  Require(Result.JSONType=Kind,'Wrong type: '+Key) end;
function S(J: TJSONObject; const Key: string): string;
var U: UTF8String; Ch: AnsiChar;
begin
  U:=Need(J,Key,jtString).AsString;
  // Validate before UTF8String -> system-codepage conversion. Otherwise an
  // unsupported character can become '?' (a valid Morse character) on Windows.
  for Ch in U do Require(Ord(Ch)<128,'Non-ASCII field is not supported by P1: '+Key);
  Result:=U;
end;
function SU(J: TJSONObject; const Key: string): string;
begin Result:=Need(J,Key,jtString).AsString end;
function N(J: TJSONObject; const Key: string): Int64;
begin Require(TryStrToInt64(Need(J,Key,jtNumber).AsJSON,Result),'Expected Int64: '+Key) end;
function ReadObject(const Path: string): TJSONObject;
var F: TFileStream; D: TJSONData; P: TJSONParser;
begin
  F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
  D:=nil; P:=nil;
  try Require(F.Size<=16*1024*1024,'JSON file exceeds 16 MiB');
    P:=TJSONParser.Create(F,[joUTF8,joStrict]); D:=P.Parse;
    Require(D.JSONType=jtObject,'Expected JSON object'); Result:=TJSONObject(D); D:=nil;
  finally P.Free; D.Free; F.Free end;
end;
function ParseRecordJSON(const Line: string): TJSONData;
var P: TJSONParser;
begin
  Require(Length(Line)<=1024*1024,'JSONL record exceeds 1 MiB');
  P:=TJSONParser.Create(Line,[joUTF8,joStrict]);
  try Result:=P.Parse finally P.Free end;
end;
procedure SaveObject(const Path: string; J: TJSONObject);
var F: TFileStream; T: RawByteString;
begin
  T:=J.FormatJSON+#10; F:=TFileStream.Create(Path,fmCreate);
  try if T<>'' then F.WriteBuffer(T[1],Length(T)) finally F.Free end;
end;
function Pattern(Ch: char): string;
var I,P: integer;
begin
  Require(Pos(Ch,Allowed)>0,'Unsupported character'); Result:='';
  for I:=Low(MorseTable) to High(MorseTable) do
    if (MorseTable[I][1]=Ch) and (MorseTable[I][2]='[') then begin
      P:=Pos(']',MorseTable[I]); Exit(Copy(MorseTable[I],3,P-3));
    end;
  raise Exception.Create('Missing Morse table entry');
end;
function TableText: string;
var I: integer;
begin Result:=''; for I:=1 to Length(Allowed) do Result:=Result+Allowed[I]+'='+Pattern(Allowed[I])+#10 end;
function LoadConfig(J: TJSONObject; AllowLegacy: boolean): TTeacherConfig;
var I: integer; W: double; V: Int64;
const Keys='|schema_version|mode|timing_profile|text|wpm|wpm_end|gap_scale_milli|jitter_milli|seed|pitch_hz|amplitude|chunk_seconds|';
begin
  for I:=0 to J.Count-1 do Require(Pos('|'+J.Names[I]+'|',Keys)>0,'Unknown config field: '+J.Names[I]);
  Result.Mode:=S(J,'mode');
  Result.Profile:=S(J,'timing_profile');
  Require((Result.Profile='standard_v1') or (Result.Profile='standard_v2') or
    (AllowLegacy and (Result.Profile='upstream_keyer_legacy')),'Unsupported timing profile');
  if Result.Profile='standard_v2' then
    Require((Result.Mode='international') or (Result.Mode='wabun') or (Result.Mode='mixed'),'Unsupported mode')
  else Require(Result.Mode='international','Legacy/P1 requires international mode');
  Require(S(J,'schema_version')=SchemaFor(Result),'Unsupported config schema/profile combination');
  if Result.Profile='standard_v2' then Result.Text:=SU(J,'text') else Result.Text:=S(J,'text');
  Require((Length(Result.Text)>0) and (Length(Result.Text)<=65536),'Text length must be 1..65536 bytes');
  if Result.Profile='standard_v2' then Tokenize(Result.Text,Result.Mode)
  else for I:=1 to Length(Result.Text) do begin
    if Result.Text[I]=' ' then begin
      Require((I>1) and (I<Length(Result.Text)),'Leading/trailing space');
      if (I>1) and (Result.Profile='standard_v1') then Require(Result.Text[I-1]<>' ','Repeated space: use explicit pauses in a future profile');
    end else Require(Pos(Result.Text[I],Allowed)>0,'Unsupported character at byte '+IntToStr(I));
  end;
  W:=Need(J,'wpm',jtNumber).AsFloat;
  Require((not IsNan(W)) and (not IsInfinite(W)) and (W>=5) and (W<=60),'WPM must be 5..60');
  Result.MilliWpm:=Round(W*1000);
  Require(W=Double(Result.MilliWpm/1000),'WPM supports at most three decimals');
  Result.EndMilliWpm:=Result.MilliWpm;
  Result.GapScaleMilli:=1000; Result.JitterMilli:=0; Result.Seed:=0;
  if Result.Profile='standard_v2' then begin
    W:=Need(J,'wpm_end',jtNumber).AsFloat;
    Require((not IsNan(W)) and (not IsInfinite(W)) and (W>=5) and (W<=60),'End WPM must be 5..60');
    Result.EndMilliWpm:=Round(W*1000);
    Require(W=Double(Result.EndMilliWpm/1000),'End WPM supports at most three decimals');
    V:=N(J,'gap_scale_milli'); Require((V>=1000) and (V<=3000),'Gap scale must be 1000..3000'); Result.GapScaleMilli:=V;
    V:=N(J,'jitter_milli'); Require((V>=0) and (V<=100),'Jitter must be 0..100'); Result.JitterMilli:=V;
    V:=N(J,'seed'); Require((V>=1) and (V<=2147483647),'Seed must be 1..2147483647'); Result.Seed:=V;
  end else begin
    Require((J.Find('wpm_end')=nil) and (J.Find('gap_scale_milli')=nil) and
      (J.Find('jitter_milli')=nil) and (J.Find('seed')=nil),'P2 speed fields require standard_v2');
  end;
  V:=N(J,'pitch_hz'); Require((V>=200) and (V<=1200),'Pitch must be 200..1200'); Result.Pitch:=V;
  V:=N(J,'amplitude'); Require((V>=1) and (V<=30000),'Amplitude must be 1..30000'); Result.Amplitude:=V;
  V:=N(J,'chunk_seconds'); Require((V>=1) and (V<=3600),'Chunk seconds must be 1..3600'); Result.ChunkSeconds:=V;
end;
function ConfigJSON(const C: TTeacherConfig): TJSONObject;
begin
  Result:=TJSONObject.Create(['schema_version',SchemaFor(C),'mode',C.Mode,'timing_profile',C.Profile,
    'text',C.Text,'pitch_hz',C.Pitch,'amplitude',C.Amplitude,'chunk_seconds',C.ChunkSeconds]);
  AddWpm(Result,'wpm',C.MilliWpm);
  if C.Profile='standard_v2' then begin
    AddWpm(Result,'wpm_end',C.EndMilliWpm);
    Result.Add('gap_scale_milli',C.GapScaleMilli);
    Result.Add('jitter_milli',C.JitterMilli); Result.Add('seed',C.Seed);
  end;
end;
end.
