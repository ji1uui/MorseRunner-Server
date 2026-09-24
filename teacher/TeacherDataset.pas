unit TeacherDataset;
{$mode objfpc}{$H+}
interface
uses SysUtils, Classes, fpjson, TeacherContract;
procedure GenerateDataset(const OutputDir: string; const C: TTeacherConfig);
procedure ValidateDataset(const Dir: string);
procedure MigrateDataset(const InputDir, OutputDir: string);
implementation
uses Math, DateUtils, jsonparser, TeacherIdentity, TeacherHash, TeacherTiming,
  TeacherAudio, TeacherPlatform, TeacherSymbols, TeacherLineReader, MorseKey, SndTypes;
{$IFDEF TEACHER_BUILD_INFO}
{$I TeacherBuildInfo.inc}
{$ELSE}
const SourceCommit = ''; SourceDirty = True;
{$ENDIF}
type
  TRecords = class
    C: TTeacherConfig;
    Dir, Session: string;
    Compare: boolean;
    Symbols, Tokens: TextFile;
    SymbolsOpen, TokensOpen: boolean;
    SymbolInput, TokenInput: TBoundedLineReader;
    Audio: TAudioFiles;
    procedure Start;
    procedure Stop;
    procedure RecordData(const Category: string; J: TJSONObject);
    destructor Destroy; override;
  end;
function TableFor(const C: TTeacherConfig): string;
begin if C.Profile='standard_v2' then Result:=SymbolTableV2 else Result:=TableText end;
function TableId(const C: TTeacherConfig): string;
begin if C.Profile='standard_v2' then Result:='international_wabun_v2'
  else Result:='international_subset_v1' end;
function GeneratorId(const C: TTeacherConfig): string;
begin if C.Profile='standard_v2' then Result:='teacher-0.3-p2'
  else Result:='teacher-0.2-p1' end;
function EmittedFor(const C: TTeacherConfig): string;
var Items: TSendTokens; I: integer;
begin
  if C.Profile<>'standard_v2' then Exit(C.Text);
  Items:=Tokenize(C.Text,C.Mode); Result:='';
  for I:=0 to High(Items) do Result:=Result+Items[I].Value;
end;

procedure Same(Expected, Actual: TJSONData; const Where: string);
var I: integer; E,A: TJSONObject;
begin
  Require(Actual<>nil,'Missing '+Where);
  Require(Expected.JSONType=Actual.JSONType,'Wrong type '+Where);
  if Expected.JSONType=jtObject then begin
    E:=TJSONObject(Expected); A:=TJSONObject(Actual);
    for I:=0 to E.Count-1 do Same(E.Items[I],A.Find(E.Names[I]),Where+'.'+E.Names[I]);
  end else if Expected.JSONType=jtArray then begin
    Require(Expected.Count=Actual.Count,'Wrong array length '+Where);
    for I:=0 to Expected.Count-1 do Same(Expected.Items[I],Actual.Items[I],Where+'['+IntToStr(I)+']');
  end else if (Expected.JSONType=jtNumber) and (TJSONNumber(Expected).NumberType=ntFloat) then
    Require(Abs(Expected.AsFloat-Actual.AsFloat)<=1E-10,'Numeric value mismatch '+Where)
  else Require(Expected.AsJSON=Actual.AsJSON,'Value mismatch '+Where);
end;
procedure TRecords.Start;
begin
  if Compare then begin
    SymbolInput:=TBoundedLineReader.Create(Dir+'symbols.jsonl');
    TokenInput:=TBoundedLineReader.Create(Dir+'tokens.jsonl');
  end else begin
    AssignFile(Symbols,Dir+'symbols.jsonl'); AssignFile(Tokens,Dir+'tokens.jsonl');
    Rewrite(Symbols); SetTextLineEnding(Symbols,#10); SymbolsOpen:=True;
    Rewrite(Tokens); SetTextLineEnding(Tokens,#10); TokensOpen:=True;
  end;
end;
procedure TRecords.Stop;
begin
  if Compare then begin
    Require(SymbolInput.AtEnd,'Extra symbol records'); Require(TokenInput.AtEnd,'Extra token records');
    FreeAndNil(SymbolInput); FreeAndNil(TokenInput);
  end else begin
    CloseFile(Symbols); SymbolsOpen:=False; CloseFile(Tokens); TokensOpen:=False;
  end;
end;
destructor TRecords.Destroy;
begin
  if SymbolsOpen then CloseFile(Symbols);
  if TokensOpen then CloseFile(Tokens);
  SymbolInput.Free; TokenInput.Free;
  inherited Destroy;
end;
procedure TRecords.RecordData(const Category: string; J: TJSONObject);
var Line: string; D: TJSONData;
begin
  if Compare then begin
    if Category='symbols' then Line:=SymbolInput.NextLine
    else Line:=TokenInput.NextLine;
    D:=ParseRecordJSON(Line);
    try Same(J,D,Category) finally D.Free end;
  end else if Category='symbols' then WriteLn(Symbols,J.AsJSON) else WriteLn(Tokens,J.AsJSON);
  if (Category='symbols') and (C.Profile<>'upstream_keyer_legacy') then RenderEvent(Audio,C,J);
end;
procedure WriteText(const Path, Text: string);
var F: TFileStream;
begin
  F:=TFileStream.Create(Path,fmCreate);
  try if Text<>'' then F.WriteBuffer(Text[1],Length(Text)) finally F.Free end;
end;
procedure SingleRow(const Dir, Name: string; Expected: TJSONObject; Compare: boolean);
var Actual: TJSONObject;
begin
  try
    if Compare then begin
      Actual:=ReadObject(Dir+Name);
      try Same(Expected,Actual,Name) finally Actual.Free end;
    end else WriteText(Dir+Name,Expected.AsJSON+#10);
  finally Expected.Free end;
end;
procedure RenderLegacy(Audio: TAudioFiles; const C: TTeacherConfig);
var K: TKeyer; E: TSingleArray; I,J,N,V: integer; B: array[0..8191] of byte;
begin
  K:=TKeyer.Create;
  try
    K.Wpm:=C.MilliWpm div 1000; K.BufSize:=512; K.MorseMsg:=K.Encode(C.Text); E:=K.Envelope;
    I:=0;
    while I<Length(E) do begin
      N:=Min(4096,Length(E)-I);
      for J:=0 to N-1 do begin
        V:=Round(C.Amplitude*E[I+J]*Cos(2*Pi*C.Pitch*(I+J)/Rate));
        B[J*2]:=V and 255; B[J*2+1]:=(V shr 8) and 255;
      end;
      Audio.Samples(B,N); Inc(I,N);
    end;
  finally K.Free end;
end;
procedure ProcessData(const Dir, Session: string; const C: TTeacherConfig;
  Files: TJSONArray; Compare: boolean);
var Timeline: TTimeline; Records: TRecords; Audio: TAudioFiles; J,Expected: TJSONObject;
  F: TFileStream; Names: array[0..5] of string; Name: string;
begin
  Timeline:=nil; Records:=nil; Audio:=nil;
  try
    Timeline:=TTimeline.Create(C,Session); Timeline.Run;
    Audio:=TAudioFiles.Create(Dir,Session,C,Timeline.TotalSamples,Files,Compare);
    Records:=TRecords.Create; Records.C:=C; Records.Session:=Session; Records.Dir:=Dir;
    Records.Compare:=Compare; Records.Audio:=Audio; Records.Start;
    Timeline.OnRecord:=@Records.RecordData; Timeline.Run; Records.Stop;
    if C.Profile='upstream_keyer_legacy' then RenderLegacy(Audio,C);
    Audio.Finish;
    J:=TJSONObject.Create(['schema_version',SchemaFor(C),'session_id',Session,
      'station_id','st01','role','target','mode',C.Mode,'pitch_hz',C.Pitch,
      'amplitude',C.Amplitude]);
    AddWpm(J,'wpm_equivalent',C.MilliWpm); SingleRow(Dir,'stations.jsonl',J,Compare);
    SingleRow(Dir,'messages.jsonl',TJSONObject.Create(['schema_version',SchemaFor(C),'session_id',Session,
      'station_id','st01','message_id','m001','mode',C.Mode,'source_text',C.Text,
      'emitted_text',EmittedFor(C),'render_status','complete','start_sample',Int64(0),
      'end_sample',Timeline.LabelEnd,'symbol_table_id',TableId(C)]),Compare);
    if Compare then begin
      F:=TFileStream.Create(Dir+'conditions.jsonl',fmOpenRead or fmShareDenyWrite);
      try Require(F.Size=0,'Unexpected conditions in a clean dataset') finally F.Free end;
      J:=ReadObject(Dir+'config.json'); Expected:=nil;
      try Expected:=ConfigJSON(C); Same(Expected,J,'config') finally Expected.Free; J.Free end;
      Require(HashFile(Dir+'symbol_table.txt')=HashText(TableFor(C)),'Symbol table differs');
    end else begin
      WriteText(Dir+'conditions.jsonl',''); WriteText(Dir+'symbol_table.txt',TableFor(C));
      J:=ConfigJSON(C); try SaveObject(Dir+'config.json',J) finally J.Free end;
    end;
    Names[0]:='symbols.jsonl'; Names[1]:='tokens.jsonl'; Names[2]:='stations.jsonl';
    Names[3]:='messages.jsonl'; Names[4]:='conditions.jsonl'; Names[5]:='config.json';
    for Name in Names do AddFile(Files,Dir,Name);
    AddFile(Files,Dir,'symbol_table.txt');
  finally Records.Free; Audio.Free; Timeline.Free end;
end;
function BaseManifest(const C: TTeacherConfig; const Session: string): TJSONObject;
var T: TTimeline;
begin
  T:=TTimeline.Create(C,Session);
  try
    T.Run;
    Result:=TJSONObject.Create(['schema_version',SchemaFor(C),'complete',True,'session_id',Session,
      'session_code',SessionCode(Session),'pipeline','keyer_only_no_receiver_effects',
      'sample_rate_hz',Rate,'channels',1,'sample_format','pcm_s16le',
      'session_sample_count',T.TotalSamples,'label_end_sample',T.LabelEnd,
      'timing_profile',C.Profile,'coordinates','zero_based_half_open_logical_keying',
      'label_source','synthetic_exact','symbol_table_id',TableId(C),
      'symbol_table_sha256',HashText(TableFor(C)),'speed_basis','PARIS_50_units',
      'dot_duration_ms',Double(1200000)/C.MilliWpm,
      'generator_version',GeneratorId(C),'dropped_samples',0,'writer_overruns',0,
      'validation_file','validation.json']);
    AddWpm(Result,'wpm_equivalent',C.MilliWpm);
    if C.Profile='standard_v2' then
      Result.Add('symbol_table_source',TJSONObject.Create([
        'international','ITU-R M.1677-1 (10/2009)',
        'wabun','Japanese Radio Station Operation Regulations Annex 1, revision 325M50080000017_20260324_508M60000008028']));
    if (C.Profile='standard_v2') and (C.JitterMilli>0) then begin
      Result.Add('rng_algorithm','xorshift32_v1'); Result.Add('seed',C.Seed);
      Result.Add('rng_reason','Seeded per-event duration variation; session UUID is independent');
    end else begin
      Result.Add('rng_algorithm',TJSONNull.Create); Result.Add('seed',TJSONNull.Create);
      if C.Profile='standard_v2' then
        Result.Add('rng_reason','No signal randomness; session UUID is independent')
      else Result.Add('rng_reason','No signal randomness in P1; session UUID is independent');
    end;
    Result.Add('corpus_id',TJSONNull.Create); Result.Add('corpus_sha256',TJSONNull.Create);
    Result.Add('corpus_reason','Inline literal text recorded in config.json');
    Result.Add('effects',TJSONArray.Create);
    Result.Add('config',ConfigJSON(C));
    if C.Profile<>'upstream_keyer_legacy' then begin
      Result.Add('envelope','raised_cosine_attack_at_keydown_release_at_keyup');
      Result.Add('ramp_samples',Round(0.005*Rate));
    end else begin
      Result.Add('envelope','upstream_blackman_harris');
      Result.Add('ramp_samples',Round(2.7*Single(0.005)*Rate));
    end;
  finally T.Free end;
end;
function ValidationJSON(const Session: string; const C: TTeacherConfig): TJSONObject;
begin
  Result:=TJSONObject.Create(['schema_version',SchemaFor(C),'session_id',Session,'passed',True,
    'scope','config_table_records_and_reconstructed_pcm',
    'validator_version',GeneratorId(C),'manifest_hash_included',False]);
end;
procedure CheckHex(const Value: string; Count: integer);
var Ch: char;
begin
  Require(Length(Value)=Count,'Invalid hash/commit length');
  for Ch in Value do Require(Ch in ['0'..'9','a'..'f'],'Invalid hash/commit hex');
end;
procedure Audit(const Dir: string; Manifest: TJSONObject; IncludeValidation: boolean);
var C: TTeacherConfig; Session: string; Expected,Migration: TJSONObject; Files: TJSONArray;
  D: TJSONData; Timestamp: TDateTime;
begin
  Require((S(Manifest,'schema_version')='0.2') or (S(Manifest,'schema_version')='0.3'),
    'Unsupported dataset schema (0.1 requires migrate_dataset)');
  Session:=S(Manifest,'session_id'); SessionCode(Session);
  Require((Session[15]='4') and (Session[20] in ['8','9','a','b']),'Expected UUID v4');
  C:=LoadConfig(TJSONObject(Need(Manifest,'config',jtObject)),True);
  Require(S(Manifest,'schema_version')=SchemaFor(C),'Manifest/config schema mismatch');
  Require(TryISO8601ToDate(S(Manifest,'created_at_utc'),Timestamp),'Invalid UTC creation time');
  Require((Length(S(Manifest,'created_at_utc'))=20) and (Copy(S(Manifest,'created_at_utc'),20,1)='Z'),
    'Creation time must use UTC Z');
  CheckHex(S(Manifest,'generator_binary_sha256'),64);
  Require((S(Manifest,'os')<>'') and (S(Manifest,'cpu_arch')<>'') and
    (S(Manifest,'compiler_version')<>''),'Missing build provenance');
  D:=Manifest.Find('source_commit'); Require(D<>nil,'Missing source_commit');
  if D.JSONType=jtNull then begin
    Need(Manifest,'source_dirty',jtNull); Require(S(Manifest,'source_reason')<>'','Missing source reason');
  end else begin CheckHex(S(Manifest,'source_commit'),40); Need(Manifest,'source_dirty',jtBoolean) end;
  if C.Profile='upstream_keyer_legacy' then begin
    Require((Length(C.Text)<=256) and (C.MilliWpm mod 1000=0) and (C.Amplitude=12000),'Invalid legacy migration settings');
    Require(S(Manifest,'provenance_kind')='migration_0.1','Missing legacy provenance');
    Migration:=TJSONObject(Need(Manifest,'migration',jtObject));
    Require(S(Migration,'source_schema')='0.1','Wrong migration source');
    CheckHex(S(Migration,'source_manifest_sha256'),64); CheckHex(S(Migration,'source_wav_sha256'),64);
    Require(S(Migration,'original_provenance')='unknown','Cannot infer original build provenance');
  end else begin
    Require(S(Manifest,'provenance_kind')='generated','Wrong provenance');
    Require(Manifest.Find('migration')=nil,'Generated session must not claim legacy migration');
  end;
  Expected:=BaseManifest(C,Session); Files:=TJSONArray.Create;
  try
    Same(Expected,Manifest,'manifest');
    Require(S(Manifest,'config_sha256')=HashFile(Dir+'config.json'),'Config hash mismatch');
    ProcessData(Dir,Session,C,Files,True);
    if C.Profile='upstream_keyer_legacy' then
      Require(S(TJSONObject(Files[0]),'sha256')=S(TJSONObject(Manifest.Find('migration')),'source_wav_sha256'),
        'Migration changed original WAV');
    if IncludeValidation then begin
      SingleRow(Dir,'validation.json',ValidationJSON(Session,C),True);
      AddFile(Files,Dir,'validation.json');
    end;
    Same(Files,Need(Manifest,'files',jtArray),'files');
  finally Files.Free; Expected.Free end;
end;
procedure ValidateDataset(const Dir: string);
var M: TJSONObject;
begin
  M:=ReadObject(IncludeTrailingPathDelimiter(ExpandFileName(Dir))+'manifest.json');
  try Audit(IncludeTrailingPathDelimiter(ExpandFileName(Dir)),M,True) finally M.Free end;
end;
procedure WriteDataset(const OutputDir: string; const C: TTeacherConfig; Migration: TJSONObject);
var Dir,Session: string; M,J: TJSONObject; Files: TJSONArray; T: TTimeline;
begin
  Session:=NewSession; Dir:=IncludeTrailingPathDelimiter(ExpandFileName(OutputDir));
  T:=TTimeline.Create(C,Session);
  try
    T.Run;
    Require((T.TotalSamples+Int64(C.ChunkSeconds)*Rate-1) div (Int64(C.ChunkSeconds)*Rate)<=16000,
      'P1 manifest supports at most 16000 audio parts; increase chunk_seconds');
  finally T.Free end;
  CheckOutputPath(Dir+AudioName(Session,'r',999999)+'.partial');
  Require(not DirectoryExists(Dir) and not FileExists(ExcludeTrailingPathDelimiter(Dir)),'Output exists; refusing overwrite');
  Require(ForceDirectories(ExtractFileDir(ExcludeTrailingPathDelimiter(Dir))),'Cannot create parent');
  Require(CreateDir(ExcludeTrailingPathDelimiter(Dir)),'Cannot exclusively create output directory');
  M:=nil; J:=nil; Files:=nil;
  try
    Files:=TJSONArray.Create; ProcessData(Dir,Session,C,Files,False);
    M:=BaseManifest(C,Session); M.Add('files',Files); Files:=nil;
    M.Add('config_sha256',HashFile(Dir+'config.json'));
    M.Add('created_at_utc',FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',LocalTimeToUniversal(Now)));
    M.Add('generator_binary_sha256',HashFile(ExecutablePath));
    M.Add('compiler_version',{$I %FPCVERSION%});
    M.Add('os',{$I %FPCTARGETOS%}); M.Add('cpu_arch',{$I %FPCTARGETCPU%});
    if SourceCommit='' then begin
      M.Add('source_commit',TJSONNull.Create); M.Add('source_dirty',TJSONNull.Create);
      M.Add('source_reason','Build without tools/build_teacher.ps1');
    end else begin M.Add('source_commit',SourceCommit); M.Add('source_dirty',SourceDirty) end;
    if Migration=nil then M.Add('provenance_kind','generated')
    else begin M.Add('provenance_kind','migration_0.1'); M.Add('migration',Migration.Clone) end;
    Audit(Dir,M,False);
    J:=ValidationJSON(Session,C); SaveObject(Dir+'validation.json',J);
    AddFile(M.Arrays['files'],Dir,'validation.json');
    SaveObject(Dir+'manifest.json.partial',M);
    Require(RenameFile(Dir+'manifest.json.partial',Dir+'manifest.json'),'Cannot finalize manifest');
    WriteLn('Complete: ',Dir);
  finally Files.Free; J.Free; M.Free end;
end;
procedure GenerateDataset(const OutputDir: string; const C: TTeacherConfig);
begin Require((C.Profile='standard_v1') or (C.Profile='standard_v2'),'Generator supports standard profiles only'); WriteDataset(OutputDir,C,nil) end;

type TLegacyCheck = class
  F: TextFile;
  Opened: boolean;
    Index: integer;
    Code: string;
    MarkIndex: integer;
  procedure Check(const Category: string; J: TJSONObject);
  destructor Destroy; override;
end;
procedure TLegacyCheck.Check(const Category: string; J: TJSONObject);
var Line: string; Old: TJSONData; O: TJSONObject;
begin
  if Category<>'symbols' then Exit;
  Require(not EOF(F),'Missing legacy events'); ReadBoundedLine(F,Line); Old:=ParseRecordJSON(Line);
  try
    Require(Old.JSONType=jtObject,'Invalid legacy event'); O:=TJSONObject(Old);
    if (S(J,'kind')='dit') or (S(J,'kind')='dah') then begin
      Inc(MarkIndex);
      while (MarkIndex<=Length(Code)) and not (Code[MarkIndex] in ['.','-']) do Inc(MarkIndex);
    end;
    Require((N(O,'event_id')=Index) and (S(O,'station_id')='station_1') and
      (S(O,'message_id')='message_1') and (S(O,'kind')=S(J,'kind')) and
      (N(O,'morse_index_1based')=MarkIndex) and
      (N(O,'start_sample')=N(J,'start_sample')) and (N(O,'end_sample')=N(J,'end_sample')),'Legacy event mismatch');
    Inc(Index);
  finally Old.Free end;
end;
destructor TLegacyCheck.Destroy;
begin if Opened then CloseFile(F); inherited Destroy end;
procedure MigrateDataset(const InputDir, OutputDir: string);
var Dir: string; Old,Msg,CJ,Prov: TJSONObject; C: TTeacherConfig;
  T: TTimeline; L: TLegacyCheck; Key: TKeyer; Env: TSingleArray;
  W: TFileStream; Header: array[0..43] of byte; I,V: integer; Setting: Int64; B: array[0..1] of byte;
  function LE32(Offset: integer): cardinal;
  begin Result:=cardinal(Header[Offset]) or (cardinal(Header[Offset+1]) shl 8) or
    (cardinal(Header[Offset+2]) shl 16) or (cardinal(Header[Offset+3]) shl 24) end;
begin
  Dir:=IncludeTrailingPathDelimiter(ExpandFileName(InputDir));
  Old:=nil; Msg:=nil; CJ:=nil; Prov:=nil; T:=nil; L:=nil; Key:=nil; W:=nil;
  try
    Old:=ReadObject(Dir+'manifest.json'); Msg:=ReadObject(Dir+'message.json');
    Require(S(Old,'schema_version')='0.1','Migration requires schema 0.1');
    Require(Need(Old,'complete',jtBoolean).AsBoolean and Need(Old,'observer_audio_equal',jtBoolean).AsBoolean,'Incomplete legacy dataset');
    Require((S(Old,'pipeline')='keyer_only_no_receiver_effects') and
      (S(Old,'timing_profile')='upstream_keyer_legacy') and (N(Old,'sample_rate_hz')=Rate) and
      (N(Old,'channels')=1) and (S(Old,'sample_format')='pcm_s16le'),'Unsupported legacy audio');
    Require((S(Old,'generator')='MorseRunner-Server/export_sample') and
      (S(Old,'coordinates')='zero_based_half_open_logical_keying'),'Unsupported legacy coordinates/generator');
    C.Text:=S(Msg,'emitted_text'); C.Profile:='upstream_keyer_legacy'; C.Mode:='international';
    Setting:=N(Old,'wpm_setting'); Require((Setting>=5) and (Setting<=60),'Invalid legacy WPM');
    C.MilliWpm:=Setting*1000;
    Setting:=N(Old,'pitch_hz'); Require((Setting>=200) and (Setting<=1200),'Invalid legacy pitch'); C.Pitch:=Setting;
    C.Amplitude:=12000; C.ChunkSeconds:=3600;
    CJ:=ConfigJSON(C); C:=LoadConfig(CJ,True);
    Require(Length(C.Text)<=256,'Legacy text too long');
    Require((S(Msg,'mode')='international') and (S(Msg,'station_id')='station_1') and
      (S(Msg,'message_id')='message_1'),'Unsupported legacy message');
    Key:=TKeyer.Create; Key.Wpm:=C.MilliWpm div 1000; Key.BufSize:=512;
    Require((N(Old,'samples_per_dit')=Round(0.1*Rate*12/Key.Wpm)) and
      (Abs(Need(Old,'rise_time_seconds',jtNumber).AsFloat-Key.RiseTime)<1E-8),'Legacy timing metadata differs');
    Key.MorseMsg:=Key.Encode(C.Text); Require(Key.MorseMsg=S(Msg,'encoded_morse'),'Legacy encoding differs');
    Env:=Key.Envelope;
    Require((Length(Env)=N(Old,'sample_count')) and (Key.RampLen=N(Old,'ramp_samples')) and
      (N(Old,'buffer_samples')=512),'Legacy envelope metadata differs');
    W:=TFileStream.Create(Dir+'received.wav',fmOpenRead or fmShareDenyWrite);
    W.ReadBuffer(Header,44);
    Require((LE32(0)=$46464952) and (LE32(8)=$45564157) and (LE32(12)=$20746d66) and
      (LE32(36)=$61746164) and (LE32(16)=16) and (LE32(20)=$00010001) and
      (LE32(24)=Rate) and (LE32(28)=Rate*2) and (LE32(32)=$00100002) and
      (LE32(4)=36+Length(Env)*2) and (LE32(40)=Length(Env)*2) and
      (W.Size=44+Int64(Length(Env))*2),'Legacy WAV header differs');
    for I:=0 to High(Env) do begin
      V:=Round(12000*Env[I]*Cos(2*Pi*C.Pitch*I/Rate)); W.ReadBuffer(B,2);
      Require((B[0]=(V and 255)) and (B[1]=((V shr 8) and 255)),'Legacy PCM differs');
    end;
    FreeAndNil(W); Env:=nil; FreeAndNil(Key);
    L:=TLegacyCheck.Create; L.Code:=S(Msg,'encoded_morse');
    AssignFile(L.F,Dir+'symbols.jsonl'); Reset(L.F); L.Opened:=True;
    T:=TTimeline.Create(C,'migration-check'); T.OnRecord:=@L.Check; T.Run;
    Require(EOF(L.F),'Extra legacy events');
    Prov:=TJSONObject.Create(['source_schema','0.1','source_manifest_sha256',HashFile(Dir+'manifest.json'),
      'source_wav_sha256',HashFile(Dir+'received.wav'),'original_provenance','unknown',
      'note','Legacy metadata and PCM verified; original build identity was not recorded']);
    WriteDataset(OutputDir,C,Prov);
  finally W.Free; Key.Free; L.Free; T.Free; Prov.Free; CJ.Free; Msg.Free; Old.Free end;
end;
end.
