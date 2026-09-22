program ExportSample;
{$mode objfpc}{$H+}

uses SysUtils, Classes, Math, fpjson, MorseKey, SndTypes;

type
  TCollector = class
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Event(const Kind: string; StartSample, EndSample: Int64;
      MorseIndex: integer);
  end;

constructor TCollector.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TCollector.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

procedure TCollector.Event(const Kind: string; StartSample, EndSample: Int64;
  MorseIndex: integer);
var J: TJSONObject;
begin
  J := TJSONObject.Create;
  try
    J.Add('event_id', Lines.Count);
    J.Add('station_id', 'station_1');
    J.Add('message_id', 'message_1');
    J.Add('kind', Kind);
    J.Add('start_sample', StartSample);
    J.Add('end_sample', EndSample);
    J.Add('morse_index_1based', MorseIndex);
    Lines.Add(J.AsJSON);
  finally J.Free end;
end;

procedure SaveJSON(const Path: string; J: TJSONObject);
var S: TStringStream;
begin
  S := TStringStream.Create(J.FormatJSON + LineEnding);
  try S.SaveToFile(Path) finally S.Free end;
end;

procedure WriteWav(const Path: string; const Envelope: TSingleArray;
  Rate, Pitch: integer);
var F: TFileStream; I, Used: integer; Sample: smallint; Bits: word;
  Buffer: array[0..8191] of byte;
  procedure Tag(const S: AnsiString);
  begin F.WriteBuffer(S[1], Length(S)) end;
  procedure U16(V: word);
  var B: array[0..1] of byte;
  begin B[0] := V and 255; B[1] := V shr 8; F.WriteBuffer(B, 2) end;
  procedure U32(V: cardinal);
  var B: array[0..3] of byte; K: integer;
  begin
    for K := 0 to 3 do B[K] := (V shr (8*K)) and 255;
    F.WriteBuffer(B, 4);
  end;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    Tag('RIFF'); U32(36 + Length(Envelope)*2); Tag('WAVE');
    Tag('fmt '); U32(16); U16(1); U16(1); U32(Rate);
    U32(Rate*2); U16(2); U16(16);
    Tag('data'); U32(Length(Envelope)*2);
    Used := 0;
    for I := 0 to High(Envelope) do
    begin
      Sample := Round(12000 * Envelope[I] * Cos(2*Pi*Pitch*I/Rate));
      Bits := word(integer(Sample) and $FFFF);
      Buffer[Used] := Bits and 255;
      Buffer[Used+1] := Bits shr 8;
      Inc(Used, 2);
      if Used = SizeOf(Buffer) then
      begin
        F.WriteBuffer(Buffer, Used);
        Used := 0;
      end;
    end;
    if Used > 0 then F.WriteBuffer(Buffer, Used);
  finally F.Free end;
end;

procedure Run;
var K: TKeyer; C: TCollector; J: TJSONObject;
  Baseline, Observed: TSingleArray;
  OutDir, Txt, Code: string; Wpm, Pitch, I: integer;
begin
  if ParamCount <> 4 then
    raise Exception.Create('Usage: export_sample NEW_OUTPUT_DIR "UPPERCASE TEXT" WPM PITCH_HZ');
  OutDir := ExpandFileName(ParamStr(1));
  Txt := ParamStr(2);
  Wpm := StrToInt(ParamStr(3));
  Pitch := StrToInt(ParamStr(4));
  if (Wpm < 5) or (Wpm > 60) then raise Exception.Create('WPM must be 5..60');
  if (Pitch < 200) or (Pitch > 1200) then raise Exception.Create('Pitch must be 200..1200 Hz');
  if (Length(Txt) = 0) or (Length(Txt) > 256) then
    raise Exception.Create('Text length must be 1..256 ASCII characters');
  if (Txt[1] = ' ') or (Txt[Length(Txt)] = ' ') then
    raise Exception.Create('Leading/trailing spaces are not supported');
  for I := 1 to Length(Txt) do
    if not (Txt[I] in ['A'..'Z', '0'..'9', ' ', '/', '.', ',', '?', '=']) then
      raise Exception.CreateFmt('Unsupported character at byte %d', [I]);
  if DirectoryExists(OutDir) or FileExists(OutDir) then
    raise Exception.Create('Output path already exists; refusing to overwrite');

  K := nil;
  C := nil;
  J := nil;
  try
    K := TKeyer.Create;
    C := TCollector.Create;
    J := TJSONObject.Create;
    K.Wpm := Wpm; K.BufSize := 512;
    Code := K.Encode(Txt);
    K.MorseMsg := Code;
    Baseline := K.Envelope;
    K.OnKeyingEvent := @C.Event;
    Observed := K.Envelope;
    if Length(Baseline) <> Length(Observed) then
      raise Exception.Create('Observer changed envelope length');
    for I := 0 to High(Baseline) do
      if Baseline[I] <> Observed[I] then
        raise Exception.CreateFmt('Observer changed sample %d', [I]);
    if not ForceDirectories(ExtractFileDir(OutDir)) then
      raise Exception.Create('Cannot create output parent directory');
    // Exclusive final-directory creation prevents two exporters overwriting
    // each other after both have passed the earlier existence check.
    if not CreateDir(OutDir) then
      raise Exception.Create('Cannot exclusively create output directory');
    OutDir := IncludeTrailingPathDelimiter(OutDir);
    WriteWav(OutDir + 'received.wav', Observed, K.Rate, Pitch);
    C.Lines.SaveToFile(OutDir + 'symbols.jsonl');
    J.Add('message_id', 'message_1'); J.Add('station_id', 'station_1');
    J.Add('mode', 'international'); J.Add('emitted_text', Txt);
    J.Add('encoded_morse', Code);
    SaveJSON(OutDir + 'message.json', J);
    J.Clear;
    J.Add('schema_version', '0.1'); J.Add('complete', True);
    J.Add('generator', 'MorseRunner-Server/export_sample');
    J.Add('pipeline', 'keyer_only_no_receiver_effects');
    J.Add('sample_rate_hz', K.Rate); J.Add('channels', 1);
    J.Add('sample_format', 'pcm_s16le'); J.Add('sample_count', Length(Observed));
    J.Add('wpm_setting', Wpm); J.Add('pitch_hz', Pitch);
    J.Add('samples_per_dit', Round(0.1*K.Rate*12/Wpm));
    J.Add('rise_time_seconds', K.RiseTime); J.Add('ramp_samples', K.RampLen);
    J.Add('buffer_samples', K.BufSize);
    J.Add('timing_profile', 'upstream_keyer_legacy');
    J.Add('coordinates', 'zero_based_half_open_logical_keying');
    J.Add('observer_audio_equal', True);
    // Completion manifest is written last; incomplete folders are not datasets.
    SaveJSON(OutDir + 'manifest.json', J);
    Writeln('Exported ', Length(Observed), ' samples and ', C.Lines.Count, ' events.');
  finally
    K.Free; C.Free; J.Free;
  end;
end;

begin
  try Run except
    on E: Exception do begin Writeln(StdErr, E.Message); Halt(1) end;
  end;
end.
