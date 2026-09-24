program ValidateTeacherDataset;
{$mode objfpc}{$H+}
uses SysUtils, TeacherDataset, TeacherPlatform;
begin
  InitializeTeacherRuntime;
  if ArgumentCount<>1 then begin WriteLn(StdErr,'Usage: validate_dataset DATASET_DIR'); Halt(64) end;
  try ValidateDataset(Argument(1)); WriteLn('VALID')
  except on E: Exception do begin WriteLn(StdErr,E.Message); Halt(4) end end;
end.
