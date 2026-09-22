param([string]$Fpc = 'C:/lazarus/fpc/3.2.2/bin/x86_64-win64/fpc.exe')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$run = Join-Path $repo ('lib/test-export-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
function Assert($condition, $message) { if (-not $condition) { throw $message } }

# Compare complete float envelopes against the unmodified, pinned upstream keyer.
$base = Join-Path $run 'baseline'
$current = Join-Path $run 'current'
New-Item -ItemType Directory -Path $base,$current | Out-Null
$original = & git show c55dbfb286031066f69add0a43d2c6df320e6788:VCL/MorseKey.pas
Assert ($LASTEXITCODE -eq 0) 'Cannot read baseline keyer'
[IO.File]::WriteAllLines((Join-Path $base 'MorseKey.pas'), $original)
Copy-Item VCL/MorseTbl.pas,VCL/SndTypes.pas $base
Copy-Item tests/envelope_probe.lpr $base
& $Fpc -B "-Fu$base" "-FU$base" "-FE$base" "$base/envelope_probe.lpr" > "$run/baseline-build.log"
Assert ($LASTEXITCODE -eq 0) 'Baseline probe build failed'
& "$base/envelope_probe.exe" "$run/baseline.bin"
Assert ($LASTEXITCODE -eq 0) 'Baseline probe failed'
& $Fpc -B -FuVCL "-FU$current" "-FE$current" tests/envelope_probe.lpr > "$run/current-build.log"
Assert ($LASTEXITCODE -eq 0) 'Current probe build failed'
& "$current/envelope_probe.exe" "$run/current.bin"
Assert ($LASTEXITCODE -eq 0) 'Current probe failed'
Assert ((Get-FileHash "$run/baseline.bin").Hash -eq (Get-FileHash "$run/current.bin").Hash) 'Audio changed from upstream'

& $Fpc -B -Cr -Co -FuVCL "-FU$current" "-FE$current" tools/export_sample.lpr > "$run/export-build.log"
Assert ($LASTEXITCODE -eq 0) 'Exporter build failed'
$exe = "$current/export_sample.exe"
foreach ($speed in @(5,10,20,30,40,60)) {
  $out = Join-Path $run "speed-$speed"
  & $exe $out 'EE T EEEEE 5NN /?=' $speed 700
  Assert ($LASTEXITCODE -eq 0) 'Export failed'
  $m = Get-Content "$out/manifest.json" -Raw | ConvertFrom-Json
  $msg = Get-Content "$out/message.json" -Raw | ConvertFrom-Json
  $events = @(Get-Content "$out/symbols.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
  $wav = [IO.File]::ReadAllBytes("$out/received.wav")
  Assert ($m.complete -and $m.observer_audio_equal) 'Incomplete or changed audio'
  Assert ([Text.Encoding]::ASCII.GetString($wav,0,4) -eq 'RIFF') 'Not RIFF'
  Assert ([BitConverter]::ToInt32($wav,24) -eq $m.sample_rate_hz) 'Wrong WAV sample rate'
  Assert (($wav.Length - 44) -eq (2 * $m.sample_count)) 'WAV length mismatch'
  $expectedMarks = ($msg.encoded_morse -replace '[^.-]','')
  $actualMarks = ''
  $end = 0L
  foreach ($e in $events) {
    Assert ($e.start_sample -eq $end) 'Gap or overlap in event coverage'
    Assert ($e.end_sample -gt $e.start_sample -and $e.end_sample -le $m.sample_count) 'Invalid event extent'
    $end = $e.end_sample
    if ($e.kind -in @('dit','dah')) {
      $units = 1
      if ($e.kind -eq 'dah') { $units = 3; $actualMarks += '-' } else { $actualMarks += '.' }
      Assert (($e.end_sample-$e.start_sample) -eq ($units*$m.samples_per_dit)) 'Wrong mark duration'
      # A midpoint beyond the attack must have tone energy near it.
      $mid = [int](($e.start_sample+$e.end_sample)/2)
      $peak = 0
      for ($j=$mid; $j -lt [Math]::Min($mid+32,$e.end_sample); $j++) {
        $peak = [Math]::Max($peak,[Math]::Abs([int][BitConverter]::ToInt16($wav,44+2*$j)))
      }
      Assert ($peak -gt 1000) 'Mark does not align with waveform'
    }
  }
  Assert ($actualMarks -ceq $expectedMarks) 'Repeated elements lost or extra elements emitted'
  Assert ($events[1].kind -eq 'character_gap') 'EE boundary mislabeled'
  Assert ($events[3].kind -eq 'word_gap') 'Word boundary mislabeled'
}
$first = "$run/speed-20"
$before = (Get-FileHash "$first/received.wav").Hash
& $exe $first E 20 700 2>$null
Assert ($LASTEXITCODE -ne 0) 'Overwrite was allowed'
Assert ((Get-FileHash "$first/received.wav").Hash -eq $before) 'Existing audio changed'
& $exe "$run/invalid" 'a' 20 700 2>$null
Assert ($LASTEXITCODE -ne 0 -and -not (Test-Path "$run/invalid")) 'Invalid text accepted'
& $exe "$run/repeat" 'EE T EEEEE 5NN /?=' 20 700
Assert ($LASTEXITCODE -eq 0) 'Repeat export failed'
Assert ((Get-FileHash "$run/repeat/received.wav").Hash -eq $before) 'Export is not deterministic'
# Boundary inputs, including the largest accepted message at the slowest speed.
& $exe "$run/max-length" ('0' * 256) 5 200
Assert ($LASTEXITCODE -eq 0) 'Maximum text length failed'
& $exe "$run/fast-high" 'E' 60 1200
Assert ($LASTEXITCODE -eq 0) 'Highest speed/pitch failed'
foreach ($argsCase in @(@('bad-speed', 'E', '0', '700'), @('bad-pitch', 'E', '20', '1201'), @('bad-length', ('E' * 257), '20', '700'))) {
  & $exe (Join-Path $run $argsCase[0]) $argsCase[1] $argsCase[2] $argsCase[3] 2>$null
  Assert ($LASTEXITCODE -ne 0) 'Invalid boundary input accepted'
}
# Both independent processes target one new directory; exactly one may own it.
$processes = @()
try {
  foreach ($i in 1..2) {
    $info = [Diagnostics.ProcessStartInfo]::new($exe)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    foreach ($arg in @("$run/concurrent", ('0' * 256), '5', '700')) { $info.ArgumentList.Add($arg) }
    $processes += [Diagnostics.Process]::Start($info)
  }
  foreach ($p in $processes) { $p.WaitForExit() }
  Assert (@($processes | Where-Object ExitCode -eq 0).Count -eq 1) 'Concurrent output not exclusive'
  $concurrent = Get-Content "$run/concurrent/manifest.json" -Raw | ConvertFrom-Json
  Assert ($concurrent.complete) 'Winning concurrent export incomplete'
} finally { foreach ($p in $processes) { $p.Dispose() } }
Write-Output 'PASS: upstream audio identity (5..60 WPM), observer identity, six-speed WAV/event validation, repetition, invalid input, overwrite protection, determinism.'
Write-Output "Evidence: $run"
