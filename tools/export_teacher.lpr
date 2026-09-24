program ExportTeacher;
{$mode objfpc}{$H+}
uses SysUtils, fpjson, TeacherContract, TeacherDataset, TeacherPlatform;
var J: TJSONObject; C: TTeacherConfig;
begin
  InitializeTeacherRuntime;
  if ArgumentCount<>2 then begin WriteLn(StdErr,'Usage: export_teacher CONFIG.json NEW_OUTPUT_DIR'); Halt(64) end;
  J:=nil;
  try
    try J:=ReadObject(Argument(1)); C:=LoadConfig(J)
    finally J.Free end;
  except on E: Exception do begin WriteLn(StdErr,E.Message); ExitCode:=2 end end;
  if ExitCode=0 then
    try GenerateDataset(Argument(2),C)
    except on E: Exception do begin WriteLn(StdErr,E.Message); ExitCode:=3 end end;
end.
