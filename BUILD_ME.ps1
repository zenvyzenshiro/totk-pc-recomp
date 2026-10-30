<#
.SYNOPSIS
  Builds totk.exe for TotK 1.4.3 from this checkout, following docs/building.md.

.DESCRIPTION
  Checks the toolchain and config.local.toml first and stops with a clear message when something is missing. Then runs
  the official steps: Python environments, hactool, extraction (skipped by extract.py when already verified), shader
  translator, lift, RomFS frame-rate patches, compile and link, shader preparation. Finally it writes a totk.ini next
  to totk.exe only when none exists (AMD compatibility preset, 2560x1440, 60 fps). Nothing outside this folder is
  written; game files, keys and saves are only read.

.PARAMETER CheckOnly      Only check the toolchain and the config.
.PARAMETER SkipShaders    Skip the shader preparation step (the game then compiles shaders while you play).
.PARAMETER Version        v143 (default) or v121.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\BUILD_ME.ps1
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$SkipShaders,
    [ValidateSet('v143', 'v121')][string]$Version = 'v143'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
Set-Location $Root
$Ucrt = 'C:\msys64\ucrt64\bin'
$Problems = New-Object System.Collections.Generic.List[string]

function Say($msg) { Write-Host "== $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "   ok   $msg" -ForegroundColor Green }
function Bad($msg, $fix) { Write-Host "   FAIL $msg" -ForegroundColor Red; $Problems.Add("$msg -> $fix") }
function Fail($msg) { Write-Host ""; Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function Run($title, [string]$exe, [string[]]$argv) {
    Say $title
    Write-Host "   > $exe $($argv -join ' ')" -ForegroundColor DarkGray
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { Fail "$title failed (exit code $LASTEXITCODE). Read the output above; docs\building.md lists the fixes." }
}

# ---- 1. dependencies
Say 'Checking the toolchain'
foreach ($t in 'clang.exe', 'ld.lld.exe', 'ninja.exe', 'gcc.exe', 'glslc.exe') {
    if (Test-Path (Join-Path $Ucrt $t)) { Ok "MSYS2 UCRT64 $t" }
    else { Bad "MSYS2 UCRT64 $t missing" 'install MSYS2 to C:\msys64 and the pacman packages in docs\building.md' }
}
foreach ($p in @(@('git', 'winget install Git.Git'), @('uv', 'install uv from astral.sh'),
                 @('dotnet', 'winget install Microsoft.DotNet.SDK.10'))) {
    if (Get-Command $p[0] -ErrorAction SilentlyContinue) { Ok $p[0] } else { Bad "$($p[0]) not on PATH" $p[1] }
}
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    $sdks = (& dotnet --list-sdks) -join "`n"
    if ($sdks -match '(?m)^10\.') { Ok '.NET SDK 10' } else { Bad '.NET SDK 10 missing' 'winget install Microsoft.DotNet.SDK.10' }
}
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $vc = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vc) { Ok 'Visual Studio C++ build tools' } else { Bad 'VS C++ workload missing' 'winget install Microsoft.VisualStudio.BuildTools with the VCTools workload' }
    if (-not (Get-Command vswhere -ErrorAction SilentlyContinue)) {
        $env:PATH = "$env:PATH;C:\Program Files (x86)\Microsoft Visual Studio\Installer"   # NativeAOT needs vswhere on PATH
    }
} else { Bad 'Visual Studio Build Tools missing' 'winget install Microsoft.VisualStudio.BuildTools --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended' }
if ($env:VULKAN_SDK -or (Get-Command vulkaninfo -ErrorAction SilentlyContinue)) { Ok 'Vulkan SDK (optional)' }
else { Write-Host '   note Vulkan SDK not found (optional: validation layers only)' -ForegroundColor Yellow }
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bash)) { Bad 'Git Bash missing' 'install Git for Windows (tools\fetch_refs.sh runs in it)' }

$drive = (Get-Item $Root).PSDrive
$freeGB = [math]::Floor($drive.Free / 1GB)
if ($freeGB -ge 60 -or (Test-Path "build\extracted\$Version\romfs\index.json")) { Ok "free space on ${drive}: $freeGB GB" }
else { Bad "only $freeGB GB free on ${drive}:" 'extraction needs about 60 GB' }

# ---- 2. config.local.toml
Say 'Checking config.local.toml'
$cfg = Join-Path $Root 'config.local.toml'
if (-not (Test-Path $cfg)) {
    Bad 'config.local.toml missing' 'copy config.example.toml to config.local.toml and set base, updates and keys'
} else {
    $text = Get-Content $cfg -Raw
    foreach ($m in [regex]::Matches($text, "(?m)^\s*(base|keys)\s*=\s*'([^']+)'")) {
        if (Test-Path -LiteralPath $m.Groups[2].Value) { Ok "$($m.Groups[1].Value) found" }
        else { Bad "$($m.Groups[1].Value) not found: $($m.Groups[2].Value)" 'fix the path in config.local.toml' }
    }
    foreach ($m in [regex]::Matches($text, "'([^']+\.nsp)'")) {
        if (Test-Path -LiteralPath $m.Groups[1].Value) { Ok "update found: $(Split-Path $m.Groups[1].Value -Leaf)" }
        else { Bad "update not found: $($m.Groups[1].Value)" 'fix updates in config.local.toml' }
    }
}
$ignored = & git -C $Root check-ignore config.local.toml 2>$null
if (-not $ignored) { Bad 'config.local.toml is not ignored by git' 'restore .gitignore' }

if ($Problems.Count) {
    Write-Host ""
    Write-Host "Fix these first:" -ForegroundColor Red
    $Problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Ok 'all checks passed'
if ($CheckOnly) { exit 0 }

$env:PATH = "$Ucrt;$env:PATH"   # the MSYS2 ninja and clang first (docs\building.md, PATH)
$py = Join-Path $Root '.venv\Scripts\python.exe'
$py14 = Join-Path $Root '.venv-py314\Scripts\python.exe'

# ---- 3. build steps (docs\building.md, "Build")
if (-not (Test-Path $py)) {
    Run 'Python 3.12 environment' 'uv' @('venv', '--python', '3.12', '.venv')
    Run 'Python 3.12 packages' 'uv' @('pip', 'install', '--python', $py, '-r', 'tools/requirements.txt')
}
if (-not (Test-Path $py14)) {
    Run 'Python 3.14 environment' 'uv' @('venv', '--python', '3.14', '.venv-py314')
    Run 'Python 3.14 packages' 'uv' @('pip', 'install', '--python', $py14, '-r', 'tools/requirements-py314.txt')
}
if (-not (Test-Path 'toolchain\hactool\hactool.exe')) { Run 'hactool' $py @('tools\build_hactool.py') }
Run 'Extract and verify the game (skipped when already verified)' $py14 @('tools\extract.py')
if (-not (Test-Path 'build\xlate\totk_xlate.exe')) { Run 'Shader translator' $py @('tools\build_xlate.py') }
Run 'Lift the modules to C' $py @('recomp\gen.py', '--exefs', "build\extracted\$Version\exefs", '--out', "generated\$Version",
                                  '--patches', "recomp\patches-$Version.txt")
Run 'RomFS frame-rate patches' $py14 @('tools\make_romfs_patches.py', '--version', $Version)
Run 'Compile and link totk.exe' $py @('tools\build_game.py', '--version', $Version)

$exe = Join-Path $Root "build\$Version\totk.exe"
if (-not (Test-Path $exe)) { Fail "build_game.py finished but $exe is missing" }

if (-not $SkipShaders) {
    if (-not (Test-Path 'tools\data\shader_list.tsv') -and -not (Test-Path 'refs\MacNativeGames')) {
        Run 'Reference checkouts (shader list)' $bash @('tools/fetch_refs.sh')
    }
    Run 'Prepare shaders' $py14 @('tools\prepare_shaders.py', "build\$Version", '--version', $Version)
}

# ---- 4. totk.ini, only when none exists
$ini = Join-Path $Root "build\$Version\totk.ini"
if (Test-Path $ini) {
    Say "Keeping your totk.ini ($ini)"
} else {
    Say "Writing $ini (AMD preset, 2560x1440, 60 fps)"
    $lines = @(
        '# Written by BUILD_ME.ps1 for Ryzen 5 7500F + RX 6700 XT. Every key: totk.ini.example. F1 changes these in game.',
        '[frame rate]', 'fps_limit = 60', '',
        '[performance]',
        '# vk_recorder = 0 and astc = cpu come from the preset; a line of their own wins over it.',
        'amd_preset = 1', '',
        '[display]', 'window_size = 2560x1440', 'output_res = 2560x1440', 'upscaler = fsr', ''
    )
    $example = Get-Content (Join-Path $Root 'totk.ini.example')
    ($lines + '' + '# ---- totk.ini.example below (all commented) ----' + $example) | Out-File -FilePath $ini -Encoding ascii
}

Write-Host ""
Write-Host "Done: $exe" -ForegroundColor Green
Write-Host "Saves: build\profile-$Version. Indonesian mod: .\INSTALL_INDONESIAN_MOD.ps1" -ForegroundColor Green
