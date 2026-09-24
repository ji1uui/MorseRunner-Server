unit TeacherSymbols;
{$mode objfpc}{$H+}
interface
uses SysUtils;
type
  TSendToken = record
    Value, Code, Kind, Mode: string;
    SourceIndex: integer;
    IsSpace: boolean;
  end;
  TSendTokens = array of TSendToken;
function Tokenize(const Source, InitialMode: string): TSendTokens;
function SymbolTableV2: string;
implementation
const
  Kana: array[0..47] of string = (
    'イ','ロ','ハ','ニ','ホ','ヘ','ト','チ','リ','ヌ','ル','ヲ',
    'ワ','カ','ヨ','タ','レ','ソ','ツ','ネ','ナ','ラ','ム','ウ',
    'ヰ','ノ','オ','ク','ヤ','マ','ケ','フ','コ','エ','テ','ア',
    'サ','キ','ユ','メ','ミ','シ','ヱ','ヒ','モ','セ','ス','ン');
  KanaCode: array[0..47] of string = (
    '.-','.-.-','-...','-.-.','-..','.','..-..','..-.','--.','....','-.--.','.---',
    '-.-','.-..','--','-.','---','---.','.--.','--.-','.-.','...','-','..-',
    '.-..-','..--','.-...','...-','.--','-..-','-.--','--..','----','-.---','.-.--','--.--',
    '-.-.-','-.-..','-..--','-...-','..-.-','--.-.','.--..','--..-','-..-.','.---.','---.-','.-.-.');
  International = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/.,?=:'+#39+'-()"+@';
  InternationalCode: array[0..48] of string = (
    '.-','-...','-.-.','-..','.','..-.','--.','....','..','.---','-.-','.-..','--','-.','---','.--.',
    '--.-','.-.','...','-','..-','...-','.--','-..-','-.--','--..',
    '-----','.----','..---','...--','....-','.....','-....','--...','---..','----.',
    '-..-.','.-.-.-','--..--','..--..','-...-','---...','.----.','-....-','-.--.','-.--.-','.-..-.','.-.-.','.--.-.');
function ValidUTF8(const S: string): boolean;
var I,L,N,J,CP,MinCP: integer; B: byte;
begin
  I:=1; L:=Length(S);
  while I<=L do begin
    B:=Ord(S[I]);
    if B<128 then begin Inc(I); Continue end;
    if B in [$C2..$DF] then begin N:=1; CP:=B and $1F; MinCP:=$80 end
    else if B in [$E0..$EF] then begin N:=2; CP:=B and $0F; MinCP:=$800 end
    else if B in [$F0..$F4] then begin N:=3; CP:=B and $07; MinCP:=$10000 end
    else Exit(False);
    if I+N>L then Exit(False);
    for J:=1 to N do begin
      B:=Ord(S[I+J]); if not (B in [$80..$BF]) then Exit(False);
      CP:=(CP shl 6) or (B and $3F);
    end;
    if (CP<MinCP) or (CP>$10FFFF) or ((CP>=$D800) and (CP<=$DFFF)) then Exit(False);
    Inc(I,N+1);
  end;
  Result:=True;
end;
function Rune(const S: string; var At: integer): string;
var N: integer; B: byte;
begin
  B:=Ord(S[At]);
  if B<128 then N:=1 else if B<$E0 then N:=2 else if B<$F0 then N:=3 else N:=4;
  Result:=Copy(S,At,N); Inc(At,N);
end;
function CanonicalKana(const S: string): string;
var U: UnicodeString; C: WideChar;
const Small='ァィゥェォッャュョヮ'; Large='アイウエオツヤユヨワ';
begin
  U:=UTF8Decode(S);
  if Length(U)<>1 then Exit(S);
  C:=U[1];
  if (Ord(C)>=$3041) and (Ord(C)<=$3096) then C:=WideChar(Ord(C)+$60);
  Result:=UTF8Encode(UnicodeString(C));
  if Pos(Result,Small)>0 then begin
    // Both tables are indexed by Unicode scalar, never by UTF-8 byte.
    case Ord(C) of
      $30A1: Result:='ア'; $30A3: Result:='イ'; $30A5: Result:='ウ';
      $30A7: Result:='エ'; $30A9: Result:='オ'; $30C3: Result:='ツ';
      $30E3: Result:='ヤ'; $30E5: Result:='ユ'; $30E7: Result:='ヨ';
      $30EE: Result:='ワ';
    end;
  end;
  if Result='゙' then Result:='゛';
  if Result='゚' then Result:='゜';
  if Result='ﾞ' then Result:='゛';
  if Result='ﾟ' then Result:='゜';
  if (Ord(C)>=$FF10) and (Ord(C)<=$FF19) then Result:=Chr(Ord(C)-$FF10+Ord('0'));
  case Ord(C) of
    $4E00: Result:='1'; $4E8C: Result:='2'; $4E09: Result:='3';
    $56DB: Result:='4'; $4E94: Result:='5'; $516D: Result:='6';
    $4E03: Result:='7'; $516B: Result:='8'; $4E5D: Result:='9';
    $3007: Result:='0';
  end;
end;
function VoiceBase(const S: string; out Mark: string): string;
const Voiced='ガギグゲゴザジズゼゾダヂヅデドバビブベボヴ';
  Bases='カキクケコサシスセソタチツテトハヒフヘホウ';
  Semi='パピプペポ'; SemiBase='ハヒフヘホ';
var I: integer; U,V: UnicodeString;
begin
  Mark:=''; Result:=S; U:=UTF8Decode(S); V:=UTF8Decode(Voiced);
  if Length(U)<>1 then Exit;
  for I:=1 to Length(V) do if U[1]=V[I] then begin
    Result:=UTF8Encode(Copy(UTF8Decode(Bases),I,1)); Mark:='゛'; Exit;
  end;
  V:=UTF8Decode(Semi);
  for I:=1 to Length(V) do if U[1]=V[I] then begin
    Result:=UTF8Encode(Copy(UTF8Decode(SemiBase),I,1)); Mark:='゜'; Exit;
  end;
end;
function Lookup(const Value, Mode: string; out Code, Kind: string): boolean;
var I: integer;
begin
  Result:=True;
  if Mode='wabun' then begin
    for I:=0 to High(Kana) do if Kana[I]=Value then begin Code:=KanaCode[I]; Kind:='character'; Exit end;
    if Value='゛' then begin Code:='..'; Kind:='diacritic'; Exit end;
    if Value='゜' then begin Code:='..--.'; Kind:='diacritic'; Exit end;
    if Value='ー' then begin Code:='.--.-'; Kind:='punctuation'; Exit end;
    if Value='、' then begin Code:='.-.-.-'; Kind:='punctuation'; Exit end;
    if Value='。' then begin Code:='.-.-..'; Kind:='punctuation'; Exit end;
    if (Value='「') or (Value='（') then begin Code:='.-..-.'; Kind:='punctuation'; Exit end;
    if (Value='」') or (Value='）') then begin Code:='-.--.-'; Kind:='punctuation'; Exit end;
    if (Length(Value)=1) and (Value[1] in ['0'..'9']) then begin
      I:=Pos(Value,International)-1; Code:=InternationalCode[I]; Kind:='digit'; Exit;
    end;
  end else begin
    I:=Pos(Value,International);
    if (Length(Value)=1) and (I>0) then begin
      Code:=InternationalCode[I-1];
      if Value[1] in ['0'..'9'] then Kind:='digit'
      else if Value[1] in ['A'..'Z'] then Kind:='character'
      else Kind:='punctuation';
      Exit;
    end;
  end;
  Result:=False;
end;
function DefinedPattern(const Code, Mode: string): boolean;
var I: integer;
begin
  Result:=True;
  if Mode='international' then begin
    for I:=0 to High(InternationalCode) do if Code=InternationalCode[I] then Exit;
  end else begin
    for I:=0 to High(KanaCode) do if Code=KanaCode[I] then Exit;
    if (Code='..') or (Code='..--.') or (Code='.--.-') or (Code='.-.-.-') or
       (Code='.-.-..') or (Code='.-..-.') or (Code='-.--.-') then Exit;
    for I:=26 to 35 do if Code=InternationalCode[I] then Exit;
  end;
  if (Code='-..---') or (Code='...-.') or (Code='.-.-.') or (Code='...-.-') or
     (Code='-...-') or (Code='.-...') or (Code='........') then Exit;
  Result:=False;
end;
function Tokenize(const Source, InitialMode: string): TSendTokens;
var At,Index,N,I,SourceAt: integer; R,Canon,Mark,Mode,Code,Kind,Marker: string;
  procedure Append(const Value, ACode, AKind: string; SourceAt: integer; Space: boolean);
  var L: integer;
  begin
    L:=Length(Result); SetLength(Result,L+1);
    Result[L].Value:=Value; Result[L].Code:=ACode; Result[L].Kind:=AKind;
    Result[L].Mode:=Mode; Result[L].SourceIndex:=SourceAt; Result[L].IsSpace:=Space;
  end;
begin
  if not ValidUTF8(Source) then raise Exception.Create('Invalid UTF-8');
  if (InitialMode<>'international') and (InitialMode<>'wabun') and (InitialMode<>'mixed') then
    raise Exception.Create('Unsupported mode');
  if InitialMode='mixed' then Mode:='international' else Mode:=InitialMode;
  At:=1; Index:=0; SetLength(Result,0);
  while At<=Length(Source) do begin
    if Source[At]='{' then begin
      N:=Pos('}',Copy(Source,At,32));
      if N=0 then raise Exception.Create('Unclosed prosign');
      Marker:=Copy(Source,At,N); Inc(At,N);
      if Marker='{DO}' then begin
        if (InitialMode<>'mixed') or (Mode<>'international') then raise Exception.Create('Invalid DO mode switch');
        Append(Marker,'-..---','prosign',Index,False); Mode:='wabun';
      end else if Marker='{SN}' then begin
        if (InitialMode<>'mixed') or (Mode<>'wabun') then raise Exception.Create('Invalid SN mode switch');
        Append(Marker,'...-.','prosign',Index,False); Mode:='international';
      end else if Marker='{AR}' then Append(Marker,'.-.-.','prosign',Index,False)
      else if Marker='{SK}' then Append(Marker,'...-.-','prosign',Index,False)
      else if Marker='{BT}' then Append(Marker,'-...-','prosign',Index,False)
      else if Marker='{AS}' then Append(Marker,'.-...','prosign',Index,False)
      else if Marker='{HH}' then Append(Marker,'........','prosign',Index,False)
      else if Copy(Marker,1,5)='{RAW:' then begin
        Code:=Copy(Marker,6,Length(Marker)-6);
        if (Length(Code)<1) or (Length(Code)>8) or DefinedPattern(Code,Mode) then
          raise Exception.Create('RAW test pattern is assigned or invalid');
        for I:=1 to Length(Code) do if not (Code[I] in ['.','-']) then
          raise Exception.Create('RAW test pattern accepts dots and dashes only');
        Append(Marker,Code,'undefined',Index,False);
      end
      else raise Exception.Create('Unknown prosign: '+Marker);
      Inc(Index); Continue;
    end;
    R:=Rune(Source,At);
    if R=' ' then begin Append('','','space',Index,True); Inc(Index); Continue end;
    SourceAt:=Index;
    if (R='゙') or (R='゚') then begin
      if (Index=0) or (Length(Result)=0) or (Result[High(Result)].Kind<>'character') then
        raise Exception.Create('Combining mark needs a preceding kana');
      SourceAt:=Index-1;
    end;
    if Mode='wabun' then begin
      Canon:=CanonicalKana(R); Canon:=VoiceBase(Canon,Mark);
    end else begin Canon:=R; Mark:='' end;
    if not Lookup(Canon,Mode,Code,Kind) then
      raise Exception.Create('Unsupported '+Mode+' character at Unicode index '+IntToStr(Index));
    Append(Canon,Code,Kind,SourceAt,False);
    if Mark<>'' then begin
      if not Lookup(Mark,Mode,Code,Kind) then raise Exception.Create('Missing diacritic');
      Append(Mark,Code,Kind,SourceAt,False);
    end;
    if SourceAt=Index then Inc(Index);
  end;
  if (Length(Result)=0) or Result[0].IsSpace or Result[High(Result)].IsSpace then
    raise Exception.Create('Empty or edge space');
  for I:=1 to High(Result) do if Result[I].IsSpace and Result[I-1].IsSpace then
    raise Exception.Create('Repeated space');
end;
function SymbolTableV2: string;
var I: integer;
begin
  Result:='mode'+#9+'value'+#9+'pattern'+#9+'source'+#10;
  for I:=1 to Length(International) do
    Result:=Result+'international'+#9+International[I]+#9+InternationalCode[I-1]+#9+'ITU-R M.1677-1'+#10;
  for I:=0 to High(Kana) do
    Result:=Result+'wabun'+#9+Kana[I]+#9+KanaCode[I]+#9+'JP Radio Station Operation Regulations Annex 1'+#10;
  Result:=Result+'wabun'+#9+'゛'+#9+'..'+#9+'JP Radio Station Operation Regulations Annex 1'+#10+
    'wabun'+#9+'゜'+#9+'..--.'+#9+'JP Radio Station Operation Regulations Annex 1'+#10+
    'wabun'+#9+'ー'+#9+'.--.-'+#9+'JP Radio Station Operation Regulations Annex 1'+#10+
    'wabun'+#9+'、'+#9+'.-.-.-'+#9+'JP Radio Station Operation Regulations Annex 1'+#10+
    'wabun'+#9+'。'+#9+'.-.-..'+#9+'JP Radio Station Operation Regulations Annex 1'+#10+
    'wabun'+#9+'「'+#9+'.-..-.'+#9+'JP Radio Station Operation Regulations Annex 1'+#10+
    'wabun'+#9+'」'+#9+'-.--.-'+#9+'JP Radio Station Operation Regulations Annex 1'+#10;
  for I:=27 to 36 do
    Result:=Result+'wabun'+#9+International[I]+#9+InternationalCode[I-1]+#9+'JP Radio Station Operation Regulations Annex 1'+#10;
  Result:=Result+'mixed'+#9+'{DO}'+#9+'-..---'+#9+'HORE joined procedure'+#10+
    'mixed'+#9+'{SN}'+#9+'...-.'+#9+'RATA joined procedure'+#10+
    'either'+#9+'{AR}'+#9+'.-.-.'+#9+'ITU-R M.1677-1 procedure'+#10+
    'either'+#9+'{SK}'+#9+'...-.-'+#9+'ITU-R M.1677-1 procedure'+#10+
    'either'+#9+'{BT}'+#9+'-...-'+#9+'ITU-R M.1677-1 double hyphen'+#10+
    'either'+#9+'{AS}'+#9+'.-...'+#9+'ITU-R M.1677-1 wait'+#10+
    'either'+#9+'{HH}'+#9+'........'+#9+'ITU-R M.1677-1 error'+#10;
end;
end.
