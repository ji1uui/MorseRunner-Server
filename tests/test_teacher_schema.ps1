param([Parameter(Mandatory)][string]$Dataset)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$version=(Get-Content -LiteralPath (Join-Path $Dataset 'manifest.json') -Raw | ConvertFrom-Json).schema_version
if ($version -notin @('0.2','0.3')) { throw 'Unsupported schema version' }
$schema=Get-Content (Join-Path $root "schemas/teacher/$version/dataset.schema.json") -Raw | ConvertFrom-Json -AsHashtable
$count=0
foreach($entry in @(@('manifest.json','manifest'),@('config.json','config'),@('stations.jsonl','station'),@('messages.jsonl','message'),@('symbols.jsonl','symbol'),@('tokens.jsonl','token'),@('conditions.jsonl','condition'),@('validation.json','validation'))) {
    $schema['$ref']='#/$defs/'+$entry[1]
    $definition=$schema | ConvertTo-Json -Depth 100
    $path=Join-Path $Dataset $entry[0]
    $records=if($entry[0] -like '*.jsonl'){Get-Content -LiteralPath $path}else{,@(Get-Content -LiteralPath $path -Raw)}
    foreach($row in $records) {
        if(-not (Test-Json -Json $row -Schema $definition -ErrorAction Stop)){throw "Schema failed: $path"}
        $count++
    }
}
Write-Output "PASS JSON Schema: $count objects in $Dataset"
