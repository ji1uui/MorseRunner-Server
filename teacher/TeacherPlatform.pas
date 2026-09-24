unit TeacherPlatform;
{$mode objfpc}{$H+}
interface
procedure InitializeTeacherRuntime;
function Argument(Index: integer): string;
function ArgumentCount: integer;
function ExecutablePath: string;
implementation
uses SysUtils {$IFDEF WINDOWS}, Windows, ShellApi {$ENDIF};
var Args: array of string;
function ExecutablePath: string;
{$IFDEF WINDOWS}
var B: array[0..32767] of WideChar; N: DWORD;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  N:=GetModuleFileNameW(0,@B[0],Length(B));
  if (N=0) or (N>=Length(B)) then raise Exception.Create('Cannot locate executable');
  Result:=UTF8Encode(UnicodeString(PWideChar(@B[0])));
  {$ELSE}
  Result:=ExpandFileName(ParamStr(0));
  {$ENDIF}
end;
procedure InitializeTeacherRuntime;
{$IFDEF WINDOWS}
type TArgs = array[0..65535] of PWideChar; PArgs = ^TArgs;
var P: PLPWSTR; Count,I: integer;
{$ELSE}
var I: integer;
{$ENDIF}
begin
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteFileSystemCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  SetTextCodePage(Output,CP_UTF8); SetTextCodePage(StdErr,CP_UTF8);
  {$IFDEF WINDOWS}
  P:=CommandLineToArgvW(GetCommandLineW,@Count);
  if P=nil then raise Exception.Create('Cannot read Unicode arguments');
  try
    if (Count<1) or (Count>65536) then raise Exception.Create('Invalid argument count');
    SetLength(Args,Count);
    for I:=0 to Count-1 do Args[I]:=UTF8Encode(UnicodeString(PArgs(P)^[I]));
  finally LocalFree(HLOCAL(P)) end;
  {$ELSE}
  SetLength(Args,ParamCount+1);
  for I:=0 to ParamCount do Args[I]:=ParamStr(I);
  {$ENDIF}
end;
function Argument(Index: integer): string;
begin
  if (Index<0) or (Index>=Length(Args)) then raise Exception.Create('Argument index out of range');
  Result:=Args[Index];
end;
function ArgumentCount: integer;
begin Result:=Length(Args)-1 end;
end.
