param(
    [string]$Fpc='C:/lazarus/fpc/3.2.2/bin/x86_64-win64/fpc.exe',
    [string]$Python='python'
)
$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & ./tools/build_teacher.ps1 -Fpc $Fpc
    foreach ($name in @('teacher_primitives','export_sample','export_teacher_fault')) {
        $source = switch ($name) {
            'teacher_primitives' { 'tests/teacher_primitives.lpr' }
            'export_sample' { 'tools/export_sample.lpr' }
            'export_teacher_fault' { 'tools/export_teacher.lpr' }
        }
        $options = @('-B','-Cr','-Co','-gl','-Futeacher','-FuVCL','-FUlib/teacher','-FElib/teacher',"-o$name.exe")
        if ($name -eq 'export_teacher_fault') { $options += '-dTEACHER_FAULT_TEST' }
        & $Fpc @options $source > "lib/teacher/$name-build.log"
        if ($LASTEXITCODE -ne 0) { Get-Content "lib/teacher/$name-build.log" -Tail 20; throw "Build failed: $name" }
    }
    & $Python tests/test_teacher.py
    if ($LASTEXITCODE -ne 0) { throw 'Teacher integration tests failed' }
    $report=Get-Content lib/teacher/last-test.json -Raw | ConvertFrom-Json
    foreach($name in @('whole','speed-17.321','migrated-56')) {
        & ./tests/test_teacher_schema.ps1 -Dataset (Join-Path $report.evidence $name)
    }
} finally { Pop-Location }
