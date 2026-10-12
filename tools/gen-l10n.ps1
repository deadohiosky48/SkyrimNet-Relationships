<#
    Collects every word this mod shows the player, with its key, into
    SKSE\Plugins\SkyrimNet Relationships\l10n\en.json - the template a
    translator copies to <code>.json (de.json, fr.json...) and translates.
    (2.3, WP-L step 2; native/src/L10n.h is the design.)

    Where the words are, and the forms it reads (keep the key and the English
    on the call's own line, as literals):
      src\scripts\*.psc        Tr("key", "English"
      ui\relationships\*.js    t("key", "English"   or   UI.t("key", "English"
      ui\relationships\*.html  data-t="key">English<   and
                               attr="English" data-t-attr="key" (title,
                               placeholder, aria-label)
      native\src\*.cpp         L10n::Text("key", "English"

    Fails when one key has two different English texts: they would share one
    translation. Then reports, for each translation present, the keys it lacks
    (shown in English) and the keys it has that nothing uses any more.

    Usage:
        pwsh -ExecutionPolicy Bypass -File tools\gen-l10n.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo 'SKSE\Plugins\SkyrimNet Relationships\l10n'

$found = [ordered]@{}
$where = @{}
$clashes = New-Object System.Collections.Generic.List[string]

function Unescape([string]$s, [string]$kind) {
    if ($kind -eq 'html') { return [System.Net.WebUtility]::HtmlDecode($s) }
    $s = [regex]::Replace($s, '\\u([0-9a-fA-F]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
    # One pass, so an escaped backslash before an n stays a backslash and an n.
    return [regex]::Replace($s, '\\(.)', { param($m)
        switch ($m.Groups[1].Value) { 'n' { "`n" } 't' { "`t" } default { $m.Groups[1].Value } } })
}

function Add([string]$key, [string]$english, [string]$file) {
    if ($found.Contains($key)) {
        if ($found[$key] -ne $english) {
            $clashes.Add("  $key`n    $($where[$key]): $($found[$key])`n    ${file}: $english")
        }
        return
    }
    $found[$key] = $english
    $where[$key] = $file
}

$str = '"((?:[^"\\]|\\.)*)"'
$sources = @(
    @{ Dir = 'src\scripts';       Filter = '*.psc';  Kind = 'psc';  Pattern = '(?<![\w.])B?Tr\((?:\w+,\s*)?"([^"]+)",\s*' + $str },
    @{ Dir = 'ui\relationships';  Filter = '*.js';   Kind = 'js';   Pattern = '(?<![\w.$])(?:UI\.)?t\("([^"]+)",\s*' + $str },
    @{ Dir = 'native\src';        Filter = '*.cpp';  Kind = 'cpp';  Pattern = 'L10n::Text\("([^"]+)",\s*' + $str }
)
foreach ($src in $sources) {
    $dir = Join-Path $repo $src.Dir
    foreach ($f in Get-ChildItem $dir -Filter $src.Filter -File) {
        $text = Get-Content $f.FullName -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($text, $src.Pattern)) {
            Add $m.Groups[1].Value (Unescape $m.Groups[2].Value $src.Kind) "$($src.Dir)\$($f.Name)"
        }
    }
}
foreach ($f in Get-ChildItem (Join-Path $repo 'ui\relationships') -Filter '*.html' -File) {
    $text = Get-Content $f.FullName -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($text, 'data-t="([^"]+)"[^>]*>([^<]*)<')) {
        Add $m.Groups[1].Value (Unescape $m.Groups[2].Value 'html') "ui\relationships\$($f.Name)"
    }
    foreach ($tag in [regex]::Matches($text, '<[^>]+>')) {
        foreach ($attr in 'title', 'placeholder', 'aria-label') {
            $k = [regex]::Match($tag.Value, "data-t-$attr=""([^""]+)""")
            $v = [regex]::Match($tag.Value, "(?<![\w-])$attr=""([^""]*)""")
            if ($k.Success -and $v.Success) {
                Add $k.Groups[1].Value (Unescape $v.Groups[1].Value 'html') "ui\relationships\$($f.Name)"
            }
        }
    }
}

if ($clashes.Count) {
    throw "One key, two English texts - give one of them its own key:`n$($clashes -join "`n")"
}

$sorted = [ordered]@{ '_about' = 'Relationships, English. Copy to <code>.json (de, fr, es, it, pl, ru, cs, ja, zh), translate the values, keep the keys and every {0} and {1}. Keys starting with _ are ignored.' }
foreach ($k in ($found.Keys | Sort-Object)) { $sorted[$k] = $found[$k] }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$json = $sorted | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText((Join-Path $outDir 'en.json'), $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "l10n\en.json: $($found.Count) strings"

foreach ($tr in Get-ChildItem $outDir -Filter '*.json' -File | Where-Object { $_.Name -ne 'en.json' }) {
    $have = Get-Content $tr.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    $missing = @($found.Keys | Where-Object { -not $have.ContainsKey($_) })
    $stale = @($have.Keys | Where-Object { -not $_.StartsWith('_') -and -not $found.Contains($_) })
    $placeholders = @($found.Keys | Where-Object {
        $have.ContainsKey($_) -and (([regex]::Matches($found[$_], '\{[01]\}').Value | Sort-Object) -join '') -ne
                                   (([regex]::Matches([string]$have[$_], '\{[01]\}').Value | Sort-Object) -join '') })
    Write-Host ("l10n\{0}: {1} of {2} translated, {3} no longer used, {4} with placeholders that differ" -f
        $tr.Name, ($found.Count - $missing.Count), $found.Count, $stale.Count, $placeholders.Count)
    foreach ($k in $missing) { Write-Host "    missing  $k  ($($found[$k]))" }
    foreach ($k in $stale) { Write-Host "    unused   $k" }
    foreach ($k in $placeholders) { Write-Host "    {0}/{1}  $k" }
}
