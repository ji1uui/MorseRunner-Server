//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
unit MorseKey;

{$MODE Delphi}

interface

uses
  SysUtils, Classes, SndTypes, MorseTbl, Math;

type
  // Logical keying coordinates, before envelope smoothing; end is exclusive.
  TKeyingEvent = procedure(const Kind: string; StartSample, EndSample: Int64;
    MorseIndex: integer) of object;

  TKeyer = class
  private
    Morse: array[char] of string;
//    RampLen: integer;
//    RampOn, RampOff: TSingleArray;
    FRiseTime: single;

    function GetEnvelope: TSingleArray;
    procedure LoadMorseTable;
    procedure MakeRamp;
    function BlackmanHarrisKernel(x: single): single;
    function BlackmanHarrisStepResponse(Len: integer): TSingleArray;
    procedure SetRiseTime(const Value: single);
  public
    RampLen: integer;
    RampOn, RampOff: TSingleArray;

    Wpm: integer;
    BufSize: integer;
    Rate: integer;
    MorseMsg: string;
    TrueEnvelopeLen: integer;
    OnKeyingEvent: TKeyingEvent; // nil preserves the original audio path

    constructor Create;
    function Encode(Txt: string): string;

    property RiseTime: single read FRiseTime write SetRiseTime;
    property Envelope: TSingleArray read GetEnvelope;
  end;


procedure MakeKeyer;
procedure DestroyKeyer;

var
  Keyer: TKeyer;


implementation

procedure MakeKeyer;
begin
  Keyer := TKeyer.Create;
end;


procedure DestroyKeyer;
begin
  Keyer.Free;
end;



{ TKeyer }

constructor TKeyer.Create;
begin
  LoadMorseTable;
  Rate := 22050;
  RiseTime := 0.005;
end;


procedure TKeyer.SetRiseTime(const Value: single);
begin
  FRiseTime := Value;
  MakeRamp;
end;


procedure TKeyer.LoadMorseTable;
var
  i: integer;
  S: string;
  Ch: char;
begin
  for i := 0 to High(MorseTable) do
  begin
    S := MorseTable[i];
    if S[2] <> '[' then Continue;
    Ch := S[1];
    Morse[Ch] := Copy(S, 3, Pos(']', S) - 3) + ' ';
  end;
end;


function TKeyer.BlackmanHarrisKernel(x: single): single;
const
  a0 = 0.35875;
  a1 = 0.48829;
  a2 = 0.14128;
  a3 = 0.01168;
begin
  Result := a0 - a1 * Cos(2 * Pi * x) + a2 * Cos(4 * Pi * x) - a3 * Cos(6 * Pi * x);
end;


function TKeyer.BlackmanHarrisStepResponse(Len: integer): TSingleArray;
var
  i: integer;
  Scale: single;
begin
  SetLength(Result, Len);
  //generate kernel
  for i := 0 to High(Result) do Result[i] := BlackmanHarrisKernel(i / Len);
  //integrate
  for i := 1 to High(Result) do Result[i] := Result[i - 1] + Result[i];
  //normalize
  Scale := 1 / Result[High(Result)];
  for i := 0 to High(Result) do Result[i] := Result[i] * Scale;
end;


procedure TKeyer.MakeRamp;
var
  i: integer;
begin
  RampLen := Round(2.7 * FRiseTime * Rate);
  RampOn := BlackmanHarrisStepResponse(RampLen);

  SetLength(RampOff, RampLen);
  for i := 0 to RampLen - 1 do RampOff[High(RampOff) - i] := RampOn[i];
end;


function TKeyer.Encode(Txt: string): string;
var
  i: integer;
begin
  Result := '';
  for i := 1 to Length(Txt) do
    if Txt[i] in [' ', '_'] then Result := Result + ' '
    else
      Result := Result + Morse[Txt[i]];
  if Result <> '' then Result[Length(Result)] := '~';
end;


function TKeyer.GetEnvelope: TSingleArray;
var
  UnitCnt, Len, i, p: integer;
  SamplesInUnit: integer;
  MarkEnd, LastMarkIndex, GapSpaces: integer;
  GapKind: string;

  procedure EmitGap;
  begin
    if (LastMarkIndex = 0) or (p <= MarkEnd) then Exit;
    if GapSpaces = 0 then GapKind := 'intra_character_gap'
    else if GapSpaces = 1 then GapKind := 'character_gap'
    else GapKind := 'word_gap';
    if Assigned(OnKeyingEvent) then
      OnKeyingEvent(GapKind, MarkEnd, p, LastMarkIndex);
  end;

  procedure EmitMark(const Kind: string; Units: integer);
  begin
    EmitGap;
    MarkEnd := p + Units * SamplesInUnit;
    LastMarkIndex := i;
    GapSpaces := 0;
    if Assigned(OnKeyingEvent) then
      OnKeyingEvent(Kind, p, MarkEnd, i);
  end;

  procedure AddRampOn;
  begin
    Move(RampOn[0], Result[p], RampLen * SizeOf(single));
    Inc(p, Length(RampOn));
  end;

  procedure AddRampOff;
  begin
    Move(RampOff[0], Result[p], RampLen * SizeOf(single));
    Inc(p, Length(RampOff));
  end;

  procedure AddOn(Dur: integer);
  var
    i: integer;
  begin
    for i := 0 to Dur * SamplesInUnit - RampLen - 1 do Result[p + i] := 1;
    Inc(p, Dur * SamplesInUnit - RampLen);
  end;

  procedure AddOff(Dur: integer);
  begin
    Inc(p, Dur * SamplesInUnit - RampLen);
  end;

begin
  //count units
  UnitCnt := 0;
  for i := 1 to Length(MorseMsg) do
    case MorseMsg[i] of
      '.': Inc(UnitCnt, 2);
      '-': Inc(UnitCnt, 4);
      ' ': Inc(UnitCnt, 2);
      '~': Inc(UnitCnt, 1);
    end;

  //calc buffer size
  SamplesInUnit := Round(0.1 * Rate * 12 / Wpm);
  TrueEnvelopeLen := UnitCnt * SamplesInUnit + RampLen;
  Len := BufSize * Ceil(TrueEnvelopeLen / BufSize);
  Result := nil;
  SetLength(Result, Len);

  //fill buffer
  p := 0;
  MarkEnd := 0;
  LastMarkIndex := 0;
  GapSpaces := 0;
  for i := 1 to Length(MorseMsg) do
    case MorseMsg[i] of
      '.': begin
        EmitMark('dit', 1);
        AddRampOn;
        AddOn(1);
        AddRampOff;
        AddOff(1);
      end;
      '-': begin
        EmitMark('dah', 3);
        AddRampOn;
        AddOn(3);
        AddRampOff;
        AddOff(1);
      end;
      ' ': begin AddOff(2); Inc(GapSpaces); end;
      '~': AddOff(1);
    end;
  if Assigned(OnKeyingEvent) and (LastMarkIndex <> 0) then
    OnKeyingEvent('trailing_gap', MarkEnd, p, LastMarkIndex);
end;


end.
