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
        pwsh -ExecutionPolicy Bypass -File "tools\package.ps1"
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [string]$Version,
    [string]$OutDir,
    # SkyrimNet Beta 25 plugin id: author.slug, lowercase, exactly one dot. The
    # external folder must be named this exactly. Changing it after release
    # makes players see a NEW plugin instead of an update, so it is fixed here
    # rather than derived from anything that might drift.
    [string]$PluginId = 'deadohiosky48.relationships'
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
    # FIVE since SNRom_Native, the DLL's native declarations. It ships even in a
    # package without the DLL: nothing calls it unless the DLL is present.
    $pex = Get-ChildItem (Join-Path $repo 'Scripts') -Filter 'SNRom_*.pex' -File
    if ($pex.Count -lt 5) { throw "Expected 5 SNRom_*.pex, found $($pex.Count). Run tools\build.ps1 first." }

    # NEVER A STALE BUILD. A failed compile leaves the previous build's .pex in
    # Scripts\ untouched, and this used to package them without a word: an
    # archive whose scripts are not its source. So every SNRom_*.psc in
    # src\scripts must have its .pex, written no earlier than the .psc was last
    # changed; a checkout that changes a script counts as a change. The other
    # .psc files there (Romantasy.psc, MARAS.psc and the rest) are vendored
    # headers that build.ps1 compiles against and never compiles, so they have
    # no .pex of their own.
    $stale = @()
    foreach ($psc in Get-ChildItem (Join-Path $repo 'src\scripts') -Filter 'SNRom_*.psc' -File) {
        $built = Join-Path (Join-Path $repo 'Scripts') ($psc.BaseName + '.pex')
        if (-not (Test-Path $built)) {
            $stale += "$($psc.Name): no $($psc.BaseName).pex"
        } elseif ($psc.LastWriteTimeUtc -gt (Get-Item $built).LastWriteTimeUtc) {
            $stale += "$($psc.Name): changed after $($psc.BaseName).pex was built"
        }
    }
    if ($stale) {
        throw ("Scripts\ does not match src\scripts. Run tools\build.ps1 and fix any failure first:`n  " +
               ($stale -join "`n  "))
    }
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

    # --- 3a. models (2.5): the engagement and wedding rings, built by
    # tools\rings\build_rings.py from a modder's resource (tools\rings\README.md).
    $meshes = Join-Path $repo 'meshes'
    if (Test-Path $meshes) { Copy-Item $meshes $stage -Recurse -Force }

    # --- 3b. the Beta 25 content layer, GENERATED from the tree above -------
    #
    # SkyrimNet Beta 25 stopped reading prompts\ and config\ and reads a plugin
    # library instead; older builds have never heard of the plugin library. So
    # the archive carries BOTH layouts and each build reads only the one it
    # knows - old files are "ignored, not deleted" on Beta 25, and external\ is
    # an unknown folder to Beta 24. No version detection anywhere, and a player
    # upgrades SkyrimNet whenever they like without touching this mod.
    #
    # GENERATED, NEVER HAND-MAINTAINED. Two copies of fifteen files that must
    # stay identical is a drift bug waiting to happen, and the drift would be
    # INVISIBLE: each SkyrimNet build reads exactly one of the copies, so a
    # stale duplicate misbehaves only for the half of the audience you are not
    # testing on. The repo keeps one source of truth and this builds the other.
    $snRoot  = Join-Path $stage 'SKSE\Plugins\SkyrimNet'
    $ext     = Join-Path $snRoot "external\$PluginId"
    New-Item -ItemType Directory -Force -Path $ext | Out-Null

    # prompts keep their sub-paths verbatim; only the config\ prefix is dropped
    Copy-Item (Join-Path $snRoot 'prompts') $ext -Recurse -Force
    # Knowledge packs (2.5: who plans weddings) exist only in the plugin
    # library; there is no classic layout for them to have come from.
    $knowledge = Join-Path $snRoot 'knowledge'
    if (Test-Path $knowledge) { Copy-Item $knowledge $ext -Recurse -Force }
    foreach ($kind in 'triggers', 'actions') {
        $src = Join-Path $snRoot "config\$kind"
        if (Test-Path $src) { Copy-Item $src $ext -Recurse -Force }
    }

    # Beta 25 requires filename == the in-file `name`, compared case-insensitively.
    # Only cat_romance.yaml breaks that rule (name: Romance). The NAME is left
    # alone on purpose - per-action enabled/cooldown settings key by name, so
    # renaming the action itself would silently reset every player who had tuned
    # it. Renaming only the file costs nobody anything.
    $actDir = Join-Path $ext 'actions'
    foreach ($f in (Get-ChildItem $actDir -Filter '*.yaml' -File)) {
        $nameField = (Select-String -LiteralPath $f.FullName -Pattern '^\s*name:\s*"?([^"\r\n]+)"?\s*$' |
                      Select-Object -First 1).Matches.Groups[1].Value.Trim()
        if (-not $nameField) { throw "No name: field in $($f.Name)" }
        $want = ($nameField.ToLower() -replace '[^a-z0-9_-]', '_') + '.yaml'
        if ($f.Name -ne $want) {
            Rename-Item $f.FullName -NewName $want
            Write-Host ("  renamed   {0,-26} -> {1,-22} (name: {2}, untouched)" -f $f.Name, $want, $nameField)
        }
    }

    # The manifest. Folder name must equal `id` exactly or Beta 25 rejects the
    # whole folder with a visible error, so both come from $PluginId.
    # `version` must be strict semver or Beta 25 rejects the plugin. -diag and
    # -devN builds carry a suffix, so strip to the numeric core for the manifest
    # only; the archive keeps the full label. Resolved BEFORE the manifest is
    # built, so the file is written exactly once - the first version of this
    # wrote it, read it back and rewrote it to patch the string, which is two
    # chances to get the encoding wrong and a fragile literal match besides.
    $semver = [regex]::Match($Version, '^\d+\.\d+\.\d+')
    if (-not $semver.Success) { throw "Version '$Version' has no semver core for the plugin manifest." }

    $manifest = [ordered]@{
        id                   = $PluginId
        type                 = 'bundle'
        title                = 'SkyrimNet Relationships'
        tagline              = 'Companions judge how you behaved, in their own words.'
        description          = 'Prompts, triggers and actions for SkyrimNet Relationships. Requires the Relationships mod itself.'
        author               = ($PluginId -split '\.')[0]
        tags                 = @('followers', 'romance', 'dialogue')
        nsfw                 = $false
        icon                 = 'sparkles'
        version              = $semver.Value
        min_skyrimnet_version = '0.25.0'
        mods                 = @(@{ name = 'SkyrimNet Relationships'; file = 'SNRom_Integration.esl'; required = $true })
    }
    # -Depth matters: without it PowerShell flattens the nested `mods` entry to
    # a type name string and the manifest ships silently malformed.
    #
    # WriteAllText WITH AN EXPLICIT BOM-LESS ENCODER, never Set-Content -Encoding
    # UTF8. That parameter means different things on different hosts: PowerShell
    # 7 writes no BOM, Windows PowerShell 5.1 writes one. Every archive built here
    # was clean only because the tooling happened to invoke pwsh - the usage line
    # at the top of this file said `powershell`, which IS 5.1, so the DOCUMENTED
    # way to run this script was the way that emitted a BOM. Reported against the
    # Kinship packager 2026-09-15, where it fired.
    #
    # The usage lines across tools\ now say pwsh, which narrows the exposure and
    # does not remove it: a CI runner, another machine or someone typing the old
    # command still lands on 5.1. Encoding is stated explicitly here so the
    # output does not depend on who invoked what.
    #
    # A leading U+FEFF is invisible in an editor and makes a strict JSON parser
    # reject the manifest on its first character - which in Beta 25 means the
    # whole plugin folder is refused, and the mod goes silently contentless.
    # smoke.ps1 already uses this idiom; package.ps1 was the odd one out.
    [System.IO.File]::WriteAllText(
        (Join-Path $ext 'manifest.json'),
        ($manifest | ConvertTo-Json -Depth 5),
        (New-Object System.Text.UTF8Encoding($false)))

    # PROVE IT, rather than trusting the encoder. A BOM is three bytes that no
    # editor shows and no diff highlights, and the failure it causes lands on the
    # player rather than here. Two assertions, both cheap: the file starts with
    # `{`, and it round-trips through a STRICT parser - .NET's JSON reader
    # rejects a leading U+FEFF exactly as Beta 25's would.
    $mfBytes = [System.IO.File]::ReadAllBytes((Join-Path $ext 'manifest.json'))
    if ($mfBytes[0] -ne 0x7B) {
        throw ("manifest.json does not start with '{' - first bytes " +
               (($mfBytes[0..2] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') +
               ". A BOM here makes Beta 25 reject the whole plugin folder.")
    }
    # ConvertFrom-Json, NOT System.Text.Json: that namespace ships with .NET
    # Core and does not exist on the .NET Framework that Windows PowerShell 5.1
    # runs on, so the first version of this guard threw on 5.1 - a host-dependent
    # check for a host-dependent bug, which is no check at all. The byte test
    # above is the one that actually catches a BOM and it is pure arithmetic;
    # this only confirms the document is well-formed.
    try { [System.IO.File]::ReadAllText((Join-Path $ext 'manifest.json')) | ConvertFrom-Json | Out-Null }
    catch { throw "manifest.json is not valid JSON: $_" }
    Write-Host "  verified  manifest.json is BOM-free and parses"

    # EVERY LEGACY CONTENT FILE MUST HAVE A COUNTERPART, compared by hash.
    #
    # The copies cannot drift - they are generated - so this is not guarding
    # against edits. It guards against a file the generator does not know about:
    # add a prompts\ sub-folder, a second category, a knowledge pack, and the
    # old layer would ship it while the new one silently would not. That failure
    # only shows up for players on the OTHER SkyrimNet build from the one being
    # tested, which is the worst possible place to discover it.
    $legacy = @()
    $legacy += Get-ChildItem (Join-Path $snRoot 'prompts') -Recurse -File
    if (Test-Path $knowledge) { $legacy += Get-ChildItem $knowledge -Recurse -File }
    foreach ($kind in 'triggers', 'actions') {
        $d = Join-Path $snRoot "config\$kind"
        if (Test-Path $d) { $legacy += Get-ChildItem $d -Recurse -File }
    }
    $extHashes = @{}
    foreach ($f in (Get-ChildItem $ext -Recurse -File)) {
        if ($f.Name -eq 'manifest.json') { continue }
        $extHashes[(Get-FileHash $f.FullName).Hash] = $f.Name
    }
    foreach ($f in $legacy) {
        $h = (Get-FileHash $f.FullName).Hash
        if (-not $extHashes.ContainsKey($h)) {
            throw "Beta 25 layer is missing '$($f.Name)'. The generator in package.ps1 does not cover it - every content file must exist in both layouts."
        }
    }
    if ($extHashes.Count -ne $legacy.Count) {
        throw "Layer file counts differ: legacy $($legacy.Count), Beta 25 $($extHashes.Count)."
    }
    Write-Host ("  verified  both layouts carry the same {0} content files" -f $legacy.Count)

    # 2.0 NEEDS BETA 25, so the classic layer goes, now that the check above
    # has proved the plugin library holds every file in it. Beta 25 ignores it
    # anyway; on Beta 24 it would half-work. The plugin settings manifest in
    # config\plugins stays: Beta 25 reads that one where it is.
    Remove-Item (Join-Path $snRoot 'prompts') -Recurse -Force
    if (Test-Path $knowledge) { Remove-Item $knowledge -Recurse -Force }
    foreach ($kind in 'triggers', 'actions') {
        $d = Join-Path $snRoot "config\$kind"
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    Write-Host "  dropped   the classic layout (prompts\, config\triggers, config\actions) - 2.0 needs Beta 25"

    $extCount = (Get-ChildItem $ext -Recurse -File).Count
    Write-Host ("  Beta 25   external\{0}  ({1} files)" -f $PluginId, $extCount)

    # --- 3c. the dashboard: SkyrimNetRelationships.dll and its page ---------
    # OUTSIDE SkyrimNet's content layers: the DLL goes to SKSE\Plugins and the
    # page to MeridianUI\snrelationships, which is where Meridian serves
    # mod://snrelationships/ from, and again to PrismaUI\views\snrelationships,
    # Prisma's base directory (native\src\PrismaHost.cpp). The same files in
    # both: the page never knows which host it runs under. Neither belongs in
    # external\, so both layouts above are untouched.
    #
    # Both or neither. The page does nothing without the DLL, and the DLL is
    # optional: a build machine without it still packages the rest of the mod,
    # and says so below rather than failing.
    $dll = Join-Path $repo 'native\build\Release\SkyrimNetRelationships.dll'
    if (Test-Path $dll) {
        # The .dll ONLY - never a .pdb. A debug database carries every source
        # path of the build machine and is of no use to a player.
        Copy-Item $dll (Join-Path $stage 'SKSE\Plugins')
        $page = Join-Path $stage 'MeridianUI\snrelationships'
        New-Item -ItemType Directory -Force -Path $page | Out-Null
        # WITHOUT mock\: the invented snapshots, and mock\host.js, which is the
        # mock host and its MOCK HOST strip. bridge.js loads it only when the page
        # is served over http, which no game host does - but it does not ship.
        Get-ChildItem (Join-Path $repo 'ui\relationships') |
            Where-Object { $_.Name -ne 'mock' } |
            Copy-Item -Destination $page -Recurse
        # Proven, not assumed: nothing of the mock host or its strip anywhere.
        $mockLeaks = Get-ChildItem $page -Recurse -File | Where-Object {
            $_.Directory.Name -eq 'mock' -or
            (Select-String -LiteralPath $_.FullName -Pattern 'snrom-mock-bar|__snromMock' -Quiet)
        }
        if ($mockLeaks) {
            throw "The mock host or its developer strip is staged: $($mockLeaks.Name -join ', ')"
        }
        $pageCount = (Get-ChildItem $page -Recurse -File).Count
        $prismaPage = Join-Path $stage 'PrismaUI\views\snrelationships'
        New-Item -ItemType Directory -Force -Path (Split-Path $prismaPage) | Out-Null
        Copy-Item $page $prismaPage -Recurse
        if ((Get-ChildItem $prismaPage -Recurse -File).Count -ne $pageCount) {
            throw "The Prisma copy of the page differs from the Meridian copy"
        }
        # And a third, for Magelight UI (2.1): Data\Magelight\<modId>\ is where
        # Magelight pins a mod's file reads, and MagelightHost.cpp loads
        # Magelight\snrelationships\index.html from there.
        $magelightPage = Join-Path $stage 'Magelight\snrelationships'
        New-Item -ItemType Directory -Force -Path (Split-Path $magelightPage) | Out-Null
        Copy-Item $page $magelightPage -Recurse
        if ((Get-ChildItem $magelightPage -Recurse -File).Count -ne $pageCount) {
            throw "The Magelight copy of the page differs from the Meridian copy"
        }
        $dashNote = "SkyrimNetRelationships.dll ($([math]::Round((Get-Item $dll).Length / 1KB)) KB), MeridianUI\snrelationships, PrismaUI\views\snrelationships and Magelight\snrelationships ($pageCount files each)"
    } else {
        $dashNote = 'NOT INCLUDED - no DLL built (tools\build-dll.ps1); this package has no dashboard'
        Write-Host "  Dashboard not included: native\build\Release\SkyrimNetRelationships.dll is not built." -ForegroundColor Yellow
    }
    if (Get-ChildItem $stage -Recurse -Filter '*.pdb' -File) { throw "A .pdb is staged. Never ship one." }

    # --- 4. other mods' files: NEVER SHIPPED ------------------------------
    # This archive carries only our own content. Patches to another mod's files
    # (2.4 removed the last, gates for Baka's actions on Romantasy's faction)
    # are a player's deliberate choice, made in an installer, never something
    # inherited by installing this: SkyrimNet reads action YAML from disk, so no
    # setting of ours can enable or disable another mod's file.

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
    # Its own file, not three more tabs in the one above: it describes desire,
    # not disposition, and a player who wants one should not have to take both.
    Copy-Item (Join-Path $repo 'library\arousal_bio_blocks.json') $docOut

    # --- 7. REFUSE TO SHIP A BUILD MACHINE'S DIRECTORY LAYOUT ---------------
    # Every text file about to be shipped is scanned for absolute paths. The repo
    # is kept clean of them by hand and by tools\local.settings.ps1, but this is
    # the only moment that actually matters: once an archive is published the
    # leak is permanent and public.
    $leaks = @()
    Get-ChildItem $stage -Recurse -File |
        Where-Object { $_.Extension -in '.md','.psc','.prompt','.yaml','.yml','.txt','.inc','.ps1','.json','.js','.css','.html' } |
        ForEach-Object {
            $name = $_.Name
            # TWO space-free segments are required. A real path has a drive and at
            # least two folders; a YAML description containing "USE:\n- ..." is not. The naive
            # [A-Za-z]:\\ pattern flagged eight of those escape sequences on the
            # first run and refused to package over them.
            [regex]::Matches((Get-Content $_.FullName -Raw), '[A-Za-z]:\\[A-Za-z0-9_.-]+\\[A-Za-z0-9_.-]+') |
                ForEach-Object { $_.Value } | Sort-Object -Unique |
                ForEach-Object { $leaks += "$name : $_" }
        }
    # BINARIES TOO, and the DLL above all. __FILE__ and std::source_location bake
    # absolute source paths into it; /d1trimfile: in native\CMakeLists.txt strips
    # them, but that flag is undocumented, so if a future MSVC stops honouring it
    # the build will NOT fail - it will quietly leak, the way Kinship's first two
    # releases did. Kinship's packager warns; this one refuses.
    #
    # Scanned as Latin-1 AND as UTF-16 at both byte alignments, because a DLL
    # stores wide strings too and a one-byte scan cannot see them. Either
    # separator, because CMake hands MSVC forward-slash paths.
    foreach ($bin in (Get-ChildItem $stage -Recurse -File | Where-Object { $_.Extension -in '.dll', '.exe' })) {
        $bytes = [System.IO.File]::ReadAllBytes($bin.FullName)
        $views = @(
            [System.Text.Encoding]::GetEncoding(28591).GetString($bytes),
            [System.Text.Encoding]::Unicode.GetString($bytes),
            [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
        )
        foreach ($view in $views) {
            # The lookbehind keeps URL schemes out: mod://snrelationships/ is in
            # this DLL on purpose, and "d:/" alone would read as a drive.
            [regex]::Matches($view, '(?<![A-Za-z0-9])[A-Za-z]:[\\/][ A-Za-z0-9_.\\/-]{6,150}') |
                ForEach-Object { $_.Value } | Sort-Object -Unique |
                ForEach-Object { $leaks += "$($bin.Name) : $_" }
        }
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
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $views = @([System.Text.Encoding]::GetEncoding(28591).GetString($bytes))
        # A DLL also stores UTF-16 strings, which the one-byte scan above reads as
        # letters separated by zeros and never matches. Both alignments, because
        # a wide string can start on an odd byte.
        if ($file.Extension -in '.dll', '.exe') {
            $views += [System.Text.Encoding]::Unicode.GetString($bytes)
            $views += [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
        }
        foreach ($text in $views) {
            foreach ($token in $identity) {
                if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $found += "$($file.Name) contains the build machine's identity"
                }
            }
        }
    }
    if ($found) {
        Write-Host ""
        Write-Host "  REFUSING TO PACKAGE - build machine identity in shipped files:" -ForegroundColor Red
        $found | Sort-Object -Unique | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "Identifying strings would be published. Fix them, then re-run."
    }

    # --- 8. the FOMOD (2.5; the author, 2026-10-25) -------------------------
    # OUR PLUGIN AS AN .esl OR A LIGHT-FLAGGED .esp, the player's choice. The
    # same file either way (SNRom_Bridge.OurPlugin, native/src/OurPlugin.h).
    # An .esl always loads among the masters, so installing one moves every
    # light-flagged .esp after it down a slot; on a large load order that broke
    # an existing save for a mod that does not follow its saved forms. The
    # .esp can be placed last, where it moves nothing.
    #
    # Everything staged and checked above becomes "00 Core". The plugin and
    # the content layer's manifest (which names the plugin it requires) go
    # into one folder per choice. Built from what was checked, so the checks
    # above cover every file but the installer's own XML, which is ours.
    $fomodStage = Join-Path $env:TEMP ("snrom_fomod_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $core = Join-Path $fomodStage '00 Core'
    New-Item -ItemType Directory -Force -Path $core | Out-Null
    Get-ChildItem $stage -Force | Move-Item -Destination $core
    $stagedPlugin = Join-Path $core 'SNRom_Integration.esl'
    $extRel = "SKSE\Plugins\SkyrimNet\external\$PluginId\manifest.json"
    $coreManifest = Join-Path $core $extRel
    $manifestText = [System.IO.File]::ReadAllText($coreManifest)
    foreach ($choice in @(@{ dir = '10 Plugin as ESL'; ext = 'esl' }, @{ dir = '11 Plugin as ESP'; ext = 'esp' })) {
        $dir = Join-Path $fomodStage $choice.dir
        New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $dir $extRel)) | Out-Null
        Copy-Item $stagedPlugin (Join-Path $dir "SNRom_Integration.$($choice.ext)")
        $text = $manifestText.Replace('"SNRom_Integration.esl"', "`"SNRom_Integration.$($choice.ext)`"")
        if (-not $text.Contains("SNRom_Integration.$($choice.ext)")) { throw "manifest.json names no plugin for $($choice.dir)" }
        [System.IO.File]::WriteAllText((Join-Path $dir $extRel), $text, (New-Object System.Text.UTF8Encoding($false)))
    }
    Remove-Item $stagedPlugin, $coreManifest -Force

    $fomodDir = Join-Path $fomodStage 'fomod'
    New-Item -ItemType Directory -Force -Path $fomodDir | Out-Null
    $author = ($PluginId -split '\.')[0]
    $info = @"
<?xml version="1.0" encoding="UTF-8"?>
<fomod>
  <Name>Relationships</Name>
  <Author>$author</Author>
  <Version>$Version</Version>
  <Description>Companions judge how you behaved, in their own words. For SkyrimNet.</Description>
  <Groups>
    <element>Gameplay</element>
  </Groups>
</fomod>
"@
    $eslText = @'
The plugin as an .esl. Choose this unless one of the reasons under the other option applies to you.

It is light, so it takes no regular plugin slot. Like every .esl, it loads among the master files, ahead of all .esp plugins: that is how the game treats the extension, and you cannot move it below them.

That is right for a new playthrough, and for most load orders.
'@
    $espText = @'
The same plugin, still light-flagged (it takes no regular slot either), but named .esp, so it can load wherever you place it. Place it LAST in your load order.

Choose this if either applies:
- You are adding Relationships to a playthrough you already have, and your load order has many light-flagged .esp plugins (hundreds or more, as large lists like Nolvus have).
- A save crashed on load after you installed the .esl version.

Why both are offered: an .esl loads ahead of every .esp, so installing one gives every light-flagged .esp after it a new slot. Most mods follow their saved records to the new slot; some older ones do not, and a save made before can then crash on load (Schlongs of Skyrim on Skyrim 1.5.97 did). Loaded last, the .esp moves nothing.

One difference: SeverActions recognises Relationships by the .esl name when it stands its own Intimacy & Consent layer down. With the .esp it may keep running beside ours; you can turn it off in SeverActions' settings.
'@
    $switchText = 'Do not switch between the two in a playthrough that already uses one: a save remembers the plugin by its name, and switching loses what Relationships recorded in it (its factions, the rings, the planner''s book).'
    $esc = { param($t) [System.Security.SecurityElement]::Escape($t) }
    $config = @"
<?xml version="1.0" encoding="UTF-8"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://qconsulting.ca/fo3/ModConfig5.0.xsd">
  <moduleName>Relationships</moduleName>
  <requiredInstallFiles>
    <folder source="00 Core" destination="" />
  </requiredInstallFiles>
  <installSteps order="Explicit">
    <installStep name="Plugin">
      <optionalFileGroups order="Explicit">
        <group name="Which plugin file" type="SelectExactlyOne">
          <plugins order="Explicit">
            <plugin name="SNRom_Integration.esl (most players)">
              <description>$(& $esc ($eslText.Trim() + "`n`n" + $switchText))</description>
              <files>
                <folder source="10 Plugin as ESL" destination="" />
              </files>
              <typeDescriptor>
                <type name="Recommended" />
              </typeDescriptor>
            </plugin>
            <plugin name="SNRom_Integration.esp, light-flagged (large load orders)">
              <description>$(& $esc ($espText.Trim() + "`n`n" + $switchText))</description>
              <files>
                <folder source="11 Plugin as ESP" destination="" />
              </files>
              <typeDescriptor>
                <type name="Optional" />
              </typeDescriptor>
            </plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
  </installSteps>
</config>
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $fomodDir 'info.xml'), $info, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $fomodDir 'ModuleConfig.xml'), $config, $utf8)
    foreach ($x in 'info.xml', 'ModuleConfig.xml') {
        try { [xml](Get-Content -Raw (Join-Path $fomodDir $x)) | Out-Null } catch { throw "fomod\$x is not well-formed XML: $_" }
    }
    Write-Host "  verified  FOMOD: core, the .esl and the .esp choices, XML well-formed"

    # --- 9. zip ------------------------------------------------------------
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # HYPHENS, NOT SPACES. GitHub rewrites spaces to dots in release asset names,
    # so "SkyrimNet Relationships-0.9.0.zip" was published as
    # "SkyrimNet.Relationships-0.9.0.zip" - a name neither this script nor anyone
    # reading it chose. Picking the separator here keeps the published filename
    # identical to the built one.
    #
    # "Relationships", NOT "SkyrimNet-Relationships" (2.2, the author,
    # 2026-10-07). MO2 takes a mod's default name from the archive name up to
    # the first hyphen, so players importing "SkyrimNet-Relationships-2.1.0.zip"
    # were offered "SkyrimNet" - and accepting it overwrote SkyrimNet itself.
    # The mod's name has no hyphen in it now; the only one is before the
    # version, where MO2 is meant to split.
    $zip = Join-Path $OutDir "Relationships-$Version.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $fomodStage '*') -DestinationPath $zip -CompressionLevel Optimal

    $size = [math]::Round((Get-Item $zip).Length / 1KB)
    Write-Host ""
    Write-Host "  Packaged  $zip" -ForegroundColor Green
    Write-Host "  Version   $Version"
    Write-Host "  Plugin    SNRom_Integration.esl or .esp, the player's choice in the FOMOD ($eslNote)"
    Write-Host "  Scripts   $($pex.Count) compiled"
    Write-Host "  Dashboard $dashNote"
    Write-Host "  Size      $size KB"
    Write-Host "  Paths     clean - no absolute paths in any shipped file, the DLL included"
    Write-Host "  Identity  clean - no build machine username or hostname, .pex headers and the DLL included"
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    if ($fomodStage) { Remove-Item $fomodStage -Recurse -Force -ErrorAction SilentlyContinue }
}
