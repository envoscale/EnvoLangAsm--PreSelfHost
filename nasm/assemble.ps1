# Phase A bootstrap adapter: assemble one .eas unit with NASM in flat-binary mode.
# Usage: assemble.ps1 <input.eas> <output-file> <include-dir>
# This is the only file in the repository that knows NASM exists (besides assemble.sh).
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [Parameter(Mandatory = $true)][string]$IncludeDir
)
$ErrorActionPreference = 'Stop'

function Find-Nasm {
    if ($env:NASM -and (Test-Path -LiteralPath $env:NASM)) { return $env:NASM }
    $cmd = Get-Command nasm -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'NASM\nasm.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'NASM\nasm.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'bin\NASM\nasm.exe') }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

$nasm = Find-Nasm
if (-not $nasm) {
    [Console]::Error.WriteLine('error: NASM not found. Install it (winget install NASM.NASM) or set $env:NASM. See adapters/bootstrap/nasm/README.md')
    exit 127
}

# NASM requires the include prefix to end with a path separator.
$inc = $IncludeDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
# In EAS a `near` jump is always rel32 (docs/spec/eas.md). NASM 3.01 treats `near` as a
# hint and shortens jumps that fit in rel8; "strict near" keeps the EAS meaning in every
# NASM version, and leaves the bytes of versions that already honour `near` unchanged.
& $nasm -f bin -w+all '-dnear=strict near' -I $inc -o $OutputFile $InputFile
exit $LASTEXITCODE
