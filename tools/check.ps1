<#
    Pre-deploy invariant checks for SkyrimNet-Romantasy.

    WHY THIS EXISTS. Nearly every bug this project has shipped was two places
    that must agree, disagreeing - and every one of them was greppable:

      | Bug                    | The disagreement                              |
      |------------------------|-----------------------------------------------|
      | Six inert gates        | key read with a default, written by NOTHING   |
      | Assessors never ran    | sweep used IsFollowing, candidates used the   |
      |                        | bare vanilla IsPlayerTeammate                 |
      | Config keys unreachable| manifest declared them, settings.yaml did not |
      | llmVariant fold        | Papyrus literal vs case-sensitive YAML lookup |
      | Empty messages array   | top-level prompt missing [ system ]/[ user ]  |
      | Decorator cache poison | mod decorator named in eligibilityRules       |

    None needed the game running to catch. All of them cost a debugging session.

    Run before every deploy:
        powershell -ExecutionPolicy Bypass -File "tools\check.ps1"

    NOT `pwsh` - that is PowerShell 7 and is not installed here. This box has
    Windows PowerShell 5.1, which every script in tools\ is written against.
    Exit code 0 = clean, 1 = at least one FAIL.

    FAIL  = a known-shape bug. Fix before deploying.
    WARN  = suspicious, may be deliberate. Read it, then allowlist if fine.
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [string]$StagingRoot = ''
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
if (-not $StagingRoot) { $StagingRoot = $localCfg.StagingRoot }
if (-not $StagingRoot) { $StagingRoot = $env:SKYRIM_STAGING }

$ErrorActionPreference = 'Stop'
$repo    = Split-Path -Parent $PSScriptRoot
$src     = Join-Path $repo 'src\scripts'
$prompts = Join-Path $repo 'SKSE\Plugins\SkyrimNet\prompts'
$cfg     = Join-Path $repo 'SKSE\Plugins\SkyrimNet\config'
$data    = Join-Path $SkyrimRoot 'Data'

$script:fails = 0
$script:warns = 0
function Fail($check, $msg) { Write-Host ("  FAIL  [{0}] {1}" -f $check, $msg) -ForegroundColor Red;    $script:fails++ }
function Warn($check, $msg) { Write-Host ("  WARN  [{0}] {1}" -f $check, $msg) -ForegroundColor Yellow; $script:warns++ }
function Ok($check, $msg)   { Write-Host ("  ok    [{0}] {1}" -f $check, $msg) -ForegroundColor DarkGray }
function Section($name)     { Write-Host "`n$name" -ForegroundColor Cyan }

# Keys deliberately written-but-never-read, or read-but-never-written, with the
# reason. Anything NOT here that is one-sided is a real finding.
$storageAllow = @{
    'SNRom_AutoEnrolled'  = 'write-only audit record; gates nothing (documented)'
    'SNRom_SeedRapportAt' = 'write-only forward hook: the rapport a seed CONSUMED, so an eventual SeverActions rapport bridge measures deltas from here instead of paying it out twice'
    # Deliberately read-only since 2026-08-04. WHY now lives in JsonUtil
    # (file-backed, survives a reload); StorageUtil STRINGS do not. This read is
    # the legacy fallback so NPCs authored before the move keep rendering for
    # the rest of the current session. Nothing writes it any more and nothing
    # should - if this ever needs writing again, the reload bug is back.
    'SNRom_DispositionWhy' = 'legacy read-only fallback; WHY is written to JsonUtil now because StorageUtil strings do not survive a reload'
    'SNRom_EnrolledAt'    = 'timestamp; read by the spark tenure gate'
    'SNRom_SparkedAt'     = 'write-only timestamp, kept for the record'
    'SNRom_EndedAt'       = 'write-only timestamp, kept for the record'
    # FOREIGN key - owned by SeverActions, so of course nothing here writes it.
    # This check cannot verify it: if Sever renames the key, the read keeps
    # compiling and silently returns 0, and IsFollowing quietly loses its third
    # signal without losing the other two. Re-grep SeverActions' scripts for the
    # literal after any SA upgrade - static analysis here will not catch it.
}

# Foreign StorageUtil keys we read but do not write. EVERY entry needs a proven
# WRITER in the owning mod's shipped artifacts, named here.
#
# This list exists because of a bug that cost a live save. SeverFollower_Rapport
# and SeverFollower_IsFollower were read on the strength of SeverActions'
# SOURCE, which declares AutoReadOnly constants for them, unsets them on
# dismissal, and carries a header comment documenting the whole SeverFollower_*
# family as a live API. Nothing writes any of them - not one of SA's 38 Papyrus
# scripts, and the strings are absent from both native DLLs in every encoding.
# SA moved to a native API and left the constants behind as cleanup for stale
# values. Both reads silently returned their defaults, so tier seeding computed
# every follower's rapport as 0.0 and stamped the result once-per-NPC-ever.
#
# A DECLARATION IS NOT A WRITER. Find the write, or do not depend on the key.
#
# SNKin_Bound clears that bar. SkyrimNet-Kinship writes it on the CHILD actor,
# verified in its published source (src/scripts/SNKin_Bridge.psc):
#
#     StorageUtil.SetIntValue(akChild, "SNKin_Bound", 1)
#
# It is the flag Kinship binds a child to its roster with, and StorageUtil is a
# shared namespace, so reading it needs no compile-time dependency. Absent
# Kinship the key never exists, the read returns 0, and the child guard is
# inert - which is the intended soft-dependency behavior, not a silent failure.
#
# WHAT THIS CHECK STILL CANNOT SEE: if Kinship renames or stops writing the key,
# the read keeps compiling and silently returns 0, and the guard quietly stops
# guarding. Re-verify against Kinship's source on any of its releases.
$foreignReads = @{
    'SNKin_Bound' = @{
        Owner  = 'SkyrimNet-Kinship'
        Source = $localCfg.KinshipSource
        Const  = 'SNKin_Bound'
    }
    # PROMOTED from $storageAllow once Kinship 1.1.0 landed and the writer was
    # on disk. This is the correct answer to "is this the player's child": it is
    # written on every path that establishes child identity, INCLUDING the ones
    # where BindChildRef refuses to bind because two children share a spawned
    # actor. SNKin_Bound is never written on that path, so a guard reading it
    # alone fails OPEN on a real child - which is what shipped first.
    'SNKin_IsPlayerChild' = @{
        Owner  = 'SkyrimNet-Kinship'
        Source = $localCfg.KinshipSource
        Const  = 'SNKin_IsPlayerChild'
    }
}


$ourScripts = Get-ChildItem $src -Filter 'SNRom_*.psc' -File
# CODE ONLY - comments and docstrings stripped.
#
# Every regex below scans this. Without the strip they also match example code
# quoted inside a comment, which this codebase does constantly: the comments
# explain bugs by showing the call that caused them. Adding the note "this used
# to read StorageUtil.GetIntValue(akActor, "SeverFollower_IsFollower", 0)" made
# the storage check report a live read of a key nothing calls any more.
#
# A check that cries wolf is worse than no check - the same lesson that killed
# the fixed-line-window version of the follower assertion.
function Remove-PapyrusComments([string]$text) {
    # Docstrings: { ... }, may span lines. Anchored to a { that OPENS a line,
    # because this codebase also builds JSON inside Papyrus string literals -
    # an unanchored (?s)\{.*?\} eats from that brace to the next } and silently
    # deletes real code, which would make the promptvar check under-count
    # instead of failing loudly.
    $text = [regex]::Replace($text, '(?sm)^\s*\{.*?\}', ' ')
    # Block comments: ;/ ... /;
    $text = [regex]::Replace($text, '(?s);/.*?/;', ' ')
    # Line comments: strip from the first ; that is NOT inside a string literal.
    ($text -split "`n" | ForEach-Object {
        $line = $_; $inStr = $false; $cut = -1
        for ($i = 0; $i -lt $line.Length; $i++) {
            $c = $line[$i]
            if ($c -eq '"') { $inStr = -not $inStr }
            elseif ($c -eq ';' -and -not $inStr) { $cut = $i; break }
        }
        if ($cut -ge 0) { $line.Substring(0, $cut) } else { $line }
    }) -join "`n"
}
$allSrcRaw = ($ourScripts | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
$allSrc    = Remove-PapyrusComments $allSrcRaw

# ---------------------------------------------------------------------------
Section 'StorageUtil keys - read with a default but written by nothing'
# The audit that found six decorative gates in one pass. A key only ever read
# is a gate that silently always takes the default branch.
# ---------------------------------------------------------------------------
$reads  = [regex]::Matches($allSrc, 'StorageUtil\.Get(?:Int|Float|String|Form)Value\s*\([^,]+,\s*"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$writes = [regex]::Matches($allSrc, 'StorageUtil\.(?:Set|Unset)(?:Int|Float|String|Form)Value\s*\([^,]+,\s*"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

foreach ($k in $reads) {
    if ($writes -notcontains $k) {
        if ($foreignReads.ContainsKey($k)) {
            # Look for an actual WRITE, not for the string.
            #
            # Searching artifacts for the key text is what a first draft of this
            # did, and it would have PASSED the very bug it was written for:
            # SeverActions' .pex contains "SeverFollower_Rapport" twice - once
            # for the AutoReadOnly constant and once for the Unset - while
            # nothing sets it. Presence of the name proves the name exists, not
            # that anyone writes it.
            #
            # So this requires the owner's SOURCE and greps for a Set*Value on
            # the key. When the source is not available it reports WARN, never
            # ok: an unverifiable dependency should read as unverified.
            $owner = $foreignReads[$k]
            if ([string]::IsNullOrWhiteSpace($owner.Source) -or -not (Test-Path $owner.Source)) {
                Warn 'storage' "$k read-only from $($owner.Owner) - CANNOT VERIFY, source not at $($owner.Source). Re-check by hand that something still writes it."
            }
            else {
                $wrote = Get-ChildItem $owner.Source -Filter *.psc -Recurse -ErrorAction SilentlyContinue |
                    # (?<!Un) is load-bearing: "UnsetFloatValue" CONTAINS
                    # "SetFloatValue", so without it this matches the very
                    # cleanup-only Unset that defines the bug, and reports the
                    # unset line as proof of a writer. Caught by negative test.
                    Select-String -Pattern ("(?<!Un)Set(Float|Int|String|Form)Value\s*\([^)]*(" + [regex]::Escape($k) + "|" + [regex]::Escape($owner.Const) + ")")
                if ($wrote) { Ok 'storage' "$k read-only - $($owner.Owner) writes it at $($wrote[0].Filename):$($wrote[0].LineNumber)" }
                else { Fail 'storage' "$k is READ but $($owner.Owner) NEVER WRITES IT - only declares/unsets it. The read silently returns its default. Find the replacement API." }
            }
        }
        elseif ($storageAllow.ContainsKey($k)) { Ok 'storage' "$k read-only - allowed: $($storageAllow[$k])" }
        elseif ($k -match '^(Sever|OCR_|MARAS|FertilityMode|OStim|SNKin_)') {
            Fail 'storage' "$k looks like ANOTHER MOD's key but is not in `$foreignReads - add it with a proven writer, or use that mod's API instead"
        }
        else { Fail 'storage' "$k is READ but never written - the gate always takes its default" }
    }
}
foreach ($k in $writes) {
    if ($reads -notcontains $k -and -not $storageAllow.ContainsKey($k)) {
        Warn 'storage' "$k is WRITTEN but never read - dead state, or a reader was lost"
    }
}
Ok 'storage' "$($reads.Count) keys read, $($writes.Count) written"

# ---------------------------------------------------------------------------
Section 'Config keys - reachable from manifest AND settings.yaml'
# GetConfig* for a key absent from settings.yaml falls back to the manifest
# default; absent from BOTH and the caller silently takes a value nobody chose.
# settings.yaml is generated ONCE and never regenerated when the manifest gains
# keys, which is how six assessor knobs became untunable.
# ---------------------------------------------------------------------------
$cfgReads = [regex]::Matches($allSrc, 'GetConfig(?:Int|Bool|Float|String)\s*\([^,]+,\s*"([^"]+)"') |
              ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$manifest = Join-Path $cfg 'plugins\SkyrimNet Relationships\manifest.yaml'
$settings = Join-Path $data 'SKSE\Plugins\SkyrimNet\config\plugins\SkyrimNet Relationships\settings.yaml'

$manifestKeys = @()
if (Test-Path $manifest) {
    $manifestKeys = Select-String -Path $manifest -Pattern '^\s*path:\s*"([^"]+)"' |
                      ForEach-Object { $_.Matches[0].Groups[1].Value }
} else { Fail 'config' "manifest.yaml not found at $manifest" }

$settingsKeys = @()
if (Test-Path $settings) {
    $settingsKeys = (Get-Content $settings) |
                      Where-Object { $_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:' } |
                      ForEach-Object { ($_ -split ':')[0].Trim() }
} else { Warn 'config' "settings.yaml not found (generated at first run): $settings" }

foreach ($k in $cfgReads) {
    if ($manifestKeys -notcontains $k) { Fail 'config' "$k read in Papyrus but NOT declared in manifest.yaml" }
    elseif ($settingsKeys.Count -and $settingsKeys -notcontains $k) {
        Fail 'config' "$k declared in manifest but MISSING from settings.yaml - not tunable; settings.yaml never regenerates"
    }
}
foreach ($k in $manifestKeys) {
    if ($cfgReads -notcontains $k) { Warn 'config' "$k advertised in manifest but never read - a setting that does nothing" }
}
Ok 'config' "$($cfgReads.Count) keys read, $($manifestKeys.Count) declared, $($settingsKeys.Count) in settings.yaml"

# ---------------------------------------------------------------------------
Section 'Follower detection - one question, asked one way'
# 2026-08-01: SweepFollowers used the permissive IsFollowing() while
# TalkCandidate/SparkCandidate used the bare vanilla flag. SeverActions
# companions do not reliably set it, so they were ENROLLED and then never
# assessed - silently, forever. IsFollowing's own docstring warned about this.
# ---------------------------------------------------------------------------
# Track the ENCLOSING FUNCTION by walking the file, rather than peeking a fixed
# number of lines back. A fixed window breaks the moment someone adds a comment
# block above the call - which happened immediately - and a check that cries wolf
# is worse than no check.
$insideIsFollowing = $false
foreach ($f in $ourScripts) {
    $fn = '<file scope>'
    $n = 0
    foreach ($line in (Get-Content $f.FullName)) {
        $n++
        if ($line -match '^\s*(?:\w+(?:\[\])?\s+)?Function\s+(\w+)') { $fn = $Matches[1] }
        elseif ($line -match '^\s*(?:\w+(?:\[\])?\s+)?Event\s+(\w+)')  { $fn = $Matches[1] }
        elseif ($line -match '^\s*End(?:Function|Event)\b')            { $fn = '<file scope>' }

        if ($line -match '\w+\.IsPlayerTeammate\s*\(\s*\)' -and $line -notmatch '^\s*;') {
            if ($fn -eq 'IsFollowing') {
                $insideIsFollowing = $true
                Ok 'follower' "$($f.Name):$n inside IsFollowing - correct"
            } else {
                Fail 'follower' "$($f.Name):$n bare IsPlayerTeammate() in $fn - SeverActions companions set CurrentFollowerFaction but NOT the vanilla flag, so they get enrolled and then never assessed. Use IsFollowing()."
            }
        }
    }
}
if (-not $insideIsFollowing) { Warn 'follower' 'IsFollowing() no longer tests IsPlayerTeammate - intended?' }

# ---------------------------------------------------------------------------
Section 'Decorators - never in eligibilityRules'
# SkyrimNet caches action eligibility ~13s BEFORE OnInit can RegisterDecorator.
# A mod decorator there resolves "not found", caches false, and the action is
# permanently ineligible with nothing logged. actions?api=reload will not clear it.
# ---------------------------------------------------------------------------
$decorators = [regex]::Matches($allSrc, 'RegisterDecorator\s*\(\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$actionYaml = @(Get-ChildItem (Join-Path $cfg 'actions') -Filter *.yaml -File -ErrorAction SilentlyContinue)
foreach ($y in $actionYaml) {
    $text = Get-Content $y.FullName -Raw
    if ($text -match '(?ms)eligibilityRules:(.*?)(\r?\n\w|\z)') {
        $rules = $Matches[1]
        foreach ($d in $decorators) {
            if ($rules -match [regex]::Escape($d)) {
                Fail 'decorator' "$($y.Name): eligibilityRules references mod decorator '$d' - cached false at startup, permanently ineligible"
            }
        }
    }
}
Ok 'decorator' "$($decorators.Count) registered, $($actionYaml.Count) action files scanned"

# ---------------------------------------------------------------------------
Section 'Prompts - section markers'
# A top-level prompt without [ system ] / [ user ] renders perfectly, splits
# into ZERO chat messages, and the request is never sent. Papyrus reports
# "LLM returned empty response"; the real error is only in SkyrimNet.log.
# Submodules must NOT carry markers.
# ---------------------------------------------------------------------------
foreach ($p in Get-ChildItem $prompts -Filter *.prompt -File) {
    $t = Get-Content $p.FullName -Raw
    if ($t -notmatch '\[\s*system\s*\]') { Fail 'prompt' "$($p.Name): no [ system ] marker - messages array will be EMPTY and nothing is sent" }
    if ($t -notmatch '\[\s*user\s*\]')   { Fail 'prompt' "$($p.Name): no [ user ] marker" }
}
foreach ($p in Get-ChildItem (Join-Path $prompts 'submodules') -Filter *.prompt -File -Recurse -ErrorAction SilentlyContinue) {
    $t = Get-Content $p.FullName -Raw
    if ($t -match '\[\s*(system|user)\s*\]') { Fail 'prompt' "$($p.Name): submodule must NOT carry section markers" }
}
Ok 'prompt' 'section markers checked'

# ---------------------------------------------------------------------------
Section 'Prompts - every variable is supplied by Papyrus'
# A prompt reading a context key Papyrus never sends renders as blank with no
# error anywhere - the npc_why class of bug.
# ---------------------------------------------------------------------------
$supplied = [regex]::Matches($allSrc, '\\"([a-z_][a-z0-9_]*)\\"\s*:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$builtins = @('player','npc','name','uuid','UUID','location','gameTimeNumeric','events','maxRecentEvents','profile','said','fresh','diaries','dfresh','mem','watermarked','dmarked','ev','e','m','_n','_filter','loop','gameTimeStr','entry_date_str','content','emotion','age_hours','data','dialogue','speaker','listener','type','gameTime','memory')
foreach ($p in Get-ChildItem $prompts -Filter 'snrom_*.prompt' -File) {
    $t = Get-Content $p.FullName -Raw
    # Negative lookahead on "(" so Inja FUNCTION calls - default(), length(),
    # get_diary_entries() - are not mistaken for context variables.
    $used = [regex]::Matches($t, '\{\{\s*([a-z_][a-z0-9_]*)(?![\w(])') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    foreach ($v in $used) {
        if ($supplied -notcontains $v -and $builtins -notcontains $v) {
            Warn 'promptvar' "$($p.Name): {{ $v }} is not sent by any Papyrus context JSON - renders blank, silently"
        }
    }
}
Ok 'promptvar' "$($supplied.Count) context keys supplied by Papyrus"

# ---------------------------------------------------------------------------
Section 'Artifact - config literals survived compilation with exact case'
# The compiler interns strings CASE-INSENSITIVELY, first spelling wins, and
# identifiers enter the table before literals. A function named LLMVariant
# rewrote the literal "llmVariant" everywhere, which then failed SkyrimNet's
# case-SENSITIVE YAML lookup and silently returned the default.
# ---------------------------------------------------------------------------
# ALL our .pex files, not just the bridge - config keys are read from the
# decorators and the player alias too, and scanning one file reports the others'
# keys as missing.
$pexFiles = @(Get-ChildItem (Join-Path $repo 'Scripts') -Filter 'SNRom_*.pex' -File -ErrorAction SilentlyContinue)
if ($pexFiles.Count) {
    $strings = @()
    foreach ($pf in $pexFiles) {
        $bytes = [IO.File]::ReadAllBytes($pf.FullName)
        $sb = New-Object Text.StringBuilder
        foreach ($b in $bytes) {
            if ($b -ge 32 -and $b -lt 127) { [void]$sb.Append([char]$b) }
            else { if ($sb.Length -ge 3) { $strings += $sb.ToString() }; [void]$sb.Clear() }
        }
        if ($sb.Length -ge 3) { $strings += $sb.ToString() }
    }
    foreach ($k in $cfgReads) {
        $exact = @($strings | Where-Object { $_ -clike "*$k*" }).Count
        $any   = @($strings | Where-Object { $_ -like  "*$k*" }).Count
        if ($exact -eq 0 -and $any -gt 0) { Fail 'pex' "config key '$k' present only in the WRONG CASE - case-folded at compile time, YAML lookup will miss" }
        elseif ($exact -eq 0) { Warn 'pex' "config key '$k' not found in .pex string table - stale build?" }
    }
    Ok 'pex' "$($strings.Count) strings across $($pexFiles.Count) .pex, $($cfgReads.Count) config keys verified"
} else { Warn 'pex' 'no Scripts\SNRom_*.pex built yet - run tools\build.ps1' }

# ---------------------------------------------------------------------------
Section 'Deploy - project = staging = Data'
# Three copies, two of them hardlinked. A stale one means the game is running
# code you are not reading. Compilation success says nothing about deployment.
# ---------------------------------------------------------------------------
$deployables = @()
Get-ChildItem (Join-Path $repo 'Scripts') -Filter 'SNRom_*.pex' -File -ErrorAction SilentlyContinue | ForEach-Object { $deployables += "Scripts\$($_.Name)" }
Get-ChildItem $prompts -Filter '*.prompt' -File -Recurse | ForEach-Object {
    $deployables += ($_.FullName.Substring($repo.Length + 1))
}
Get-ChildItem (Join-Path $cfg 'actions') -Filter '*.yaml' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $deployables += ($_.FullName.Substring($repo.Length + 1))
}
# ---------------------------------------------------------------------------
# ANYTHING OF OURS IN Data MUST EXIST IN THE REPO.
#
# Every deploy check above compares files that are already tracked, so all of
# them are blind to a file that was NEVER ADDED. Four action definitions -
# cat_romance, RomanceMarkMoment, RomanceBeginSpark, RomanceEndIt - sat loose in
# Data from the first week of development, untracked, and shipped in NO release
# from 0.9.0 to 0.9.3. RomanceMarkMoment calls itself "the workhorse" in its own
# header. Players got the background assessors and none of the in-conversation
# actions, and nothing noticed for four releases: the author's own game had them
# the whole time, because that is where they were written.
#
# So this asks the opposite question to every other check here - not "does what
# we track still match?" but "is there anything of ours we are not tracking?"
# ---------------------------------------------------------------------------
$untracked = @()
$snTree = Join-Path $data 'SKSE\Plugins\SkyrimNet'
if (Test-Path $snTree) {
    Get-ChildItem $snTree -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $p = $_.FullName
            $p -notlike '*\logs\*' -and $p -notlike '*\characters\*' -and
            $p -notlike '*\original_*' -and $_.Extension -notin '.bak', '.log' -and
            $_.Name -notlike '*-bak'
        } |
        ForEach-Object {
            $isOurs = $_.Name -match '^snrom' -or $_.Name -match '^cat_romance'
            if (-not $isOurs -and $_.Length -lt 200KB) {
                $head = Get-Content $_.FullName -TotalCount 60 -ErrorAction SilentlyContinue
                if ($head -match 'SNRom_Quest|SNRom_Bridge') { $isOurs = $true }
            }
            if ($isOurs) {
                $rel = $_.FullName.Substring($snTree.Length + 1)
                $mine = Join-Path $repo (Join-Path 'SKSE\Plugins\SkyrimNet' $rel)
                if (-not (Test-Path $mine)) { $untracked += $rel }
            }
        }
}
if ($untracked) {
    Write-Host ""
    Write-Host "Ours in Data, absent from the repo - these would never ship" -ForegroundColor Cyan
    foreach ($u in $untracked) { Fail 'untracked' "$u is ours and is not in the repo - it cannot be packaged" }
} else {
    Write-Host ""
    Write-Host "Ours in Data, absent from the repo - these would never ship" -ForegroundColor Cyan
    Ok 'untracked' "nothing of ours is missing from the repo"
}

function Get-DeployHash([string]$path) {
    # .pex carries the BUILD MACHINE'S IDENTITY in its header - the compiling
    # account's username and the computer name - and tools\sanitize-pex.ps1
    # rewrites both in anything we ship. So a RELEASE build deployed over the dev
    # one is byte-different in the header and byte-identical in every single
    # instruction. Comparing whole files reported "Vortex hardlink broken" for
    # four scripts that were the same program, on 2026-08-19.
    #
    # A check that fires on a difference that cannot matter is a check people
    # learn to scroll past, and this one guards real drift. So hash the BODY:
    # the header is metadata about who compiled it, the body is the code.
    $b = [System.IO.File]::ReadAllBytes($path)
    if ([System.IO.Path]::GetExtension($path) -ne '.pex' -or $b.Length -lt 24 -or
        -not ($b[0] -eq 0xFA -and $b[1] -eq 0x57 -and $b[2] -eq 0xC0 -and $b[3] -eq 0xDE)) {
        return (Get-FileHash $path -Algorithm MD5).Hash
    }
    $o = 16                     # magic(4) major(1) minor(1) gameID(2) time(8)
    for ($i = 0; $i -lt 3; $i++) {          # source name, user name, machine name
        $o += 2 + ((($b[$o] -shl 8) -bor $b[$o + 1]))
    }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    return ([BitConverter]::ToString($md5.ComputeHash($b, $o, $b.Length - $o))).Replace('-','')
}

$drift = 0
foreach ($rel in $deployables) {
    $a = Join-Path $repo $rel; $b = Join-Path $StagingRoot $rel; $c = Join-Path $data $rel
    if (-not (Test-Path $b)) { Fail 'deploy' "$rel missing from staging"; $drift++; continue }
    if (-not (Test-Path $c)) { Fail 'deploy' "$rel missing from Data"; $drift++; continue }
    $ha = Get-DeployHash $a
    if ($ha -ne (Get-DeployHash $b)) {
        # Staging is deliberately NOT written while Skyrim is running. The
        # 2026-08-07 bugcheck named vlflt.sys - Vortex's boot-start filesystem
        # filter - and hammering the staging tree through it while the game
        # holds the same files open is avoidable risk, whatever the root cause
        # turns out to be. So during a live session this is expected, and a
        # check that always fails is a check nobody reads.
        if (Get-Process SkyrimSE -ErrorAction SilentlyContinue) {
            Warn 'deploy' "$rel differs project vs staging - expected, Skyrim is running. Sync staging once it is closed."
        }
        else { Fail 'deploy' "$rel differs project vs staging - UNDEPLOYED"; $drift++ }
    }
    elseif ($ha -ne (Get-DeployHash $c)) { Fail 'deploy' "$rel differs staging vs Data - Vortex hardlink broken"; $drift++ }
}
if ($drift -eq 0) { Ok 'deploy' "$($deployables.Count) artifacts identical across project, staging and Data" }

# ---------------------------------------------------------------------------
# The LLM variant we name must actually exist, and must survive a preset switch.
#
# Added 2026-08-03. `snrom_background` was hand-added to the live OpenRouter.yaml
# and exists in NONE of the 16 model presets, while `sever_background` exists in
# all of them. Applying or switching a preset in the SkyrimNet UI rewrites
# OpenRouter.yaml from the preset, which would drop our variant - and an unknown
# variant name makes SkyrimNet return NO RESPONSE, silently, for every assessor
# and every disposition authoring. No error, no log line, the mod just stops
# thinking. It is also why the variant is invisible in the UI: the UI lists what
# the preset defines.
Section 'LLM variant - named, present, and preset-durable'

$orPath  = Join-Path $data 'SKSE\Plugins\SkyrimNet\config\OpenRouter.yaml'
$setPath = Join-Path $data 'SKSE\Plugins\SkyrimNet\config\plugins\SkyrimNet Relationships\settings.yaml'
if ((Test-Path $orPath) -and (Test-Path $setPath)) {
    $wanted = ((Get-Content $setPath | Where-Object { $_ -match '^\s*llmVariant\s*:' }) -split ':', 2)[1].Trim().Trim('"')
    $orTxt  = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($orPath))
    if ($orTxt -notmatch ("(?m)^\s+" + [regex]::Escape($wanted) + "\s*:\s*$")) {
        Fail 'variant' "settings.yaml names llmVariant '$wanted' but OpenRouter.yaml does not define it - SkyrimNet returns NO RESPONSE, silently, for every LLM call this mod makes"
    }
    else {
        # Strip quotes AND handle the empty case. Editing a variant through the
        # Models page detaches the config from its preset and writes
        # `active_preset_id: ""` - a real value this crashed on with "Illegal
        # characters in path" before the trim.
        $activeId = ([regex]::Match($orTxt, '(?m)^active_preset_id:\s*(.*)$')).Groups[1].Value.Trim().Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($activeId)) {
            # No preset is active, so nothing can re-apply over OpenRouter.yaml.
            # This is the SAFE state for a hand-tuned variant, not a problem.
            Ok 'variant' "'$wanted' defined in OpenRouter.yaml; no active preset, so nothing can overwrite it"
            $activeId = $null
        }
        $preset = if ($activeId) { Join-Path $data "SKSE\Plugins\SkyrimNet\config\model_presets\$activeId.yaml" } else { $null }
        if (-not $activeId) { }
        elseif (-not (Test-Path $preset)) {
            Warn 'variant' "'$wanted' is defined, but active preset '$activeId' was not found on disk - cannot check preset durability"
        }
        elseif ((Get-Content $preset -Raw) -notmatch [regex]::Escape($wanted)) {
            Warn 'variant' "'$wanted' exists in OpenRouter.yaml but NOT in the active preset '$activeId' - re-applying or switching presets in the SkyrimNet UI will delete it and silently break every LLM call"
        }
        else { Ok 'variant' "'$wanted' defined in OpenRouter.yaml and carried by preset '$activeId'" }
    }
}

# ---------------------------------------------------------------------------
# The activity catalogue and the Papyrus whitelist must agree, exactly.
#
# The prompt offers 58 activity names; LabelToOffset maps each to a ROM_ faction
# and returns 0 for anything else, which IS the whitelist. A name in the prompt
# that LabelToOffset does not know is silently discarded at apply time - the
# model answers correctly, Papyrus rejects it, and the NPC ends up with fewer
# preferences than the log says were recognized.
#
# Added 2026-08-05 when the catalogue moved from a single interpunct-joined line into
# an Inja array literal (so it can be rotated per call). That edit rewrote all
# 58 entries at once, which is exactly the moment a typo becomes invisible.
Section 'Activity catalogue - prompt offers only what Papyrus accepts'

$authorPrompt = Join-Path $prompts 'snrom_author_disposition.prompt'
if (Test-Path $authorPrompt) {
    $ap  = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($authorPrompt))
    # TWO ACCEPTED FORMS. The catalogue was an Inja array literal (so it could
    # be rotated per call) and is currently a single interpunct-joined line -
    # the shape it had when authoring last worked. Both are legitimate; this
    # check is about the NAMES agreeing with LabelToOffset, not about which
    # container holds them, and it must not fail merely because the container
    # changed during a bisect.
    $names = @()
    $arr = [regex]::Match($ap, '\{%\s*set CAT\s*=\s*\[[^\]]*\]')
    if ($arr.Success) {
        $names = [regex]::Matches($arr.Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    }
    else {
        # The separator is U+00B7 INTERPUNCT. Build it from a codepoint rather
        # than typing it: this file has no BOM, so PowerShell 5.1 decodes it as
        # ANSI and a literal U+00B7 arrives here as the two chars "A-circumflex
        # + interpunct", which matches nothing. Keep this script pure ASCII.
        $dot   = [char]0x00B7
        $line  = [regex]::Match($ap, '(?m)^Locations Discovered[^\r\n]*')
        if ($line.Success) { $names = $line.Value -split "\s*$dot\s*" | ForEach-Object { $_.Trim() } }
    }
    # --- JSON booleans built from string literals -------------------------
    # Papyrus interns strings CASE-INSENSITIVELY. A source literal "true" or
    # "false" collapses into the capitalised True/False already present in any
    # script that uses Bools, so the .pex ships "npc_married":True - and since
    # that makes the WHOLE context object unparseable, every variable in it
    # comes back undefined, not just the offending one.
    #
    # This is invisible in the .psc and cost two debugging attempts on
    # 2026-08-07 before the .pex string table was read (True x6 / False x6
    # against source that said lowercase throughout). Use an Int and test
    # `== 1` in the prompt; an Int cannot be case-folded.
    # NARROW ON PURPOSE. Two broader versions of this check were written and
    # both were wrong, which is worth recording because the failures were
    # instructive:
    #
    #   1. Flagging every lowercase "true"/"false" in source. Cried wolf -
    #      SNRom_Decorators returns those strings deliberately and they DO
    #      survive interning there, because the fold resolves per script to
    #      whichever casing already holds the slot in that file.
    #   2. Reading the .pex for a surviving lowercase literal. Silently passed
    #      with the bug present, because Papyrus embeds DOCSTRINGS in the .pex
    #      and this check's own explanatory comment contains the words true and
    #      false in prose. It was matching its own documentation.
    #
    # So this only asserts the one thing that actually broke: every boolean
    # concatenated into an LLM context object must come from an Int, never a
    # String. An Int cannot be case-folded. Anything else about interning is
    # left to a human reading the .pex, which is where it has to be checked.
    Section 'Context booleans are Ints, not case-foldable strings'
    $ctxBool = @()
    foreach ($f in (Get-ChildItem $src -Filter 'SNRom_*.psc' -File)) {
        $txt = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($f.FullName))
        # ",\"some_key\":" + someVar   - the shape every ctx field is built with
        foreach ($m in [regex]::Matches($txt, '\\"(\w+)\\":"\s*\+\s*(\w+)')) {
            $key = $m.Groups[1].Value
            $var = $m.Groups[2].Value
            # Only booleans matter; a String key is quoted and cannot collide.
            if ($key -notmatch '(?i)married|sparked|enabled|_ok$|^is_|^has_') { continue }
            if ($txt -match ('(?m)^\s*Int\s+' + [regex]::Escape($var) + '\s*=')) { continue }
            if ($txt -match ('(?m)^\s*String\s+' + [regex]::Escape($var) + '\s*=')) {
                $ctxBool += ('{0}: ctx key "{1}" is fed by String {2}' -f $f.Name, $key, $var)
            }
        }
    }
    if ($ctxBool.Count) {
        Fail 'ctxbool' ("a context boolean is built from a String literal. Papyrus interns strings case-insensitively, so a lowercase `"true`" can ship as True - which is not valid JSON, and makes the WHOLE context object unparseable so EVERY variable in it comes back undefined, not just this field. Use an Int and test == 1 in the prompt: " + ($ctxBool -join '; '))
    }
    else {
        Ok 'ctxbool' 'no context boolean is fed by a String variable'
    }

    if (-not $names.Count) {
        Fail 'catalogue' "no activity catalogue found in snrom_author_disposition.prompt, in either the CAT array or the interpunct-joined form"
    }
    else {
        $dec   = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $src 'SNRom_Decorators.psc')))
        $unknown = @()
        foreach ($n in $names) {
            if ($dec -notmatch ('l == "' + [regex]::Escape($n.ToUpper()) + '"')) { $unknown += $n }
        }
        # Duplicates matter too: the same name twice wastes a slot the model
        # could have spent on a different activity.
        $dupes = $names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
        if ($unknown.Count) { Fail 'catalogue' "prompt offers $($unknown.Count) name(s) LabelToOffset rejects - they will be silently discarded: $($unknown -join ', ')" }
        if ($dupes.Count)   { Fail 'catalogue' "duplicate catalogue entries: $($dupes -join ', ')" }
        if (-not $unknown.Count -and -not $dupes.Count) { Ok 'catalogue' "$($names.Count) activities offered, all accepted by LabelToOffset, no duplicates" }
    }
}

# ---------------------------------------------------------------------------
# Trigger templates: every {{ token }} must actually resolve.
#
# Added 2026-08-03 after 108 literal "{{ sender_name }}" strings were found
# sitting in the save's persistent event history, being read back by every NPC
# in scene. Per-event fields on a mod_event trigger are addressed as
# `event_json.<field>`; written bare, Inja does not resolve them and LEAVES THE
# RAW TOKEN in the output. The trigger still fires, the YAML is still valid,
# nothing is logged. `player_name` is a global and DOES resolve bare, so half
# of each line rendered correctly, which is why it survived so long.
Section 'Trigger templates - tokens that will actually resolve'

# Bare tokens known to be globals. Anything else bare is a bug.
$triggerGlobals = @('player_name', 'player', 'gameTimeJson', 'join', 'decnpc', 'originator', 'target', 'deityName')
$trigDir = Join-Path $cfg 'triggers'
$badTok = 0
$tokSeen = 0
foreach ($tf in (Get-ChildItem $trigDir -Filter *.yaml -ErrorAction SilentlyContinue)) {
    # Strip YAML comments - a token inside a # comment is never templated.
    # $tf, not $_: inside the match loop $_ is the regex Match, whose .Name is
    # the capture-group name ("0"). Reported the group index as the filename on
    # the first negative test.
    $body = ((Get-Content $tf.FullName) | ForEach-Object { ($_ -split '#', 2)[0] }) -join "`n"
    foreach ($m in [regex]::Matches($body, '\{\{\s*([A-Za-z_][A-Za-z0-9_.]*)')) {
        $tok = $m.Groups[1].Value
        $tokSeen++
        $root = ($tok -split '\.')[0]
        if ($tok -notmatch '^event_json\.' -and $triggerGlobals -notcontains $root) {
            Fail 'trigger' "'$tok' in $($tf.Name) is neither a known global nor event_json.* - it will render as a LITERAL into the event history"
            $badTok++
        }
    }
}
if ($badTok -eq 0) { Ok 'trigger' "$tokSeen template token(s) across our triggers all resolve" }

# ---------------------------------------------------------------------------
# Foreign FormIDs still point at the record we think they do.
#
# Added 2026-08-02 with the attraction feed, which hardcodes two FormIDs from
# OStimCommunityResource.esp. That is a NEW failure shape for this project and
# a nasty one: if OCR renumbers on an update, GetFormFromFile returns None and
# the runtime message is "OStim Community Resource not present" - so the log
# actively points AWAY from the real cause, and the feature just quietly stops.
#
# The plugin is the source of truth, so read it. Each entry pairs the literal
# in our Papyrus with the EDID it is supposed to name; the scan walks to the
# record header and compares. Absent plugin = skip, not fail: these are soft
# dependencies and most machines will not have them.
Section 'Foreign FormIDs - literals still name the right record'

$foreign = @(
    @{ Plugin = 'OStimCommunityResource.esp'; Edid = 'OCR_AttractionUtilQST';  Sig = 'QUST'; Fn = 'OCR_ATTRACTION_QUEST' }
    @{ Plugin = 'OStimCommunityResource.esp'; Edid = 'OCR_AttractivenessBase'; Sig = 'GLOB'; Fn = 'OCR_ATTRACTIVENESS_BASE' }
)

function Get-RecordFormId([byte[]]$bytes, [string]$edid) {
    # Record header is 24 bytes, then subrecords; EDID is conventionally first.
    # Match 'EDID' + UInt16 size + the exact null-terminated name, then step
    # back to the header and read sig (offset 0) and FormID (offset 12).
    $nameLen = $edid.Length
    $limit = $bytes.Length - 64
    for ($i = 0; $i -lt $limit; $i++) {
        if ($bytes[$i] -eq 0x45 -and $bytes[$i+1] -eq 0x44 -and $bytes[$i+2] -eq 0x49 -and $bytes[$i+3] -eq 0x44) {
            if ([BitConverter]::ToUInt16($bytes, $i+4) -eq ($nameLen + 1)) {
                if ([Text.Encoding]::ASCII.GetString($bytes, $i+6, $nameLen) -eq $edid) {
                    return [pscustomobject]@{
                        Sig    = [Text.Encoding]::ASCII.GetString($bytes, $i-24, 4)
                        FormId = [BitConverter]::ToUInt32($bytes, $i-12)
                    }
                }
            }
        }
    }
    return $null
}

$checkedForeign = 0
foreach ($f in $foreign) {
    $esp = Join-Path $data $f.Plugin
    if (-not (Test-Path $esp)) { Ok 'formid' "$($f.Plugin) not installed - skipped (soft dependency)"; continue }

    # The literal we actually compiled against, read from the source function.
    $m = [regex]::Match($allSrc, ('(?ms)Function\s+' + [regex]::Escape($f.Fn) + '\s*\(\)\s*Global.*?Return\s+(0x[0-9A-Fa-f]+)'))
    if (-not $m.Success) { Fail 'formid' "$($f.Fn) not found in source - this check and the code have drifted apart"; continue }
    $literal = [Convert]::ToUInt32($m.Groups[1].Value, 16)

    $rec = Get-RecordFormId ([IO.File]::ReadAllBytes($esp)) $f.Edid
    if ($null -eq $rec) { Fail 'formid' "$($f.Edid) no longer exists in $($f.Plugin) - OCR renamed or removed it"; continue }

    $local = $rec.FormId -band 0xFFFFFF
    if ($rec.Sig -ne $f.Sig) {
        Fail 'formid' "$($f.Edid) is a $($rec.Sig) record, not the expected $($f.Sig)"
    } elseif ($local -ne ($literal -band 0xFFFFFF)) {
        Fail 'formid' ("{0} returns 0x{1:X8} but {2} is now 0x{3:X6} in {4} - GetFormFromFile will return None and log 'not present'" -f `
            $f.Fn, $literal, $f.Edid, $local, $f.Plugin)
    } else {
        $checkedForeign++
    }
}
if ($checkedForeign -gt 0) { Ok 'formid' "$checkedForeign foreign FormID(s) verified against the plugin record headers" }

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:fails -gt 0) {
    Write-Host "$($script:fails) FAIL, $($script:warns) WARN" -ForegroundColor Red
    exit 1
}
Write-Host "All checks passed ($($script:warns) warnings)" -ForegroundColor Green
exit 0
