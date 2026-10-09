[CmdletBinding()]
param([switch]$Test)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw '需要 Visual Studio 2022 C++ x64 Build Tools 和 Windows SDK。'
}
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw '找不到 C++ x64 Build Tools。' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $repoRoot 'src\native\audio_notify.cpp'
$buildDir = Join-Path $repoRoot '.scratch\audio-native'
$resourceDir = Join-Path $repoRoot 'src\resources\audio'
$dllPath = Join-Path $resourceDir 'AudioNotify.dll'
$importLibrary = Join-Path $buildDir 'AudioNotify.lib'
New-Item -ItemType Directory -Force -Path $buildDir, $resourceDir | Out-Null

$testCommand = ''
if ($Test) {
    $testSource = Join-Path $repoRoot 'test\native\audio_notify_stop_test.cpp'
    $testExecutable = Join-Path $buildDir 'audio_notify_stop_test.exe'
    $testLibrary = Join-Path $buildDir 'audio_notify_stop_test.lib'
    $testCommand = @"
cl /nologo /std:c++17 /EHsc /W4 /WX /O2 /MT /D_WIN32_WINNT=0x0A00 "$testSource" /link /OUT:"$testExecutable" /IMPLIB:"$testLibrary" Ole32.lib User32.lib UUID.lib
if errorlevel 1 exit /b %errorlevel%
"$testExecutable"
"@
}

$batchPath = Join-Path $buildDir 'build.cmd'
$batch = @"
@echo off
chcp 65001 >nul
call "$vcvars"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /std:c++17 /EHsc /W4 /WX /O2 /MT /D_WIN32_WINNT=0x0A00 /LD "$source" /link /OUT:"$dllPath" /IMPLIB:"$importLibrary" Ole32.lib User32.lib UUID.lib
if errorlevel 1 exit /b %errorlevel%
$testCommand
exit /b %errorlevel%
"@
[IO.File]::WriteAllText($batchPath, $batch, [Text.UTF8Encoding]::new($false))
Push-Location -LiteralPath $buildDir
try {
    & $env:ComSpec /d /c "`"$batchPath`""
    if ($LASTEXITCODE -ne 0) { throw "音频通知模块编译失败：$LASTEXITCODE" }
} finally {
    Pop-Location
}
$digest = (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $resourceDir 'AudioNotify.sha256'), $digest + "`n", [Text.Encoding]::ASCII)
Write-Output "Built x64 AudioNotify.dll (SHA-256 $digest)"
