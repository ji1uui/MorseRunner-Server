program EnvelopeProbe;
{$mode objfpc}{$H+}
uses SysUtils, Classes, MorseKey, SndTypes;
var K: TKeyer; F: TFileStream; A: TSingleArray; W: integer;
begin
  K := TKeyer.Create;
  try
    K.BufSize := 512;
    K.MorseMsg := K.Encode('EE 5NN TEST /?= 000 EEEEE');
    F := TFileStream.Create(ParamStr(1), fmCreate);
    try
      for W := 5 to 60 do
      begin
        K.Wpm := W;
        A := K.Envelope;
        F.WriteBuffer(A[0], Length(A)*SizeOf(single));
      end;
    finally F.Free end;
  finally K.Free end;
end.
