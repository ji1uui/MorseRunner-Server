unit TeacherTiming;
{$mode objfpc}{$H+}
interface
uses SysUtils, Math, fpjson, TeacherContract;
type
  TRecordSink = procedure(const Category: string; J: TJSONObject) of object;
  TTimeline = class
  private
    C: TTeacherConfig;
    Session: string;
    Units, Cursor, ClockMicro: Int64;
    EventNo, TokenNo: integer;
    CurrentMilli, TotalTokenCount: integer;
    RandomState: cardinal;
    LegacyUnit, LegacyRamp: integer;
    FOnRecord: TRecordSink;
    function Position: Int64;
    function Emit(const Kind, Token: string; UnitCount: integer; MinusRamp: integer = 0): string;
    procedure RunModern;
  public
    TotalSamples, LabelEnd: Int64;
    constructor Create(const Config: TTeacherConfig; const SessionId: string);
    procedure Run;
    property OnRecord: TRecordSink read FOnRecord write FOnRecord;
  end;
implementation
uses TeacherSymbols;
constructor TTimeline.Create(const Config: TTeacherConfig; const SessionId: string);
begin
  inherited Create; C:=Config; Session:=SessionId;
  LegacyUnit:=Round(1.2*Rate/(C.MilliWpm/1000));
  // Match the legacy Single-precision RiseTime assignment, not a new ramp.
  LegacyRamp:=Round(2.7*Single(0.005)*Rate);
end;
function TTimeline.Position: Int64;
begin
  if C.Profile='upstream_keyer_legacy' then Exit(Cursor);
  if (C.Profile='standard_v2') and
    ((C.EndMilliWpm<>C.MilliWpm) or (C.GapScaleMilli<>1000) or (C.JitterMilli<>0)) then
    Exit((ClockMicro+500000) div 1000000);
  // Integer rational arithmetic: no cumulative floating point drift.
  Result:=(Units*Int64(Rate)*1200+C.MilliWpm div 2) div C.MilliWpm;
end;
function TTimeline.Emit(const Kind, Token: string; UnitCount: integer; MinusRamp: integer): string;
var J: TJSONObject; StartAt, DeltaMicro: Int64; Factor: integer;
begin
  StartAt:=Position;
  if (C.Profile='standard_v2') and
    ((C.EndMilliWpm<>C.MilliWpm) or (C.GapScaleMilli<>1000) or (C.JitterMilli<>0)) then begin
    Factor:=1000;
    if (Kind='character_gap') or (Kind='word_gap') then Factor:=C.GapScaleMilli;
    if (C.JitterMilli>0) and (Kind<>'trailing_gap') then begin
      RandomState:=RandomState xor (RandomState shl 13);
      RandomState:=RandomState xor (RandomState shr 17);
      RandomState:=RandomState xor (RandomState shl 5);
      Factor:=(Int64(Factor)*(1000-C.JitterMilli+integer(RandomState mod cardinal(2*C.JitterMilli+1)))+500) div 1000;
    end;
    DeltaMicro:=(Int64(UnitCount)*Rate*1200*1000000*Factor+Int64(CurrentMilli)*500) div (Int64(CurrentMilli)*1000);
    Inc(ClockMicro,DeltaMicro);
  end;
  Inc(Units,UnitCount);
  Inc(Cursor,Int64(UnitCount)*LegacyUnit-Int64(MinusRamp)*LegacyRamp);
  Result:='e'+IntToStr(EventNo); Inc(EventNo);
  if not Assigned(FOnRecord) then Exit;
  J:=TJSONObject.Create(['schema_version',SchemaFor(C),'session_id',Session,'event_id',Result,
    'station_id','st01','message_id','m001','kind',Kind,
    'start_sample',StartAt,'end_sample',Position,'label_source','synthetic_exact']);
  try
    if Token='' then J.Add('token_id',TJSONNull.Create) else J.Add('token_id',Token);
    FOnRecord('symbols',J);
  finally J.Free end;
end;
procedure TTimeline.RunModern;
var Items: TSendTokens; I,K,NextItem: integer; Token,Id: string;
  StartAt,EndAt: Int64; J: TJSONObject; Ids: TJSONArray;
begin
  Items:=Tokenize(C.Text,C.Mode);
  Units:=0; Cursor:=0; ClockMicro:=0; EventNo:=0; TokenNo:=0;
  RandomState:=cardinal(C.Seed); TotalTokenCount:=0;
  for I:=0 to High(Items) do if not Items[I].IsSpace then Inc(TotalTokenCount);
  for I:=0 to High(Items) do begin
    if Items[I].IsSpace then Continue;
    if TotalTokenCount<=1 then CurrentMilli:=C.MilliWpm
    else CurrentMilli:=C.MilliWpm+Int64(C.EndMilliWpm-C.MilliWpm)*TokenNo div (TotalTokenCount-1);
    Token:='t'+IntToStr(TokenNo); Inc(TokenNo);
    StartAt:=Position; Ids:=TJSONArray.Create; J:=nil;
    try
      for K:=1 to Length(Items[I].Code) do begin
        if Items[I].Code[K]='.' then Id:=Emit('dit',Token,1)
        else Id:=Emit('dah',Token,3);
        Ids.Add(Id);
        if K<Length(Items[I].Code) then Emit('intra_character_gap',Token,1);
      end;
      EndAt:=Position;
      if Assigned(FOnRecord) then begin
        J:=TJSONObject.Create(['schema_version',SchemaFor(C),'session_id',Session,'token_id',Token,
          'station_id','st01','message_id','m001','token_index',TokenNo-1,
          'source_token_index',Items[I].SourceIndex,'mode',Items[I].Mode,
          'token_type',Items[I].Kind,'emitted_value',Items[I].Value,
          'morse_pattern',Items[I].Code,'start_sample',StartAt,
          'end_sample',EndAt,'render_status','complete']);
        J.Add('event_ids',Ids); Ids:=nil; FOnRecord('tokens',J);
      end;
    finally J.Free; Ids.Free end;
    NextItem:=I+1;
    while (NextItem<=High(Items)) and Items[NextItem].IsSpace do Inc(NextItem);
    if NextItem>High(Items) then Emit('trailing_gap','',3)
    else if NextItem>I+1 then Emit('word_gap','',7)
    else Emit('character_gap','',3);
  end;
  LabelEnd:=Position; TotalSamples:=LabelEnd;
end;
procedure TTimeline.Run;
var I,K,NextChar,Spaces: integer; Code,Token,Kind,Id: string;
  StartAt,EndAt: Int64; J: TJSONObject; Ids: TJSONArray;
begin
  if C.Profile='standard_v2' then begin RunModern; Exit end;
  Units:=0; Cursor:=0; EventNo:=0; TokenNo:=0; I:=1;
  while I<=Length(C.Text) do begin
    Code:=Pattern(C.Text[I]); Token:='t'+IntToStr(TokenNo); Inc(TokenNo);
    StartAt:=Position; Ids:=TJSONArray.Create; J:=nil;
    try
      for K:=1 to Length(Code) do begin
        if Code[K]='.' then Id:=Emit('dit',Token,1) else Id:=Emit('dah',Token,3);
        Ids.Add(Id);
        if K<Length(Code) then Emit('intra_character_gap',Token,1);
      end;
      EndAt:=Position;
      if Assigned(FOnRecord) then begin
        if C.Text[I] in ['A'..'Z'] then Kind:='character'
        else if C.Text[I] in ['0'..'9'] then Kind:='digit' else Kind:='punctuation';
        J:=TJSONObject.Create(['schema_version',SchemaFor(C),'session_id',Session,'token_id',Token,
          'station_id','st01','message_id','m001','token_index',TokenNo-1,'source_token_index',I-1,
          'mode','international','token_type',Kind,'emitted_value',string(C.Text[I]),
          'morse_pattern',Code,'start_sample',StartAt,'end_sample',EndAt,'render_status','complete']);
        J.Add('event_ids',Ids); Ids:=nil; FOnRecord('tokens',J);
      end;
    finally J.Free; Ids.Free end;
    NextChar:=I+1;
    while (NextChar<=Length(C.Text)) and (C.Text[NextChar]=' ') do Inc(NextChar);
    Spaces:=NextChar-I-1;
    if NextChar>Length(C.Text) then begin
      if C.Profile='standard_v1' then Emit('trailing_gap','',3)
      else Emit('trailing_gap','',2,1);
    end else if Spaces>0 then begin
      if C.Profile='standard_v1' then Emit('word_gap','',7)
      else Emit('word_gap','',3+2*Spaces,1+Spaces);
    end else if C.Profile='standard_v1' then Emit('character_gap','',3)
    else Emit('character_gap','',3,1);
    I:=NextChar;
  end;
  LabelEnd:=Position; TotalSamples:=LabelEnd;
  if C.Profile='upstream_keyer_legacy' then
    TotalSamples:=512*((Units*LegacyUnit+LegacyRamp+511) div 512);
end;
end.
