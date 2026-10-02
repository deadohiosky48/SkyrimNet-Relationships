<#
    Builds SkyrimNetRelationships.dll, the dashboard's native host, from native\.

    Ported from SkyrimNet-Kinship's tools\build-dll.ps1, which exists because a
    raw cmake invocation has three traps, two of them PowerShell-specific:

      1. cmake is NOT on PATH. Visual Studio bundles it under
         Common7\IDE\CommonExtensions\Microsoft\CMake, and only a *Developer*
         shell puts it on PATH. This finds it via vswhere instead.
      2. %VCPKG_ROOT% is CMD syntax and expands to nothing in PowerShell, so
         the toolchain file silently resolves to a bare relative path and cmake
         reports something unrelated. PowerShell needs $env:VCPKG_ROOT.
      3. CommonLibSSE-NG must be cloned WITH SUBMODULES. Without --recursive it
         configures and then fails deep in a dependency with no obvious cause.

    Differences from Kinship's: the triplet is x64-windows-static-md (/MD, see
    native\CMakeLists.txt); CommonLibSSE-NG is pinned to the commit this DLL
    was written against; and -Deploy reads the staging folder from
    tools\local.settings.ps1 and copies the page as well as the DLL.

    -Setup fetches the prerequisites (vcpkg and CommonLibSSE-NG). Both are large
    downloads and never committed (.gitignore), so they are opt-in.

    Usage:
        pwsh -ExecutionPolicy Bypass -File "tools\build-dll.ps1" -Setup
        pwsh -ExecutionPolicy Bypass -File "tools\build-dll.ps1"
        pwsh -ExecutionPolicy Bypass -File "tools\build-dll.ps1" -Deploy
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Deploy,
    [string]$Config = 'Release',
    [string]$StagingRoot = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo 'native'
$commonLib = Join-Path $src 'extern\CommonLibSSE-NG'

# THE COMMONLIBSSE-NG COMMIT native\ WAS CHECKED AGAINST. It moves fast, and
# names change under it: RE::DebugNotification became
# RE::SendHUDMessage::ShowHUDMessage. Pinned so the first build compiles against
# the headers the code was written for; move it deliberately, and rebuild.
$commonLibRef = 'd61bca4de789428aa7d98a770b1323ddf1bb855c'

# Machine-specific paths live in local.settings.ps1 (gitignored). An explicit
# -StagingRoot wins.
$localSettings = Join-Path $PSScriptRoot 'local.settings.ps1'
$localCfg = if (Test-Path $localSettings) { & $localSettings } else { @{} }
if (-not $StagingRoot) { $StagingRoot = $localCfg.StagingRoot }

# --- locate Visual Studio's cmake ------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere not found. Install Visual Studio with the Desktop development with C++ workload."
}
$vsPath = & $vswhere -products * -latest -format value -property installationPath
if (-not $vsPath) { throw "No Visual Studio installation found." }

$cmake = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
if (-not (Test-Path $cmake)) {
    # Fall back to a standalone install if the VS component was not selected.
    $cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
    if (-not $cmake) {
        throw "cmake.exe not found in $vsPath, and none on PATH. Add the 'C++ CMake tools for Windows' component."
    }
}
Write-Host "cmake : $cmake"
Write-Host "VS    : $vsPath"

# --- prerequisites ----------------------------------------------------------
if ($Setup) {
    if (-not $env:VCPKG_ROOT) {
        $vcpkgDir = Join-Path $repo '.tools\vcpkg'
        if (-not (Test-Path (Join-Path $vcpkgDir 'vcpkg.exe'))) {
            Write-Host "`nFetching vcpkg into .tools\vcpkg ..."
            New-Item -ItemType Directory -Force -Path (Split-Path $vcpkgDir) | Out-Null
            if (-not (Test-Path $vcpkgDir)) {
                git clone --depth 1 https://github.com/microsoft/vcpkg $vcpkgDir
            }
            & (Join-Path $vcpkgDir 'bootstrap-vcpkg.bat') -disableMetrics
        }
        $env:VCPKG_ROOT = $vcpkgDir
        # Persist for future shells so this is a one-time cost.
        [Environment]::SetEnvironmentVariable('VCPKG_ROOT', $vcpkgDir, 'User')
        Write-Host "VCPKG_ROOT set to .tools\vcpkg (persisted for new shells)"
    }

    if (-not (Test-Path (Join-Path $commonLib 'CMakeLists.txt'))) {
        Write-Host "`nCloning CommonLibSSE-NG (large, with submodules)..."
        New-Item -ItemType Directory -Force -Path (Split-Path $commonLib) | Out-Null
        # --recursive is NOT optional; without it the build fails deep inside a
        # dependency rather than at configure time.
        #
        # core.longpaths TOO, or a checkout under a deep folder fails with
        # "Filename too long": CommonLib's submodules nest paths past Windows'
        # 260-character limit. Hit on the author's first WP3 build. `-c`
        # reaches the submodule clones --recursive starts; the clone's own config
        # and the second `-c` below cover the update after the pin.
        git -c core.longpaths=true clone https://github.com/alandtse/CommonLibVR.git --branch ng --recursive $commonLib
        if ($LASTEXITCODE -ne 0) { throw "git clone of CommonLibSSE-NG failed ($LASTEXITCODE)" }
        git -C $commonLib config core.longpaths true
        git -C $commonLib checkout --quiet $commonLibRef
        if ($LASTEXITCODE -ne 0) { throw "CommonLibSSE-NG has no commit $commonLibRef" }
        git -C $commonLib -c core.longpaths=true submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "CommonLibSSE-NG submodules failed ($LASTEXITCODE)" }
        Write-Host "CommonLibSSE-NG pinned at $($commonLibRef.Substring(0, 7))"
    }
}

# Prefer the repo-local copy over the environment variable.
#
# SetEnvironmentVariable(..., 'User') only affects shells started AFTERWARDS, so
# a -Setup run followed immediately by a build in a fresh process still sees the
# old environment and would demand -Setup again in a loop. The directory we
# created is the fact; the variable is only a convenience.
$localVcpkg = Join-Path $repo '.tools\vcpkg'
if (Test-Path (Join-Path $localVcpkg 'vcpkg.exe')) {
    $env:VCPKG_ROOT = $localVcpkg
}
if (-not $env:VCPKG_ROOT) {
    throw "vcpkg not found. Run this script with -Setup first."
}
if (-not (Test-Path (Join-Path $commonLib 'CMakeLists.txt'))) {
    throw "CommonLibSSE-NG missing at native\extern\CommonLibSSE-NG. Run this script with -Setup first."
}

# --- configure + build ------------------------------------------------------
$toolchain = Join-Path $env:VCPKG_ROOT 'scripts\buildsystems\vcpkg.cmake'
$build = Join-Path $src 'build'

$cmakeArgs = @(
    '-B', $build, '-S', $src,
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
    '-DVCPKG_TARGET_TRIPLET=x64-windows-static-md',
    "-DVCPKG_OVERLAY_TRIPLETS=$(Join-Path $src 'cmake')"
)

Write-Host "`n--- configure ---"
& $cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

Write-Host "`n--- build ---"
& $cmake --build $build --config $Config
if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }

$dll = Join-Path $build "$Config\SkyrimNetRelationships.dll"
if (-not (Test-Path $dll)) {
    throw "Build reported success but $Config\SkyrimNetRelationships.dll is not in native\build."
}
Write-Host "`nBuilt: native\build\$Config\SkyrimNetRelationships.dll" -ForegroundColor Green

# --- deploy -----------------------------------------------------------------
# The DLL AND the page, laid out as the archive lays them out, into this mod's
# own staging folder. A mod manager then deploys them with everything else.
# Kinship learned the hard way that a DLL dropped into a folder the manager has
# never registered sits there and never reaches Data.
if ($Deploy) {
    if (-not $StagingRoot) {
        throw "No staging folder. Set StagingRoot in tools\local.settings.ps1 (see the .example), or pass -StagingRoot."
    }
    if (-not (Test-Path $StagingRoot)) { throw "StagingRoot does not exist: $StagingRoot" }

    $plugins = Join-Path $StagingRoot 'SKSE\Plugins'
    New-Item -ItemType Directory -Force -Path $plugins | Out-Null
    Copy-Item $dll $plugins -Force

    # The page without mock\, which holds the mock host and its developer strip
    # and must never reach a player (tools\package.ps1 enforces the same).
    $page = Join-Path $StagingRoot 'MeridianUI\snrelationships'
    if (Test-Path $page) { Remove-Item $page -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $page | Out-Null
    Get-ChildItem (Join-Path $repo 'ui\relationships') |
        Where-Object { $_.Name -ne 'mock' } |
        Copy-Item -Destination $page -Recurse -Force

    Write-Host "Deployed the DLL and the page to the staging folder. Deploy in your mod manager to reach Data." -ForegroundColor Green
}
