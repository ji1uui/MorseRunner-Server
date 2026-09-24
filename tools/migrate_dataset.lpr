program MigrateTeacherDataset;
{$mode objfpc}{$H+}
uses SysUtils, TeacherDataset, TeacherPlatform;
begin
  InitializeTeacherRuntime;
  if ArgumentCount<>2 then begin WriteLn(StdErr,'Usage: migrate_dataset LEGACY_DIR NEW_OUTPUT_DIR'); Halt(64) end;
  try MigrateDataset(Argument(1),Argument(2))
  except on E: Exception do begin WriteLn(StdErr,E.Message); Halt(3) end end;
end.
