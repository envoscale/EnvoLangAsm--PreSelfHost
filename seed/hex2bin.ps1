# hex2bin.ps1 <file.hex> <output>: the bytes written as hex digits in file.hex, with
# comments (# to the end of a line) and spaces ignored. PowerShell only: the seed
# (PLAN D67) needs nothing that is not already on the system.
param([Parameter(Mandatory = $true)][string]$HexFile, [Parameter(Mandatory = $true)][string]$Output)
$ErrorActionPreference = 'Stop'
$digits = New-Object System.Text.StringBuilder
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $HexFile))) {
    $hash = $line.IndexOf('#')
    if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
    [void]$digits.Append(($line -replace '\s', ''))
}
$text = $digits.ToString()
if ($text -notmatch '^[0-9A-Fa-f]*$') { throw "hex2bin: $HexFile has something other than hex digits outside comments" }
if ($text.Length % 2 -ne 0) { throw "hex2bin: $HexFile has an odd number of hex digits" }
$bytes = New-Object byte[] ($text.Length / 2)
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($text.Substring(2 * $i, 2), 16) }
if (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path (Get-Location).Path $Output }
[IO.File]::WriteAllBytes($Output, $bytes)
