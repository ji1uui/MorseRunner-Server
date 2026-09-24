param(
    [string]$Fpc='C:/lazarus/fpc/3.2.2/bin/x86_64-win64/fpc.exe',
    [string]$Python='python'
)
$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & ./tools/build_teacher.ps1 -Fpc $Fpc
    & $Python tests/test_teacher_p2.py
    if ($LASTEXITCODE -ne 0) { throw 'P2 symbol/timing tests failed' }
    $run=Get-ChildItem lib -Directory -Filter 'teacher-p2-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    foreach($name in @('all-kana','all-latin','all-voiced','unknown-pattern','mixed','dynamic-a')) {
        & ./tests/test_teacher_schema.ps1 -Dataset (Join-Path $run.FullName $name)
    }
    $key=[guid]::NewGuid().ToString('N').Substring(0,12)
    $plan="lib/teacher/plan-p2-$key.json"
    $batch="lib/teacher-batch-$key"
    & $Python tools/prepare_teacher_plan.py examples/teacher/corpus-p2.json $plan
    if ($LASTEXITCODE -ne 0) { throw 'Plan creation failed' }
    & ./tools/export_teacher_batch.ps1 -Plan $plan -OutputRoot $batch | Out-Null
    & ./tools/validate_teacher_batch.ps1 -DatasetRoot $batch | Out-Null
    $index=Get-Content (Join-Path $batch 'index.json') -Raw | ConvertFrom-Json
    if ($index.items.Count -ne 30) { throw 'Expected 30 cells' }
    $counts=$index.items | Group-Object split
    if ($counts.Count -ne 3) { throw 'Example plan must exercise train/validation/test' }
    $leak=Get-Content $plan -Raw | ConvertFrom-Json -AsHashtable
    $leak.items[2].split=if($leak.items[0].split -eq 'train'){'test'}else{'train'}
    $leakPlan="lib/teacher/plan-leak-$key.json"
    [IO.File]::WriteAllText((Join-Path $PWD $leakPlan),($leak|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
    $leakRoot="lib/teacher-leak-$key"
    $rejected=$false
    try { & ./tools/export_teacher_batch.ps1 -Plan $leakPlan -OutputRoot $leakRoot | Out-Null }
    catch { $rejected=$true }
    if (-not $rejected -or (Test-Path $leakRoot)) { throw 'Cross-split group leakage was accepted' }

    $ca=[ordered]@{schema_version='0.3';mode='international';timing_profile='standard_v2';
        text='AAAAAAAAAA';wpm=20;wpm_end=20;pitch_hz=700;amplitude=12000;
        chunk_seconds=1;gap_scale_milli=1000;jitter_milli=0;seed=2718}
    $cb=[ordered]@{schema_version='0.3';mode='wabun';timing_profile='standard_v2';
        text='イイイイイイイイイイ';wpm=20;wpm_end=20;pitch_hz=700;amplitude=12000;
        chunk_seconds=60;gap_scale_milli=1000;jitter_milli=0;seed=2718}
    $samePcm=[ordered]@{schema_version='teacher-batch-1';items=@(
        [ordered]@{group_id='latin-a';split='train';config=$ca},
        [ordered]@{group_id='wabun-i';split='test';config=$cb})}
    $samePcmPlan="lib/teacher/plan-same-pcm-$key.json"
    [IO.File]::WriteAllText((Join-Path $PWD $samePcmPlan),($samePcm|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
    $samePcmRoot="lib/teacher-same-pcm-$key"
    $rejected=$false
    try { & ./tools/export_teacher_batch.ps1 -Plan $samePcmPlan -OutputRoot $samePcmRoot | Out-Null }
    catch { $rejected=$true }
    if (-not $rejected -or (Test-Path (Join-Path $samePcmRoot 'index.json'))) { throw 'Identical PCM across splits was accepted' }

    $resumeRoot="lib/teacher-resume-$key"
    New-Item -ItemType Directory -Path $resumeRoot | Out-Null
    $first=($index.items[0].path)
    $sourceCfg=Join-Path $batch ($first+'.config.json')
    Copy-Item $sourceCfg (Join-Path $resumeRoot ($first+'.config.json'))
    & ./lib/teacher/export_teacher.exe (Join-Path $resumeRoot ($first+'.config.json')) (Join-Path $resumeRoot $first) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare resumable session' }
    & ./tools/export_teacher_batch.ps1 -Plan $plan -OutputRoot $resumeRoot -Resume | Out-Null
    & ./tools/validate_teacher_batch.ps1 -DatasetRoot $resumeRoot | Out-Null
    $report=[ordered]@{passed=$true;batch=(Resolve-Path $batch).Path;sessions=30;splits=@{}}
    foreach($c in $counts) { $report.splits[$c.Name]=$c.Count }
    $report | ConvertTo-Json -Depth 5 | Set-Content lib/teacher/p2-last-test.json -Encoding utf8
    $report | ConvertTo-Json -Depth 5
} finally { Pop-Location }
