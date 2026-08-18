<#
    Compiles the SkyrimNet-Romantasy Papyrus sources.

    Three non-obvious things this handles, all discovered the hard way:

      1. TESV_Papyrus_Flags.flg lives in Data/source/scripts (the AE layout),
         NOT Data/Scripts/Source. Pointing -f at the wrong one produces a
         misleading "Unknown user flag Hidden" for every base script.

      2. Actor.psc exists ONLY in Data/Scripts/Source (legacy layout), while
         other base scripts exist in both. Neither folder alone is sufficient.

      3. AssociationType.psc is missing from BOTH folders on a stock install.
         Actor.psc references it, so every compile fails with "unknown type
         associationtype" until the full source set is extracted from
         Data/Scripts.zip. That extraction is cached under .build/.

    Usage (Windows PowerShell 5.1 - `pwsh` is PS7 and is NOT installed here):
        powershell -ExecutionPolicy Bypass -File "tools\build.ps1"
        powershell -ExecutionPolicy Bypass -File "tools\build.ps1" -Clean
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [switch]$Clean
)


# ---- machine-specific paths -------------------------------------------------
# NOTHING in this repository may contain an absolute path from a particular
# workstation. They live in tools\local.settings.ps1, which is gitignored;
# copy local.settings.ps1.example to create it. An explicit -parameter wins.
$localSettings = Join-Path $PSScriptRoot 'local.settings.ps1'
$localCfg = if (Test-Path $localSettings) { & $localSettings } else { @{} }
if (-not $SkyrimRoot)  { $SkyrimRoot  = $localCfg.SkyrimRoot }
if (-not $SkyrimRoot)  { $SkyrimRoot  = $env:SKYRIM_ROOT }
if (-not $SkyrimRoot)  {
    Write-Host "  SkyrimRoot is not set. Copy tools\local.settings.ps1.example to tools\local.settings.ps1 and edit it, or pass -SkyrimRoot." -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$data = Join-Path $SkyrimRoot 'Data'
$compiler = Join-Path $SkyrimRoot 'Papyrus Compiler\PapyrusCompiler.exe'
$flags = Join-Path $data 'source\scripts\TESV_Papyrus_Flags.flg'

$srcDir = Join-Path $repo 'src\scripts'
$outDir = Join-Path $repo 'Scripts'
$buildDir = Join-Path $repo '.build'
$vanilla = Join-Path $buildDir 'vanilla_src\Source\Scripts'

foreach ($p in @($compiler, $flags)) {
    if (-not (Test-Path $p)) { throw "Not found: $p`nPass -SkyrimRoot if your install is elsewhere." }
}

# --- Vanilla source set (cached) -----------------------------------------
if ($Clean -and (Test-Path $buildDir)) {
    Remove-Item $buildDir -Recurse -Force
}
if (-not (Test-Path (Join-Path $vanilla 'AssociationType.psc'))) {
    $zip = Join-Path $data 'Scripts.zip'
    if (-not (Test-Path $zip)) { throw "Missing $zip - needed for AssociationType.psc and friends." }
    Write-Host 'Extracting vanilla script sources from Scripts.zip (one time)...'
    New-Item -ItemType Directory -Force -Path (Join-Path $buildDir 'vanilla_src') | Out-Null
    Expand-Archive -Path $zip -DestinationPath (Join-Path $buildDir 'vanilla_src') -Force
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ORDER IS LOad-BEARING. Data\Scripts\Source holds the SKSE-EXTENDED base
# scripts - it is the only copy of Form.psc that declares RegisterForModEvent,
# and the only copy of Actor.psc anywhere. The other two folders carry plain
# vanilla versions that SHADOW it if they come first, producing the very
# confusing "RegisterForModEvent is not a function or does not exist".
#
# The extracted Scripts.zip set therefore goes LAST: it exists only to fill
# genuine gaps (AssociationType.psc, absent from both on-disk folders), never
# to override a live SKSE definition.
#
# $srcDir MUST COME FIRST. Data\Scripts\Source accumulates copies of our own
# .psc files (BUILD_PLUGIN.md Step 0 puts them there so the Creation Kit can
# see them). If that folder is searched first, the compiler resolves
# "SNRom_Bridge" from the STALE copy there and silently compiles that instead
# of the file it was handed - producing a .pex that does not match source,
# with no error. Cost us a debugging session; do not reorder.
$imports = @(
    $srcDir                                # ours wins, always
    (Join-Path $data 'Scripts\Source')     # SKSE-extended: Form, Actor
    (Join-Path $data 'source\scripts')     # AE additions
    $vanilla                               # gap-filler only
) -join ';'

# Compile ONLY our own scripts. src\scripts also holds vendored dependency
# headers (Romantasy.psc, SkyrimNetApi.psc, MARAS.psc) so our code compiles
# against them - but emitting .pex for those would overwrite the owning mods'
# real scripts through a Vortex conflict. They are imports, never output.
$sources = Get-ChildItem -Path $srcDir -Filter 'SNRom_*.psc' -File
if (-not $sources) { throw "No SNRom_*.psc files in $srcDir" }

Write-Host "Compiling $($sources.Count) script(s) -> $outDir`n"
$failed = 0
foreach ($s in $sources) {
    $out = & $compiler $s.FullName -f="$flags" -i="$imports" -o="$outDir" 2>&1
    $line = ($out | Select-String -Pattern 'Compilation succeeded|error|Error' | Select-Object -First 1)
    if ($out -match 'Compilation succeeded') {
        Write-Host ("  OK    " + $s.Name)
    } else {
        $failed++
        Write-Host ("  FAIL  " + $s.Name) -ForegroundColor Red
        $out | Where-Object { $_ -match '\.psc\(' } | Select-Object -First 5 | ForEach-Object {
            Write-Host ("        " + $_) -ForegroundColor DarkYellow
        }
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "$failed script(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All scripts compiled." -ForegroundColor Green
