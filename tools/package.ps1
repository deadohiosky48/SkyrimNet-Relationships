<#
    Builds a mod-manager-installable archive.

    ARCHIVE ROOT = Data ROOT. A mod manager deploys the archive contents into the
    game Data folder, so the layout inside the zip must mirror Data exactly:
    Scripts\, SKSE\, and the .esl loose at the top.

    WHY THIS EXISTS. Scripts\*.pex are gitignored - they are build output, and the
    repository is source. That is correct for the repo and fatal for a user:
    cloning or downloading the ZIP yields a plugin with no scripts, which installs
    cleanly and does absolutely nothing. This archive is the only artifact a
    player should ever be handed.

    Usage:
        powershell -ExecutionPolicy Bypass -File "tools\package.ps1"
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [string]$Version,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

# Machine-specific paths live in local.settings.ps1 (gitignored). Only needed as
# a fallback source for the .esl, so a missing one is not fatal here.
$localSettings = Join-Path $PSScriptRoot 'local.settings.ps1'
$localCfg = if (Test-Path $localSettings) { & $localSettings } else { @{} }
if (-not $SkyrimRoot) { $SkyrimRoot = $localCfg.SkyrimRoot }
if (-not $SkyrimRoot) { $SkyrimRoot = $env:SKYRIM_ROOT }

$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repo 'dist' }
$plugDir = Join-Path $repo 'SKSE\Plugins\SkyrimNet\config\plugins\SkyrimNet Relationships'

# Version comes from the manifest, so the archive can never disagree with what
# the plugin reports to the SkyrimNet dashboard.
$manifestPath = Join-Path $plugDir 'manifest.yaml'
if (-not $Version) {
    $m = [regex]::Match((Get-Content $manifestPath -Raw), '(?m)^\s*version:\s*"([^"]+)"')
    if (-not $m.Success) { throw "Could not read version from $manifestPath" }
    $Version = $m.Groups[1].Value
}

$stage = Join-Path $env:TEMP ("snrom_pkg_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    # --- 1. the plugin -----------------------------------------------------
    # Tracked in the repo, unlike the compiled scripts: it is 333 bytes, built by
    # hand in the Creation Kit, and rebuilding it is ten minutes of clicking
    # rather than running a script. Falls back to the game folder if absent.
    $esl = Join-Path $repo 'SNRom_Integration.esl'
    if (-not (Test-Path $esl) -and $SkyrimRoot) { $esl = Join-Path $SkyrimRoot 'Data\SNRom_Integration.esl' }
    if (-not (Test-Path $esl)) {
        throw "SNRom_Integration.esl not found in the repo or in Data. See docs\BUILD_PLUGIN.md."
    }
    Copy-Item $esl $stage

    # Report the ESL flag rather than assume it. A rebuild that loses it costs a
    # load-order slot, and nobody notices until someone is at 254 plugins.
    $b = [System.IO.File]::ReadAllBytes($esl)
    $eslNote = if ([BitConverter]::ToUInt32($b, 8) -band 0x200) { 'ESL-flagged' } else { 'NOT ESL-flagged' }

    # --- 2. compiled scripts ----------------------------------------------
    $pex = Get-ChildItem (Join-Path $repo 'Scripts') -Filter 'SNRom_*.pex' -File
    if ($pex.Count -lt 4) { throw "Expected 4 SNRom_*.pex, found $($pex.Count). Run tools\build.ps1 first." }
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'Scripts') | Out-Null
    $pex | Copy-Item -Destination (Join-Path $stage 'Scripts')

    # STRIP THE BUILD MACHINE'S IDENTITY. The Papyrus compiler writes the
    # compiling account's username and the computer name into every .pex header.
    # Nothing surfaces it and no text search finds it, because .pex is binary -
    # so it shipped in the first published archives of both this mod and
    # SkyrimNet-Kinship before anyone noticed. Scrubbing the STAGED copies leaves
    # the build output alone; only what ships is rewritten.
    & (Join-Path $PSScriptRoot 'sanitize-pex.ps1') -Path (Join-Path $stage 'Scripts') -Recurse

    # --- 3. prompts, triggers, manifest -------------------------------------
    # settings.yaml is deliberately NOT here. SkyrimNet writes it from the
    # manifest on first run, so shipping ours would overwrite an upgrader's
    # tuning with our defaults. It is absent from the repo for the same reason,
    # and this asserts that rather than trusting it.
    Copy-Item (Join-Path $repo 'SKSE') $stage -Recurse -Force
    $shipped = Get-ChildItem $stage -Recurse -Filter 'settings.yaml' -File
    if ($shipped) { throw "settings.yaml is staged - it would overwrite user tuning. Remove it." }

    # --- 4. optional extras: DELIBERATELY NOT SHIPPED -----------------------
    # optional\baka-tier-gates\ holds modified copies of Baka's own action files.
    # They are not in this archive and should not be added to it.
    #
    # They are someone else's content, and installing them means overwriting that
    # mod's files - a decision a player must make deliberately rather than one
    # they inherit by installing this. Shipping them even as inert files under
    # Optional\ still puts another author's work in our archive.
    #
    # They remain in the repository, where anyone who wants them can read what
    # they change and apply it knowingly. A proper opt-in belongs in an installer
    # rather than a runtime setting: SkyrimNet reads action YAML from disk, so no
    # config toggle in this mod can enable or disable another mod's file.

    # --- 5. source, for anyone who wants to patch this ---------------------
    # ONLY OURS. src\scripts also holds SkyrimNetApi.psc and MARAS.psc, which
    # belong to those mods - shipping either would overwrite the owning mod's
    # copy through a manager conflict.
    #
    # Source\Scripts (the AE layout), NOT Scripts\Source: both are on the Papyrus
    # import path, but Scripts\Source is the one that shadows a build when a
    # stale copy of our own script sits in it.
    $srcOut = Join-Path $stage 'Source\Scripts'
    New-Item -ItemType Directory -Force -Path $srcOut | Out-Null
    Get-ChildItem (Join-Path $repo 'src\scripts') -Filter 'SNRom_*.psc' -File | Copy-Item -Destination $srcOut
    Get-ChildItem (Join-Path $repo 'src\scripts') -Filter '_labelmap.inc'  -File | Copy-Item -Destination $srcOut
    Get-ChildItem (Join-Path $repo 'src\scripts') -Filter '_statnames.inc' -File | Copy-Item -Destination $srcOut

    # --- 6. documentation --------------------------------------------------
    # README and LICENSE only. Build docs stay in the repo: this package contains
    # a built plugin, so a Creation Kit walkthrough landing in a player's Data
    # folder is instructions for work they must never do.
    $docOut = Join-Path $stage 'Docs\SkyrimNet Relationships'
    New-Item -ItemType Directory -Force -Path $docOut | Out-Null
    Copy-Item (Join-Path $repo 'README.md') $docOut
    Copy-Item (Join-Path $repo 'LICENSE')   $docOut

    # The SeverActions bio-block library ships here rather than under SKSE\ on
    # purpose. It is not a runtime file: nothing reads it, and dropping it into
    # a config directory would only invite SkyrimNet to try. It is imported by
    # hand through SeverActions' own UI, so it belongs where a player looks for
    # something to open - next to the README that explains what to do with it.
    # NOT merged into SeverActions_BioBlocks.json by us: that store lives in
    # Documents, is shared by every save, and carries their nextId and version.
    # Writing another mod's store is the thing we asked Kinship not to do to us.
    Copy-Item (Join-Path $repo 'library\relationships_bio_blocks.json') $docOut

    # --- 7. REFUSE TO SHIP A BUILD MACHINE'S DIRECTORY LAYOUT ---------------
    # Every text file about to be shipped is scanned for absolute paths. The repo
    # is kept clean of them by hand and by tools\local.settings.ps1, but this is
    # the only moment that actually matters: once an archive is published the
    # leak is permanent and public.
    $leaks = @()
    Get-ChildItem $stage -Recurse -File |
        Where-Object { $_.Extension -in '.md','.psc','.prompt','.yaml','.yml','.txt','.inc','.ps1','.json' } |
        ForEach-Object {
            $name = $_.Name
            # TWO space-free segments are required. A real path is C:\dev\Skyrim;
            # a YAML description containing "USE:\n- ..." is not. The naive
            # [A-Za-z]:\\ pattern flagged eight of those escape sequences on the
            # first run and refused to package over them.
            [regex]::Matches((Get-Content $_.FullName -Raw), '[A-Za-z]:\\[A-Za-z0-9_.-]+\\[A-Za-z0-9_.-]+') |
                ForEach-Object { $_.Value } | Sort-Object -Unique |
                ForEach-Object { $leaks += "$name : $_" }
        }
    if ($leaks) {
        Write-Host ""
        Write-Host "  REFUSING TO PACKAGE - absolute paths found in files about to ship:" -ForegroundColor Red
        $leaks | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "$($leaks.Count) absolute path(s) would be published. Fix them, then re-run."
    }

    # --- 7b. REFUSE TO SHIP THE BUILD MACHINE'S IDENTITY --------------------
    # Section 7 reads text files only, which is exactly how the first releases of
    # this mod shipped the build account's username and computer name: the Papyrus
    # compiler stamps both into every .pex header, .pex is binary, and no text
    # search can see it. sanitize-pex.ps1 above removes it; this proves it is gone,
    # and covers every other file too - the .esl, anything added later.
    #
    # The tokens are read from the ENVIRONMENT, never written down. This script is
    # published, so hardcoding the names to search for would itself be the leak,
    # and would only ever protect one machine. Derived this way it protects
    # whoever runs it.
    $identity = @($env:USERNAME, $env:COMPUTERNAME, $env:USERDOMAIN) |
        Where-Object { $_ -and $_.Length -ge 4 } | Sort-Object -Unique

    $found = @()
    foreach ($file in (Get-ChildItem $stage -Recurse -File)) {
        # Latin-1 maps every byte to exactly one char, so a byte scan and a text
        # scan are the same scan. UTF-8 would mangle high bytes and could split a
        # match; ASCII would drop them.
        # GetEncoding(28591) rather than ::Latin1 - the named property exists only
        # in PowerShell 7, and this must run under Windows PowerShell 5.1 too,
        # where it silently evaluates to null and takes the guard offline.
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString(
                    [System.IO.File]::ReadAllBytes($file.FullName))
        foreach ($token in $identity) {
            if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $found += "$($file.Name) contains the build machine's identity"
            }
        }
    }
    if ($found) {
        Write-Host ""
        Write-Host "  REFUSING TO PACKAGE - build machine identity in shipped files:" -ForegroundColor Red
        $found | Sort-Object -Unique | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "Identifying strings would be published. Fix them, then re-run."
    }

    # --- 8. zip ------------------------------------------------------------
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # HYPHENS, NOT SPACES. GitHub rewrites spaces to dots in release asset names,
    # so "SkyrimNet Relationships-0.9.0.zip" was published as
    # "SkyrimNet.Relationships-0.9.0.zip" - a name neither this script nor anyone
    # reading it chose. Picking the separator here keeps the published filename
    # identical to the built one.
    $zip = Join-Path $OutDir "SkyrimNet-Relationships-$Version.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

    $size = [math]::Round((Get-Item $zip).Length / 1KB)
    Write-Host ""
    Write-Host "  Packaged  $zip" -ForegroundColor Green
    Write-Host "  Version   $Version"
    Write-Host "  Plugin    SNRom_Integration.esl ($eslNote)"
    Write-Host "  Scripts   $($pex.Count) compiled"
    Write-Host "  Size      $size KB"
    Write-Host "  Paths     clean - no absolute paths in any shipped file"
    Write-Host "  Identity  clean - no build machine username or hostname, .pex headers included"
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
