<#
.SYNOPSIS
  Installs the Indonesian text mod as a checked RomFS overlay for a build of this checkout (run after BUILD_ME.ps1).

.DESCRIPTION
  Reads the mod (never changes it), from -ModDir, or else from a ZIP in -ZipDir that holds zelda_totk_indonesian_*,
  extracted to build\mod-src. tools\make_romfs_mod.py then checks the extracted 1.4.3 RomFS hash, the SHA-256 of
  each original file, the decompressed sizes and conflicts with romfs-patches, and writes build\<ver>\mods\indonesian
  with its manifest.tsv. Finally totk.ini next to totk.exe gets romfs_mods pointing there (backup: totk.ini.bak).
  The mod replaces English (US) text: the game language must be en-US.

.PARAMETER Uninstall  Remove the romfs_mods line from totk.ini (the overlay folder stays in build\, delete it freely).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\INSTALL_INDONESIAN_MOD.ps1
#>
[CmdletBinding()]
param(
    [string]$ModDir = 'E:\Games\ProjectZelda\zelda_totk_indonesian_v1.0',
    [string]$ZipDir = 'E:\Games\ProjectZelda',
    [ValidateSet('v143', 'v121')][string]$Version = 'v143',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
Set-Location $Root
function Say($msg) { Write-Host "== $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

$buildDir = Join-Path $Root "build\$Version"
$ini = Join-Path $buildDir 'totk.ini'
$out = Join-Path $buildDir 'mods\indonesian'
$py14 = Join-Path $Root '.venv-py314\Scripts\python.exe'

if (-not (Test-Path (Join-Path $buildDir 'totk.exe'))) { Fail "build\$Version\totk.exe not found. Run .\BUILD_ME.ps1 first." }
if (-not (Test-Path $py14)) { Fail '.venv-py314 missing. Run .\BUILD_ME.ps1 first.' }
if (Get-Process totk -ErrorAction SilentlyContinue) { Fail 'totk.exe is running. Close the game first.' }

# Set or remove one key in totk.ini, keeping every other line; a copy goes to totk.ini.bak first.
function Set-IniKey($key, $value) {
    $lines = @()
    if (Test-Path $ini) { Copy-Item $ini "$ini.bak" -Force; $lines = @(Get-Content $ini) }
    $pat = "^\s*$key\s*="
    $kept = @($lines | Where-Object { $_ -notmatch $pat })
    if ($null -ne $value) {
        $i = [array]::IndexOf($kept, '[files]')
        if ($i -ge 0) { $kept = $kept[0..$i] + "$key = $value" + $(if ($i + 1 -lt $kept.Count) { $kept[($i + 1)..($kept.Count - 1)] } else { @() }) }
        else { $kept += @('', '[files]', "$key = $value") }
    }
    $kept | Out-File -FilePath $ini -Encoding utf8
}

if ($Uninstall) {
    Set-IniKey 'romfs_mods' $null
    Say "romfs_mods removed from $ini (backup: totk.ini.bak)"
    exit 0
}

# ---- the mod source
if (-not (Test-Path $ModDir)) {
    $zip = Get-ChildItem -Path $ZipDir -Filter *.zip -File -ErrorAction SilentlyContinue | Where-Object {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [IO.Compression.ZipFile]::OpenRead($_.FullName)
            $hit = $z.Entries | Where-Object { $_.FullName -like 'zelda_totk_indonesian*/*Mals/USen.Product.*.sarc.zs' }
            $z.Dispose()
            [bool]$hit
        } catch { $false }
    } | Select-Object -First 1
    if (-not $zip) { Fail "Mod folder $ModDir not found and no mod ZIP in $ZipDir." }
    $src = Join-Path $Root 'build\mod-src'
    Say "Extracting $($zip.Name) to $src"
    if (Test-Path $src) { Remove-Item $src -Recurse -Force }   # build\mod-src is this script's own scratch folder
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $src
    $ModDir = (Get-ChildItem $src -Directory | Select-Object -First 1).FullName
}
Say "Mod: $ModDir"
$files = @(Get-ChildItem -Path $ModDir -Recurse -File -Filter 'USen.Product.*.sarc.zs')
if (-not $files) { Fail "No Mals\USen.Product.*.sarc.zs below $ModDir." }
foreach ($f in $files) { Write-Host ("   {0}  {1}" -f (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower(), $f.Name) }

# ---- checked overlay
Say 'Building the overlay (checks 1.4.3 RomFS hash, originals, sizes, romfs-patches)'
& $py14 tools\make_romfs_mod.py --mod $ModDir --version $Version --name indonesian --map-family
if ($LASTEXITCODE -ne 0) { Fail 'make_romfs_mod.py stopped; nothing was installed. Read the message above.' }

Set-IniKey 'romfs_mods' $out
Say "totk.ini: romfs_mods = $out (backup: totk.ini.bak)"
$lang = Select-String -Path $ini -Pattern '^\s*lang\s*=\s*(\S+)' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($lang -and $lang.Matches[0].Groups[1].Value -ne 'en-US') {
    Write-Host "WARNING: totk.ini sets lang = $($lang.Matches[0].Groups[1].Value); the mod applies only with en-US." -ForegroundColor Yellow
} elseif (-not $lang) {
    Set-IniKey 'lang' 'en-US'   # unset follows the Windows locale; the mod replaces the en-US text only
    Say 'totk.ini: lang = en-US (the mod replaces the English (US) text)'
}
Write-Host "Installed. Remove with: .\INSTALL_INDONESIAN_MOD.ps1 -Uninstall" -ForegroundColor Green
