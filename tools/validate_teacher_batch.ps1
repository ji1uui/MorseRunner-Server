param([Parameter(Mandatory)][string]$DatasetRoot,[string]$Validator='lib/teacher/validate_dataset.exe')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($DatasetRoot)
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TeacherBatchHash.ps1')
$validatorPath=[IO.Path]::GetFullPath((Join-Path $repo $Validator))
$index=Get-Content -LiteralPath (Join-Path $root 'index.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($index.schema_version -ne 'teacher-batch-1' -or $index.complete -ne $true) { throw 'Incomplete/unknown batch' }
if ((Get-FileHash -LiteralPath (Join-Path $root 'plan.json') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $index.plan_sha256) { throw 'Plan hash mismatch' }
$plan=Get-Content -LiteralPath (Join-Path $root 'plan.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($plan.schema_version -ne 'teacher-batch-1' -or $plan.items.Count -ne $index.items.Count) { throw 'Plan/index shape mismatch' }
$utf8=[Text.UTF8Encoding]::new($false)
$groups=@{}
$texts=@{}
$audio=@{}
$sessions=@{}
$cells=@{}
for($i=0;$i -lt $index.items.Count;$i++) {
    $item=$index.items[$i]
    $name=('session_{0:d6}' -f ($i+1))
    if ($item.path -cne $name) { throw "Unexpected session path: $($item.path)" }
    $manifestPath=Join-Path (Join-Path $root $name) 'manifest.json'
    $hash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $item.manifest_sha256) { throw "Manifest hash mismatch: $name" }
    & $validatorPath (Join-Path $root $name) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Dataset validation failed: $name" }
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $planned=$plan.items[$i]
    if ($planned.group_id -cne $item.group_id -or $planned.split -cne $item.split) { throw "Plan/index split mismatch: $name" }
    if ($planned.config.Count -ne $manifest.config.Count) { throw "Plan/config mismatch: $name" }
    foreach($field in $planned.config.Keys) {
        if (-not $manifest.config.ContainsKey($field) -or [string]$manifest.config[$field] -cne [string]$planned.config[$field]) {
            throw "Plan/config mismatch in ${name}: $field"
        }
    }
    $textHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes([string]$manifest.config.text))).ToLowerInvariant()
    if ($textHash -cne $item.text_sha256 -or $item.mode -cne $manifest.config.mode -or
        [double]$item.wpm -ne [double]$manifest.config.wpm -or [int]$item.pitch_hz -ne [int]$manifest.config.pitch_hz -or
        [int64]$item.sample_count -ne [int64]$manifest.session_sample_count) { throw "Index values mismatch: $name" }
    if ($manifest.session_id -cne $item.session_id -or $manifest.config_sha256 -cne $item.config_sha256) {
        throw "Index metadata mismatch: $name"
    }
    if ($sessions.ContainsKey($item.session_id)) { throw 'Duplicate session ID' }
    $sessions[$item.session_id]=$true
    $audioKey=(($manifest.files | Where-Object role -eq 'r' | ForEach-Object sha256) -join ':')
    if ($audioKey -cne $item.audio_parts_sha256) { throw "Audio index mismatch: $name" }
    $pcmHash=Get-TeacherPcmHash -SessionDir (Join-Path $root $name) -Manifest $manifest
    if ($pcmHash -cne $item.audio_pcm_sha256) { throw "PCM index mismatch: $name" }
    if ($audio.ContainsKey($pcmHash) -and $audio[$pcmHash] -cne $item.split) { throw 'Identical audio across splits' }
    $audio[$pcmHash]=$item.split
    if ($groups.ContainsKey($item.group_id) -and $groups[$item.group_id] -cne $item.split) { throw 'Group split leakage' }
    if ($texts.ContainsKey($item.text_sha256) -and $texts[$item.text_sha256] -cne $item.split) { throw 'Text split leakage' }
    $groups[$item.group_id]=$item.split; $texts[$item.text_sha256]=$item.split
    $speed=[double]$item.wpm
    $pitch=[int]$item.pitch_hz
    $sb=if($speed -lt 10){0}elseif($speed -lt 20){1}elseif($speed -lt 30){2}elseif($speed -lt 40){3}else{4}
    $pb=if($pitch -lt 500){0}elseif($pitch -lt 900){1}else{2}
    $cell="$($item.mode):$sb`:$pb"
    $tokenCount=(Get-Content -LiteralPath (Join-Path (Join-Path $root $name) 'tokens.jsonl') | Measure-Object -Line).Lines
    if ($tokenCount -ne $item.token_count) { throw "Token count index mismatch: $name" }
    if (-not $cells.ContainsKey($cell)) { $cells[$cell]=[ordered]@{sessions=0;samples=0;tokens=0} }
    $cells[$cell].sessions++
    $cells[$cell].samples+=[int64]$item.sample_count
    $cells[$cell].tokens+=[int64]$item.token_count
}
$report=[ordered]@{passed=$true;sessions=$index.items.Count;cells=$cells;groups=$groups.Count}
$report | ConvertTo-Json -Depth 10
