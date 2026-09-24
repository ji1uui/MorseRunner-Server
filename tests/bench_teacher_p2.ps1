param([ValidateSet('p1','p2')][string]$Profile='p2',
    [string]$Exporter='lib/teacher/export_teacher.exe',[string]$Validator='lib/teacher/validate_dataset.exe')
$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $run='lib/teacher-bench-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    New-Item -ItemType Directory -Path $run | Out-Null
    if ($Profile -eq 'p1') {
        $cfg=[ordered]@{schema_version='0.2';mode='international';timing_profile='standard_v1';
            text=('E'*15000);wpm=20;pitch_hz=700;amplitude=12000;chunk_seconds=60}
    } else {
        $cfg=[ordered]@{schema_version='0.3';mode='wabun';timing_profile='standard_v2';text=('ヘ'*15000);
            wpm=20;wpm_end=20;gap_scale_milli=1000;jitter_milli=50;seed=2718;
            pitch_hz=700;amplitude=12000;chunk_seconds=60}
    }
    $configPath=Join-Path $run 'config-input.json'
    [IO.File]::WriteAllText((Join-Path $PWD $configPath),($cfg|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    $output=Join-Path $run 'session'
    $stdout=Join-Path $run 'stdout.txt'
    $stderr=Join-Path $run 'stderr.txt'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $process=Start-Process -FilePath (Join-Path $PWD $Exporter) -ArgumentList @((Join-Path $PWD $configPath),(Join-Path $PWD $output)) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    $peak=0L
    while (-not $process.HasExited) {
        $process.Refresh()
        if ($process.WorkingSet64 -gt $peak) { $peak=$process.WorkingSet64 }
        Start-Sleep -Milliseconds 25
    }
    $process.Refresh(); $watch.Stop()
    if ($process.ExitCode -ne 0) { throw "Export failed: $(Get-Content $stderr -Raw)" }
    & (Join-Path $PWD $Validator) $output | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Independent validation failed' }
    $manifest=Get-Content (Join-Path $output 'manifest.json') -Raw | ConvertFrom-Json
    $seconds=$manifest.session_sample_count / 22050
    $report=[ordered]@{passed=$true;windows_only=$true;output=(Resolve-Path $output).Path;
        audio_seconds=$seconds;generate_seconds=$watch.Elapsed.TotalSeconds;
        generate_rtf=$watch.Elapsed.TotalSeconds/$seconds;peak_working_set_bytes=$peak;
        sample_interval_ms=25;source_symbols=15000;profile=$Profile;mode=$cfg.mode;
        jitter_milli=$(if($Profile -eq 'p1'){0}else{50});
        binary_sha256=(Get-FileHash (Join-Path $PWD $Exporter) -Algorithm SHA256).Hash.ToLowerInvariant()}
    $report | ConvertTo-Json -Depth 5 | Set-Content "lib/teacher/$Profile-benchmark.json" -Encoding utf8
    $report | ConvertTo-Json -Depth 5
} finally { Pop-Location }
