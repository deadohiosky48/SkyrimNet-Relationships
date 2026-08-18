<#
    Strips the build machine's identity out of compiled Papyrus.

    THE PROBLEM. The Papyrus compiler writes the compiling account's USERNAME and
    the COMPUTER NAME into every .pex header. Nothing surfaces it, no tool warns
    about it, and it is invisible in any text search because .pex is binary - so
    it ships in every release archive unless something removes it.

    Header layout (Skyrim .pex, magic 0xFA57C0DE, big-endian):

        u32   magic
        u8    major
        u8    minor
        u16   gameID
        u64   compilation time
        wstr  source file name      <- kept; it is just SNRom_Bridge.psc
        wstr  user name             <- REPLACED
        wstr  machine name          <- REPLACED

    where wstr is a u16 length followed by that many ASCII bytes. Replacing the
    two strings means rebuilding the header, since the replacements are a
    different length - the rest of the file is copied through untouched.

    Usage:
        powershell -File "tools\sanitize-pex.ps1" -Path "Scripts\Foo.pex"
        powershell -File "tools\sanitize-pex.ps1" -Path "some\dir" -Recurse
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Recurse,
    [string]$UserName    = 'deadohiosky48',
    [string]$MachineName = 'BUILD'
)

$ErrorActionPreference = 'Stop'

function Read-Wstr([byte[]]$b, [int]$off) {
    $len = ($b[$off] -shl 8) -bor $b[$off + 1]
    $s = [System.Text.Encoding]::ASCII.GetString($b, $off + 2, $len)
    return @{ Value = $s; Next = $off + 2 + $len }
}

function Write-Wstr([string]$s) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($s)
    $out = New-Object byte[] ($bytes.Length + 2)
    $out[0] = [byte](($bytes.Length -shr 8) -band 0xFF)
    $out[1] = [byte]($bytes.Length -band 0xFF)
    [Array]::Copy($bytes, 0, $out, 2, $bytes.Length)
    return $out
}

$files = if (Test-Path $Path -PathType Container) {
    Get-ChildItem $Path -Filter *.pex -File -Recurse:$Recurse
} else {
    Get-Item $Path
}

$changed = 0
foreach ($f in $files) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)

    # Magic guards against running this over something that is not a .pex.
    # Compared byte by byte on purpose: ($b[0] -shl 24) overflows PowerShell's
    # signed Int32 for any first byte above 0x7F, and 0xFA57C0DE starts with FA.
    # The shift version silently produced 0x000000DE and skipped every file.
    if (-not ($b[0] -eq 0xFA -and $b[1] -eq 0x57 -and $b[2] -eq 0xC0 -and $b[3] -eq 0xDE)) {
        Write-Host ("  skipped {0} - not a Skyrim .pex" -f $f.Name) -ForegroundColor Yellow
        continue
    }

    $off = 16                       # magic(4) + major(1) + minor(1) + gameID(2) + time(8)
    $src  = Read-Wstr $b $off
    $user = Read-Wstr $b $src.Next
    $mach = Read-Wstr $b $user.Next
    $tailStart = $mach.Next

    if ($user.Value -eq $UserName -and $mach.Value -eq $MachineName) {
        Write-Host ("  already clean: {0}" -f $f.Name) -ForegroundColor DarkGray
        continue
    }

    $out = New-Object System.IO.MemoryStream
    $out.Write($b, 0, $src.Next)                       # header through source name
    $u = Write-Wstr $UserName;    $out.Write($u, 0, $u.Length)
    $m = Write-Wstr $MachineName; $out.Write($m, 0, $m.Length)
    $out.Write($b, $tailStart, $b.Length - $tailStart) # everything after, byte for byte
    [System.IO.File]::WriteAllBytes($f.FullName, $out.ToArray())
    $out.Dispose()

    Write-Host ("  scrubbed {0,-26} user '{1}' -> '{2}',  machine '{3}' -> '{4}'" -f `
        $f.Name, $user.Value, $UserName, $mach.Value, $MachineName)
    $changed++
}

Write-Host ("  {0} file(s) scrubbed" -f $changed)
