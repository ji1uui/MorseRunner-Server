param(
    [Parameter(Mandatory)][string]$Plan,
    [Parameter(Mandatory)][string]$OutputRoot,
    [switch]$Resume,
    [string]$Exporter='lib/teacher/export_teacher.exe',
    [string]$Validator='lib/teacher/validate_dataset.exe'
)
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false)
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TeacherBatchHash.ps1')
$planPath=[IO.Path]::GetFullPath($Plan)
$root=[IO.Path]::GetFullPath($OutputRoot)
$exportPath=[IO.Path]::GetFullPath((Join-Path $repo $Exporter))
$validatePath=[IO.Path]::GetFullPath((Join-Path $repo $Validator))
if (-not [IO.File]::Exists($exportPath) -or -not [IO.File]::Exists($validatePath)) { throw 'Build Teacher tools first' }
$batch=Get-Content -LiteralPath $planPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($batch.schema_version -ne 'teacher-batch-1') { throw 'Unknown batch plan version' }
if (-not $batch.items -or $batch.items.Count -gt 5000) { throw 'Plan requires 1..5000 sessions' }
$groupSplit=@{}
$textSplit=@{}
$audioSplit=@{}
foreach($item in $batch.items) {
    if ($item.group_id -cnotmatch '^[a-z0-9_-]{1,80}$') { throw 'Invalid group_id' }
    if ($item.split -cnotin @('train','validation','test')) { throw 'Invalid split' }
    if ($null -eq $item.config -or $null -eq $item.config.text) { throw 'Missing config or text' }
    $group=[string]$item.group_id
    $split=[string]$item.split
    $textHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes([string]$item.config.text))).ToLowerInvariant()
    if ($groupSplit.ContainsKey($group) -and $groupSplit[$group] -ne $split) { throw "Group split leakage: $group" }
    if ($textSplit.ContainsKey($textHash) -and $textSplit[$textHash] -ne $split) { throw "Text split leakage: $textHash" }
    $groupSplit[$group]=$split
    $textSplit[$textHash]=$split
}
if ([IO.Directory]::Exists($root)) {
    if (-not $Resume) { throw 'Output root exists; use -Resume to inspect and continue an incomplete batch' }
    if ([IO.File]::Exists((Join-Path $root 'index.json'))) { throw 'Batch is already complete' }
} else { [IO.Directory]::CreateDirectory($root) | Out-Null }
$planHash=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
$savedPlan=Join-Path $root 'plan.json'
if ([IO.File]::Exists($savedPlan)) {
    if ((Get-FileHash -LiteralPath $savedPlan -Algorithm SHA256).Hash.ToLowerInvariant() -cne $planHash) { throw 'Plan changed during resume' }
} else { [IO.File]::Copy($planPath,$savedPlan) }
$index=[ordered]@{schema_version='teacher-batch-1';complete=$true;plan_sha256=$planHash;items=@()}
for($i=0;$i -lt $batch.items.Count;$i++) {
    $item=$batch.items[$i]
    $name=('session_{0:d6}' -f ($i+1))
    $dir=Join-Path $root $name
    $configPath=Join-Path $root ($name+'.config.json')
    $configJSON=$item.config | ConvertTo-Json -Depth 50 -Compress
    if ([IO.File]::Exists($configPath)) {
        if ([IO.File]::ReadAllText($configPath,$utf8) -cne $configJSON) { throw "Config changed during resume: $name" }
    } else { [IO.File]::WriteAllText($configPath,$configJSON,$utf8) }
    if ([IO.Directory]::Exists($dir)) {
        if (-not [IO.File]::Exists((Join-Path $dir 'manifest.json'))) { throw "Incomplete session requires inspection: $name" }
    } else {
        & $exportPath $configPath $dir
        if ($LASTEXITCODE -ne 0) { throw "Export failed: $name" }
    }
    & $validatePath $dir
    if ($LASTEXITCODE -ne 0) { throw "Validation failed: $name" }
    $manifestPath=Join-Path $dir 'manifest.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($manifest.config.Count -ne $item.config.Count) { throw "Plan/config mismatch: $name" }
    foreach($field in $item.config.Keys) {
        if (-not $manifest.config.ContainsKey($field) -or [string]$manifest.config[$field] -cne [string]$item.config[$field]) {
            throw "Plan/config mismatch in ${name}: $field"
        }
    }
    $audioKey=(($manifest.files | Where-Object role -eq 'r' | ForEach-Object sha256) -join ':')
    $pcmHash=Get-TeacherPcmHash -SessionDir $dir -Manifest $manifest
    if ($audioSplit.ContainsKey($pcmHash) -and $audioSplit[$pcmHash] -cne $item.split) { throw "Identical audio across splits: $name" }
    $audioSplit[$pcmHash]=[string]$item.split
    $index.items+=([ordered]@{
        path=$name; group_id=[string]$item.group_id; split=[string]$item.split;
        session_id=$manifest.session_id; mode=$manifest.config.mode;
        wpm=$manifest.config.wpm; wpm_end=$manifest.config.wpm_end;
        pitch_hz=$manifest.config.pitch_hz;
        sample_count=$manifest.session_sample_count;
        token_count=(Get-Content -LiteralPath (Join-Path $dir 'tokens.jsonl') | Measure-Object -Line).Lines;
        text_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes([string]$item.config.text))).ToLowerInvariant();
        audio_parts_sha256=$audioKey;
        audio_pcm_sha256=$pcmHash;
        config_sha256=$manifest.config_sha256;
        manifest_sha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    Write-Output "$($i+1)/$($batch.items.Count) $name VALID"
}
$partial=Join-Path $root 'index.json.partial'
[IO.File]::WriteAllText($partial,($index | ConvertTo-Json -Depth 50),$utf8)
[IO.File]::Move($partial,(Join-Path $root 'index.json'))
Write-Output "BATCH COMPLETE: $root"
