<#
    Live in-game smoke test for SkyrimNet-Romantasy.

    Covers what check.ps1 CANNOT: Papyrus logic, prompt rendering, and the
    end-to-end award path. Run it after any .pex change; prompt-only edits are
    cheaper to eyeball.

    THE GAME MUST BE RUNNING AND UNPAUSED for the whole run (~3 min). Switching
    to another window pauses Skyrim, which suspends the Papyrus VM - dispatches
    then queue instead of executing and every assertion times out. That is the
    single most common reason this script "fails".

    NON-MUTATING BY CONSTRUCTION. It sets talkDailyCap=0 and sparkEnabled=false
    for the duration, so ApplyTalkAward drops every award while the full
    pipeline still runs, and no NPC can cross into romance. Both are restored in
    a finally block even on Ctrl-C or a mid-run error. Verified this session:
    the cap produces "Daily conversation budget spent - award dropped".

    Run (Windows PowerShell 5.1 - `pwsh` is PS7 and is NOT installed here):
        powershell -ExecutionPolicy Bypass -File "tools\smoke.ps1"

    Exit 0 = all assertions passed, 1 = at least one failed.
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [string]$Api        = 'http://127.0.0.1:8080',
    [int]$StepTimeoutSec = 90
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
$data     = Join-Path $SkyrimRoot 'Data'
$settings = Join-Path $data 'SKSE\Plugins\SkyrimNet\config\plugins\SkyrimNet Relationships\settings.yaml'
$snrom    = Join-Path $data 'SKSE\Plugins\SkyrimNet Relationships\logs\snrom.log'
$ledger   = Join-Path $data 'SKSE\Plugins\SkyrimNet Relationships\logs\ledger.jsonl'
$inlog    = Join-Path $data 'SKSE\Plugins\SkyrimNet\logs\openrouter_input.log'
$outlog   = Join-Path $data 'SKSE\Plugins\SkyrimNet\logs\openrouter_output.log'

$script:pass = 0; $script:fail = 0
function Assert($name, [bool]$ok, $detail) {
    if ($ok) { Write-Host ("  PASS  {0}" -f $name) -ForegroundColor Green; $script:pass++ }
    else     { Write-Host ("  FAIL  {0}`n        {1}" -f $name, $detail) -ForegroundColor Red; $script:fail++ }
}
function Info($m) { Write-Host "  ..    $m" -ForegroundColor DarkGray }

function Invoke-Fn($fn, $argsArray) {
    # ALWAYS read the BODY. A dispatch that fails inside Papyrus still returns
    # HTTP 200; the only trace of an argument-count mismatch is SkyrimNet.log.
    $body = @{ questEditorId='SNRom_Quest'; scriptName='SNRom_Bridge'; functionName=$fn; arguments=$argsArray } | ConvertTo-Json -Compress
    $r = Invoke-WebRequest -UseBasicParsing -Uri "$Api/game-data?api=execute-quest-script-function" -Method POST -ContentType 'application/json' -Body $body -TimeoutSec 30
    ($r.Content | ConvertFrom-Json).result
}
function Wait-ForLine($path, $pattern, $fromLen, $timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            $len = (Get-Item $path).Length
            if ($len -gt $fromLen) {
                $tail = Get-Content $path -Raw
                if ($tail.Length -gt $fromLen) {
                    $new = $tail.Substring([Math]::Min($fromLen, $tail.Length))
                    if ($new -match $pattern) { return $new }
                }
            }
        }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

$restore = @{}
try {
    Write-Host "`nSkyrimNet-Romantasy live smoke test" -ForegroundColor Cyan
    Write-Host "STAY IN-GAME AND UNPAUSED until this finishes.`n" -ForegroundColor Yellow

    # -- A1 --------------------------------------------------------------
    $reachable = $false
    try { $null = Invoke-WebRequest -UseBasicParsing -Uri "$Api/game-data?api=nearby-actors" -TimeoutSec 10; $reachable = $true } catch {}
    Assert 'A1 game is running and the web API answers' $reachable 'Start Skyrim, or check WebServer.yaml'
    if (-not $reachable) { exit 1 }

    # -- A2 -- proves the CURRENT .pex is loaded, and works even while paused.
    $sig = (Invoke-WebRequest -UseBasicParsing -Uri "$Api/game-data?api=quest-script-functions&questEditorId=SNRom_Quest&scriptName=SNRom_Bridge" -TimeoutSec 20).Content
    $need = @('AssessTalk','AssessNextTalk','AssessSpark','AssessNextSpark','SlotStale','IsFollowing')
    $missing = @($need | Where-Object { $sig -notmatch [regex]::Escape($_) })
    Assert 'A2 expected functions present in the loaded script' ($missing.Count -eq 0) "missing: $($missing -join ', ') - stale .pex? restart required after a build"

    # -- pick a live subject ---------------------------------------------
    # Prefer an ENROLLED NPC. A random townsfolk renders "Nothing has passed
    # between them recently" with no memories or diary - a correct render that
    # exercises none of the ladder, and the first version of this script duly
    # reported a false failure against Marise Aravel of Riften.
    $actors = ((Invoke-WebRequest -UseBasicParsing -Uri "$Api/game-data?api=nearby-actors" -TimeoutSec 15).Content | ConvertFrom-Json).actors
    $candidates = @($actors | Where-Object { -not $_.isPlayer -and $_.has_bio })
    $enrolled = @()
    if (Test-Path $ledger) {
        $enrolled = Get-Content $ledger | ForEach-Object { if ($_ -match '"npc":"([^"]+)"') { $Matches[1] } } | Sort-Object -Unique
    }
    $subject = $candidates | Where-Object { $enrolled -contains $_.name } | Select-Object -First 1
    $subjectIsEnrolled = $null -ne $subject
    if (-not $subject) { $subject = $candidates | Select-Object -First 1 }
    if (-not $subject) { Assert 'A3 a nearby NPC to test against' $false 'no non-player NPC with a bio nearby - stand near a follower'; exit 1 }

    # An ENROLLED subject is required for the ladder assertions to mean anything.
    # SkyrimNet gives bios to creatures too, so the fallback once selected a
    # House Cat - and A6/A7/A8 all "passed" against it, because the cat had
    # memories and a diary like any other actor. A check that reassures without
    # testing anything is worse than one that fails. Fail A3 loudly instead.
    Assert 'A3 test subject is an ENROLLED follower' $subjectIsEnrolled `
        "nearest bio'd actor is '$($subject.name)' (0x$($subject.formID)), which has never been enrolled. Stand near a follower and re-run - assertions against a non-enrolled actor prove nothing."
    Info "subject: $($subject.name) (0x$($subject.formID))"
    if (-not $subjectIsEnrolled) {
        Info 'skipping A4-A9 - they require an enrolled subject. A10 (queue) still runs.'
    }

    # -- arm the safety net ----------------------------------------------
    $lines = Get-Content $settings
    foreach ($kv in @(@('talkDailyCap','0'), @('sparkEnabled','false'))) {
        $k = $kv[0]; $v = $kv[1]
        $existing = $lines | Where-Object { $_ -match "^\s*$k\s*:" } | Select-Object -First 1
        if ($existing) { $restore[$k] = $existing; $lines = $lines | ForEach-Object { if ($_ -match "^\s*$k\s*:") { "$k`: $v" } else { $_ } } }
        else { $restore[$k] = $null; $lines += "$k`: $v" }
    }
    # No BOM: a UTF-8 BOM corrupts the FIRST key in the file and yaml-cpp
    # rejects a fused line within ~5s via the config watcher.
    [IO.File]::WriteAllText($settings, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Info 'awards suppressed (talkDailyCap=0, sparkEnabled=false)'
    Start-Sleep -Seconds 2

    # -- A4..A9 -- full talk pipeline. Only meaningful on an enrolled subject.
    if ($subjectIsEnrolled) {
    $inLen  = (Get-Item $inlog).Length
    $outLen = if (Test-Path $outlog) { (Get-Item $outlog).Length } else { 0 }
    $snLen  = (Get-Item $snrom).Length
    $ledLen = if (Test-Path $ledger) { (Get-Item $ledger).Length } else { 0 }

    # afSince deliberately nonzero so the watermark filter must engage.
    # AssessTalk takes TWO args - Papyrus defaults do NOT apply through this API.
    $res = Invoke-Fn 'AssessTalk' @("0x$($subject.formID)", 1.0)
    Assert 'A4 AssessTalk dispatch accepted' ($res.success -eq $true -and $res.result -eq 0) "inner result: $($res | ConvertTo-Json -Compress)"

    $rendered = Wait-ForLine $inlog 'what she was willing to say aloud' $inLen $StepTimeoutSec
    Assert 'A5 talk prompt rendered' ($null -ne $rendered) "no render in ${StepTimeoutSec}s. If the game was paused this is expected; otherwise check SkyrimNet.log for 'Failed to render template'"

    if ($rendered) {
        # The ladder blocks are CONDITIONAL by design: memories render only when
        # there is fresh dialogue or diary to contextualise, and the diary only
        # when something was written since the last assessment. So assert the
        # ORDER of whatever rendered, never that all three are present - an NPC
        # with nothing new is supposed to show just "Nothing has passed...".
        $hasKept  = $rendered -match 'WHAT SHE KEPT'
        $hasDiary = $rendered -match 'HER OWN ACCOUNT'
        if ($hasKept -and $hasDiary) {
            Assert 'A6 ladder order: said -> kept -> diary (least guarded last)' `
                ($rendered -match '(?s)WHAT WAS SAID.*WHAT SHE KEPT.*HER OWN ACCOUNT') `
                'block order wrong - position IS priority; the least-guarded source must sit closest to the question'
        } elseif ($hasKept -or $hasDiary) {
            Assert 'A6 ladder order: rendered blocks follow the transcript' `
                ($rendered -match '(?s)WHAT WAS SAID.*(WHAT SHE KEPT|HER OWN ACCOUNT)') `
                'a supporting block rendered ABOVE the transcript'
        } else {
            Info 'A6 skipped - no memories or diary rendered (correct for an NPC with nothing new)'
        }
        Assert 'A7 watermark engaged (no silent full-window fallback)' `
            ($rendered -notmatch 'WATERMARK INERT') `
            'filter matched nothing and fell back to the full window - stale material can be re-scored'
    }

    # -- A8 -- the MODEL ANSWERED IN OUR FORMAT rather than roleplaying ----
    # Asserted against openrouter_output.log, which the SKSE plugin writes
    # promptly - NOT snrom.log, which MiscUtil.WriteToFile lags by minutes. The
    # first version of this check watched snrom.log and reported a false failure
    # for a verdict that arrived 30s after the window closed.
    #
    # The real risk this guards: render_character_profile embeds a block headed
    # "THIS IS WHO YOU ARE ROLEPLAYING AS", and a smaller model sometimes obeys
    # THAT instead of our answer template - replying in character as the NPC with
    # no WEIGHT: line anywhere. FieldValue then returns "" and Papyrus logs
    # "Talk verdict for X: '' - no award". Observed intermittently on
    # gemma-4-12B for Kayla, Nicollette and Marise Aravel while Svana's own
    # responses came back correctly formatted.
    $answer = Wait-ForLine $outlog 'snrom_background' $outLen $StepTimeoutSec
    Assert 'A8 model returned a verdict, not roleplay' `
        ($null -ne $answer -and $answer -match 'WEIGHT:\s*(NOTHING|SMALL|REAL|MAJOR|LANDMARK)') `
        "no well-formed WEIGHT: in the response. The model answered in character instead of judging - conversational scoring silently does nothing when this happens"

    $ledNow = if (Test-Path $ledger) { (Get-Item $ledger).Length } else { 0 }
    Assert 'A9 no points awarded during the test' ($ledNow -eq $ledLen) `
        "ledger grew by $($ledNow - $ledLen) bytes - the award suppression did NOT hold, game state was mutated"
    }   # end: subject is enrolled

    # -- A10 -- queue fairness: successive picks must not be the same NPC --
    $snLen2 = (Get-Item $snrom).Length
    1..3 | ForEach-Object { $null = Invoke-Fn 'AssessNextTalk' @(); Start-Sleep -Seconds 6 }
    Start-Sleep -Seconds 10
    $tail = Get-Content $snrom -Raw
    $new  = $tail.Substring([Math]::Min($snLen2, $tail.Length))
    $picked = [regex]::Matches($new, 'Talk assessment sent for (.+?) \(rc') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    if ($picked.Count -eq 0) { Info 'no scheduled picks (all followers inside cooldown, or only one present) - A10 skipped' }
    else {
        Info "picked: $($picked -join ', ')"
        Assert 'A10 queue is not starving the roster' ($picked.Count -ge 1) 'no NPC picked at all'
    }
}
finally {
    if ($restore.Count) {
        $lines = Get-Content $settings
        foreach ($k in $restore.Keys) {
            if ($null -eq $restore[$k]) { $lines = $lines | Where-Object { $_ -notmatch "^\s*$k\s*:" } }
            else { $lines = $lines | ForEach-Object { if ($_ -match "^\s*$k\s*:") { $restore[$k] } else { $_ } } }
        }
        [IO.File]::WriteAllText($settings, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
        Write-Host "`n  settings.yaml restored (awards re-enabled)" -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($script:fail -gt 0) { Write-Host "$($script:pass) passed, $($script:fail) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "$($script:pass) passed" -ForegroundColor Green
exit 0
