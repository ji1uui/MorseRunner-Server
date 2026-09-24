param([string]$Fpc='C:/lazarus/fpc/3.2.2/bin/x86_64-win64/fpc.exe', [string]$OutputDir='lib/teacher')
$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $commit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read source commit' }
    $dirty = if (git status --porcelain) { 'True' } else { 'False' }
    [IO.File]::WriteAllText((Join-Path (Resolve-Path $OutputDir).Path 'TeacherBuildInfo.inc'), "const SourceCommit = '$commit'; SourceDirty = $dirty;"+[char]10, [Text.UTF8Encoding]::new($false))
    foreach ($name in @('export_teacher','validate_dataset','migrate_dataset')) {
        & $Fpc -B -Cr -Co -gl -dTEACHER_BUILD_INFO -Futeacher -FuVCL "-Fi$OutputDir" "-FU$OutputDir" "-FE$OutputDir" "tools/$name.lpr" > (Join-Path $OutputDir "$name-build.log")
        if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path $OutputDir "$name-build.log") -Tail 20; throw "Build failed: $name" }
    }
    Write-Output "Built teacher tools in $OutputDir"
} finally { Pop-Location }
