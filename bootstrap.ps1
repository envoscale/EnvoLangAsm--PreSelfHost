<#
EnvoScaleAsm: builds the Envo compiler up from assembly, on Windows with only what
Windows ships (PowerShell 5.1 or 7), plus NASM if it is installed. bootstrap.sh is the
POSIX twin; keep the two in step.

  .\bootstrap.ps1 build       stage 0 from assembly (NASM, or the hex seed without it),
                              stage 1 with it, then the EnvoScale compiler with stage 1
  .\bootstrap.ps1 test        build, then the stage 0 and stage 1 tests, and check that the
                              compiler built by stage 1 behaves as it does built by itself
  .\bootstrap.ps1 fixedpoint  build, then the compiler by itself twice at -O2; both must match
  .\bootstrap.ps1 seed        fixedpoint, then the seed compilers in build\seed-release
  .\bootstrap.ps1 check       every jump in the .eas sources states its size
  .\bootstrap.ps1 clean

The compiler's sources come from EnvoScale at the commit in envoscale.ref: from
$env:ENVOSCALE if set, else .\envoscale, cloned on first use (needs git).
#>
param([string]$Command = 'help')

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Build = Join-Path $Root 'build\stage0'
$Build1 = Join-Path $Root 'build\stage1'
$Build2 = Join-Path $Root 'build\stage2'
$Stage0 = Join-Path $Root 'stage0'
$Stage1 = Join-Path $Root 'stage1'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Say([string]$msg) { Write-Host $msg }
function Fail([string]$msg) { [Console]::Error.WriteLine("error: $msg"); exit 1 }

# The EnvoScale checkout the compiler is built from, at envoscale.ref.
$Ref = (Get-Content -LiteralPath (Join-Path $Root 'envoscale.ref') -Raw).Trim()
if ($env:ENVOSCALE) {
    $Es = (Resolve-Path -LiteralPath $env:ENVOSCALE).Path
} else {
    $Es = Join-Path $Root 'envoscale'
    if (-not (Test-Path -LiteralPath (Join-Path $Es '.git'))) {
        Say 'clone     https://github.com/envoscale/EnvoScale -> envoscale\'
        & git clone -q https://github.com/envoscale/EnvoScale $Es
        if ($LASTEXITCODE -ne 0) { Fail 'cloning EnvoScale failed' }
    }
    if ((& git -C $Es rev-parse HEAD) -ne $Ref) {
        & git -C $Es fetch -q origin
        & git -C $Es -c advice.detachedHead=false checkout -q $Ref
        if ($LASTEXITCODE -ne 0) { Fail "envoscale\: cannot check out $Ref" }
    }
}
$Stage2 = Join-Path $Es 'compiler'

# ------------------------------------------------------------------- build
# asm0, the seed assembler (bootstrap/seed, PLAN D67), made from its hex with PowerShell
# alone; gives its path.
function Get-SeedAsm0 {
    $dir = Join-Path $Root 'build\seed'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $bin = Join-Path $dir 'asm0.exe'
    & (Join-Path $Root 'seed\hex2bin.ps1') (Join-Path $Root 'seed\seed-windows.hex') $bin
    return $bin
}

function Invoke-Build {
    New-Item -ItemType Directory -Force $Build | Out-Null
    $adapter = Join-Path $Root 'nasm\assemble.ps1'
    $units = @(
        @{ Src = 'envoc0-windows.eas'; Out = 'envoc0.exe' },
        @{ Src = 'envoc0-linux.eas';   Out = 'envoc0' }
    )
    foreach ($u in $units) {
        $src = Join-Path $Stage0 $u.Src
        $out = Join-Path $Build $u.Out
        Say "assemble  stage0/$($u.Src) -> build/stage0/$($u.Out)"
        & $adapter $src $out $Stage0
        if ($LASTEXITCODE -eq 127) {
            # no NASM: the seed assembles Stage 0 to the same bytes (Phase B, PLAN D67)
            Say '          NASM not found: assembling with the seed (seed/)'
            $seedTool = Get-SeedAsm0
            & $seedTool $src $out
            if ($LASTEXITCODE -ne 0) { Fail "assembling $($u.Src) with the seed failed (exit $LASTEXITCODE)" }
        } elseif ($LASTEXITCODE -ne 0) { Fail "assembling $($u.Src) failed (exit $LASTEXITCODE)" }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLowerInvariant()
        $size = (Get-Item -LiteralPath $out).Length
        Say ("          {0,8} bytes  sha256 {1}" -f $size, $hash)
    }

    # Stage 1 is an Envo-Core program (PLAN D11); envoc0 builds it for both OSes.
    New-Item -ItemType Directory -Force $Build1 | Out-Null
    $envoc0 = Join-Path $Build 'envoc0.exe'
    $files = @(Get-Content -LiteralPath (Join-Path $Stage1 'files.txt') | Where-Object { $_.Trim() -ne '' })
    foreach ($u in @(@{ Target = 'x86_64-windows'; Out = 'envoc1.exe' }, @{ Target = 'x86_64-linux'; Out = 'envoc1' })) {
        $out = Join-Path $Build1 $u.Out
        Say "build     stage1 -> build/stage1/$($u.Out)"
        $r = Invoke-Tool $envoc0 (@('build') + $files + @('-o', $out, '--target', $u.Target)) $Stage1
        if ($r.Code -ne 0) { Fail "building Stage 1 ($($u.Target)) failed: $($r.Err.Trim())" }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLowerInvariant()
        $size = (Get-Item -LiteralPath $out).Length
        Say ("          {0,8} bytes  sha256 {1}" -f $size, $hash)
    }

    # Stage 2 is an Envo-S1 program (PLAN D16); envoc1 builds it for both OSes.
    New-Item -ItemType Directory -Force $Build2 | Out-Null
    $envoc1 = Join-Path $Build1 'envoc1.exe'
    $files = @(Get-Content -LiteralPath (Join-Path $Stage2 'files.txt') | Where-Object { $_.Trim() -ne '' })
    foreach ($u in @(@{ Target = 'x86_64-windows'; Out = 'envoc.exe' }, @{ Target = 'x86_64-linux'; Out = 'envoc' })) {
        $out = Join-Path $Build2 $u.Out
        Say "build     envoscale/compiler -> build/stage2/$($u.Out)"
        $r = Invoke-Tool $envoc1 (@('build') + $files + @('-o', $out, '--target', $u.Target)) $Stage2
        if ($r.Code -ne 0) { Fail "building Stage 2 ($($u.Target)) failed: $($r.Err.Trim())" }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLowerInvariant()
        $size = (Get-Item -LiteralPath $out).Length
        Say ("          {0,8} bytes  sha256 {1}" -f $size, $hash)
    }
}

# ------------------------------------------------------------------- fixed point
# PLAN D18, M3.9: stage2a (build\stage2, built by envoc1) builds Stage 2 at -O2 into
# build\stage2b, and stage2b builds it again into build\stage2c, for both targets.
# stage2b and stage2c must be byte-identical. Keep in step with bootstrap.sh.
function Invoke-FixedPoint {
    Invoke-Build
    $files = @(Get-Content -LiteralPath (Join-Path $Stage2 'files.txt') | Where-Object { $_.Trim() -ne '' })
    foreach ($step in @(@{ From = 'stage2'; To = 'stage2b' }, @{ From = 'stage2b'; To = 'stage2c' })) {
        $dir = Join-Path $Root "build\$($step.To)"
        New-Item -ItemType Directory -Force $dir | Out-Null
        $exe = Join-Path $Root "build\$($step.From)\envoc.exe"
        foreach ($u in @(@{ Target = 'x86_64-linux'; Out = 'envoc' }, @{ Target = 'x86_64-windows'; Out = 'envoc.exe' })) {
            $out = Join-Path $dir $u.Out
            Say "build     compiler -> build/$($step.To)/$($u.Out) (by build/$($step.From)/envoc.exe, -O2)"
            $r = Invoke-Tool $exe (@('build') + $files + @('-O2', '-o', $out, '--target', $u.Target)) $Stage2
            if ($r.Code -ne 0) { Fail "building Stage 2 ($($u.Target)) with build/$($step.From) failed: $($r.Err.Trim())" }
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLowerInvariant()
            Say ("          {0,8} bytes  sha256 {1}" -f (Get-Item -LiteralPath $out).Length, $hash)
        }
    }
    foreach ($out in @('envoc', 'envoc.exe')) {
        $b = Join-Path $Root "build\stage2b\$out"
        $c = Join-Path $Root "build\stage2c\$out"
        if ((Get-FileHash -LiteralPath $b).Hash -eq (Get-FileHash -LiteralPath $c).Hash) { Say "fixed point: stage2b/$out = stage2c/$out" }
        else { Fail "no fixed point: build/stage2b/$out and build/stage2c/$out differ" }
    }
}

# ------------------------------------------------------------------- process helper
function Quote-Arg([string]$a) {
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

# Runs a program and captures exit code, stdout and stderr as UTF-8 text.
function Invoke-Tool([string]$exe, [string[]]$argv, [string]$cwd) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argv | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEnd()
    $out = $outTask.Result
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err }
}

# Stage 2 only (M3.7): compiles each of the files to an object (--unit), links the objects
# and returns a problem unless the result is the executable `build` wrote, or $null.
function Test-Objects([string]$exe, [string]$dir, [string]$program, [string[]]$files) {
    $objs = @()
    for ($k = 0; $k -lt $files.Count; $k++) {
        $obj = "$program.$k.eo"
        $r = Invoke-Tool $exe (@('compile') + $files + @('--unit', $files[$k], '-o', $obj)) $dir
        if ($r.Code -ne 0) { return "compile --unit $($files[$k]) failed: $($r.Err.Trim())" }
        $objs += $obj
    }
    $r = Invoke-Tool $exe (@('link') + $objs + @('-o', "$program.linked")) $dir
    if ($r.Code -ne 0) { return "link failed: $($r.Err.Trim())" }
    if (-not (Test-SameBytes $program "$program.linked")) { return 'the linked executable differs from the build' }
    return $null
}

# True if the files at a and b hold the same bytes.
function Test-SameBytes([string]$a, [string]$b) {
    if (-not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b)) { return $false }
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    return [string]::Equals($latin1.GetString([IO.File]::ReadAllBytes($a)), $latin1.GetString([IO.File]::ReadAllBytes($b)))
}

function Normalize([string]$s) { return ($s -replace "`r`n", "`n") }

# Shows the first line where two texts differ.
function Show-Diff([string]$expected, [string]$actual) {
    $e = $expected -split "`n"
    $a = $actual -split "`n"
    $n = [Math]::Max($e.Count, $a.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $el = if ($i -lt $e.Count) { $e[$i] } else { '<end of file>' }
        $al = if ($i -lt $a.Count) { $a[$i] } else { '<end of file>' }
        if (-not [string]::Equals($el, $al)) {
            Say "      first difference at output line $($i + 1):"
            Say "        expected: $el"
            Say "        actual:   $al"
            return
        }
    }
}

# ------------------------------------------------------------------- test
function Invoke-Test {
    Invoke-Build
    $exe = Join-Path $Build 'envoc0.exe'
    $script:passed = 0
    $script:failed = 0
    function Pass([string]$name) { $script:passed++ }
    function Bad([string]$name, [string]$why) { $script:failed++; Say "FAIL  $name"; if ($why) { Say "      $why" } }

    # Hardening (PLAN D68): Stage 1 and Stage 2 executables keep code and data apart (W^X)
    # and can be loaded anywhere (ASLR): Linux ET_DYN with an R+X and an R+W segment;
    # Windows with DYNAMIC_BASE and HIGH_ENTROPY_VA and no section both writable and executable
    Say ''
    Say 'hardening: W^X and ASLR in the executables of Stages 1 and 2'
    $hsrc = (Get-ChildItem -LiteralPath (Join-Path $Es 'tests\spec\core-run') -Filter '*.envo' | Sort-Object Name | Select-Object -First 1).FullName
    $hdir = Join-Path $Root 'build\hardening'
    New-Item -ItemType Directory -Force $hdir | Out-Null
    foreach ($hComp in @((Join-Path $Build1 'envoc1.exe'), (Join-Path $Build2 'envoc.exe'))) {
        $hElf = Join-Path $hdir 'h-linux'
        $hExe = Join-Path $hdir 'h-win.exe'
        Invoke-Tool $hComp @('build', $hsrc, '-o', $hElf, '--target', 'x86_64-linux') $Root | Out-Null
        Invoke-Tool $hComp @('build', $hsrc, '-o', $hExe, '--target', 'x86_64-windows') $Root | Out-Null
        $hb = [IO.File]::ReadAllBytes($hElf)
        $hEt = [BitConverter]::ToUInt16($hb, 16)
        $hF0 = [BitConverter]::ToUInt32($hb, 68)
        $hF1 = [BitConverter]::ToUInt32($hb, 124)
        $hName = Split-Path $hComp -Leaf
        if ($hEt -eq 3 -and $hF0 -eq 5 -and $hF1 -eq 6) { Pass "hardening: ELF from $hName" } else { Bad "hardening: ELF from $hName" "e_type $hEt, segment flags $hF0 and $hF1" }
        $hb = [IO.File]::ReadAllBytes($hExe)
        $hPe = [BitConverter]::ToUInt32($hb, 60)
        $hDll = [BitConverter]::ToUInt16($hb, $hPe + 94)
        $hNs = [BitConverter]::ToUInt16($hb, $hPe + 6)
        $hWx = $false
        for ($hi = 0; $hi -lt $hNs; $hi++) {
            $hc = [BitConverter]::ToUInt32($hb, 0x16C + 40 * $hi)
            if (($hc -band 0x20000000) -ne 0 -and ($hc -band 0x80000000) -ne 0) { $hWx = $true }
        }
        if (($hDll -band 0x60) -eq 0x60 -and $hNs -ge 2 -and -not $hWx) { Pass "hardening: PE from $hName" } else { Bad "hardening: PE from $hName" "DllCharacteristics $hDll, $hNs sections, writable code: $hWx" }
    }

    # Phase B (PLAN D67): asm0 made from the hex seed with PowerShell alone assembles
    # itself, the other asm0 and Stage 0 to exactly the bytes NASM gives
    Say ''
    Say 'seed: asm0 from seed/*.hex assembles itself, the other asm0 and Stage 0 byte for byte'
    $seedTool = Get-SeedAsm0
    $seedTmp = Join-Path $Root 'build\seed'
    foreach ($other in @('linux', 'windows')) {
        $fromHex = Join-Path $seedTmp "asm0-$other.hex.bin"
        & (Join-Path $Root 'seed\hex2bin.ps1') (Join-Path $Root "seed\seed-$other.hex") $fromHex
        $built = Join-Path $seedTmp "asm0-$other.built"
        $r = Invoke-Tool $seedTool @((Join-Path $Root "seed\asm0-$other.eas"), $built) $Root
        if ($r.Code -eq 0 -and (Get-FileHash -LiteralPath $fromHex).Hash -eq (Get-FileHash -LiteralPath $built).Hash) { Pass "seed: asm0-$other.eas" } else { Bad "seed: asm0-$other.eas" "exit $($r.Code): $($r.Err.Trim())" }
    }
    foreach ($u in @(@{ Src = 'envoc0-windows.eas'; Out = 'envoc0.exe' }, @{ Src = 'envoc0-linux.eas'; Out = 'envoc0' })) {
        $built = Join-Path $seedTmp "$($u.Out).seed"
        $r = Invoke-Tool $seedTool @((Join-Path $Stage0 $u.Src), $built) $Root
        if ($r.Code -eq 0 -and (Get-FileHash -LiteralPath (Join-Path $Build $u.Out)).Hash -eq (Get-FileHash -LiteralPath $built).Hash) { Pass "seed: $($u.Src)" } else { Bad "seed: $($u.Src)" "exit $($r.Code): $($r.Err.Trim())" }
    }

    Say ''
    Say 'smoke tests'
    $r = Invoke-Tool $exe @('version') $Root
    if ($r.Code -eq 0 -and $r.Out.StartsWith('envoc0 ')) { Pass 'version' } else { Bad 'version' "exit $($r.Code), stdout: $($r.Out)" }
    $r = Invoke-Tool $exe @() $Root
    if ($r.Code -eq 2 -and $r.Err.StartsWith('usage: envoc0')) { Pass 'no arguments' } else { Bad 'no arguments' "exit $($r.Code), stderr: $($r.Err)" }
    $r = Invoke-Tool $exe @('frobnicate') $Root
    if ($r.Code -eq 2 -and $r.Err.StartsWith("envoc0: error: unknown command 'frobnicate'")) { Pass 'unknown command' } else { Bad 'unknown command' "exit $($r.Code), stderr: $($r.Err)" }
    $r = Invoke-Tool $exe @('lex', 'no such file.envo') $Root
    if ($r.Code -eq 1 -and $r.Err.StartsWith("envoc0: error: cannot open 'no such file.envo'")) { Pass 'missing file' } else { Bad 'missing file' "exit $($r.Code), stderr: $($r.Err)" }
    # Paths are UTF-8 on every OS: a name with a space, a Latin, a CJK and a non-BMP character.
    $tmp = Join-Path $Build 'tmp'
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $uname = "u$([char]0x00FC)nicode $([char]0x65E5)$([char]::ConvertFromUtf32(0x1F600)).envo"
    [IO.File]::WriteAllText((Join-Path $tmp $uname), "print(`"hi`")`n", $Utf8)
    $r = Invoke-Tool $exe @('lex', $uname) $tmp
    if ($r.Code -eq 0 -and $r.Out.StartsWith('1:1 n ident print')) { Pass 'unicode path' } else { Bad 'unicode path' "exit $($r.Code), stderr: $($r.Err)" }
    # Cross-compilation: this host builds the other OS's executable (it can only check the header).
    [IO.File]::WriteAllText((Join-Path $tmp 'cross.envo'), "print(`"hi`")`n", $Utf8)
    $r = Invoke-Tool $exe @('build', 'cross.envo', '-o', 'cross-linux', '--target', 'x86_64-linux') $tmp
    $ok = $false
    if ($r.Code -eq 0) { $head = [IO.File]::ReadAllBytes((Join-Path $tmp 'cross-linux')); $ok = ($head[0] -eq 0x7F -and $head[1] -eq 0x45 -and $head[2] -eq 0x4C -and $head[3] -eq 0x46) }
    if ($ok) { Pass 'cross build (linux)' } else { Bad 'cross build (linux)' "exit $($r.Code), stderr: $($r.Err)" }

    # Golden suites: tests/golden/<dir>/<name>.envo -> <name><ext>, produced by `envoc0 <command>`.
    # Keep this list in step with bootstrap.sh.
    $goldenSuites = @(
        @{ Dir = 'lexer';  Command = 'lex';   Ext = '.tokens' },
        @{ Dir = 'parser'; Command = 'parse'; Ext = '.ast' },
        @{ Dir = 'check';  Command = 'check'; Ext = '.check' }
    )
    foreach ($suite in $goldenSuites) {
      Say "golden tests: tests/golden/$($suite.Dir)"
      $dir = Join-Path $Es "tests\golden\$($suite.Dir)"
      foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.envo' | Sort-Object Name) {
        $name = "golden/$($suite.Dir)/$($f.Name)"
        $expectedFile = [IO.Path]::ChangeExtension($f.FullName, $suite.Ext)
        if (-not (Test-Path -LiteralPath $expectedFile)) { Bad $name "missing $($suite.Ext) file"; continue }
        $expected = Normalize ([IO.File]::ReadAllText($expectedFile, $Utf8))
        $r = Invoke-Tool $exe @($suite.Command, $f.Name) $dir
        $actual = Normalize $r.Out
        if ($r.Code -ne 0) { Bad $name "exit $($r.Code), stderr: $($r.Err.Trim())"; continue }
        if ([string]::Equals($expected, $actual)) { Pass $name } else { Bad $name 'output differs'; Show-Diff $expected $actual }
      }
    }

    # Spec error tests run through `envoc0 check`, which lexes and parses first, so
    # lexical and syntax errors are still reported by their own stage.
    # Keep this list in step with bootstrap.sh.
    $latin1 = [Text.Encoding]::GetEncoding(28591)    # byte-transparent, for files that are not UTF-8
    foreach ($specDir in @('01-lexical', 'core-syntax', 'core-types')) {
      Say "spec tests: tests/spec/$specDir"
      $dir = Join-Path $Es "tests\spec\$specDir"
      foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.envo' | Sort-Object Name) {
        $name = "spec/$specDir/$($f.Name)"
        $text = [IO.File]::ReadAllText($f.FullName, $latin1)
        $m = [regex]::Match($text, '(?m)^// expect-error: (E\d{4})(?: @ (\d+):(\d+))?')
        if (-not $m.Success) { Bad $name 'no // expect-error: annotation'; continue }
        $code = $m.Groups[1].Value
        $want = "error[$code]"
        if ($m.Groups[2].Success) { $want = "$($f.Name):$($m.Groups[2].Value):$($m.Groups[3].Value): error[$code]" }
        $r = Invoke-Tool $exe @('check', $f.Name) $dir
        if ($r.Err.Contains('(no message for this error code)')) { Bad $name "missing message: $($r.Err.Trim())" }
        elseif ($r.Code -eq 1 -and $r.Err.Contains($want)) { Pass $name }
        else { Bad $name "expected exit 1 with '$want'; got exit $($r.Code), stderr: $($r.Err.Trim())" }
      }
    }

    # Programs compiled and run: `// expect:` stdout lines, `// expect-exit: N`,
    # `// expect-panic: <reason>` (exit 101 and "panic: <reason>" on stderr).
    # Programs compiled and run: by Stage 0, then by Stage 1, which must give the same
    # output and exit codes (M2.7, PLAN D14).
    # Then by Stage 2, whose executables must be byte-identical to Stage 1's (M3.6).
    $stage0Exe = $exe
    foreach ($compiler in @('envoc0', 'envoc1', 'envoc')) {
    if ($compiler -eq 'envoc1') { $exe = Join-Path $Build1 'envoc1.exe' }
    elseif ($compiler -eq 'envoc') { $exe = Join-Path $Build2 'envoc.exe' }
    else { $exe = $stage0Exe }
        $runDir = Join-Path $Root "build\run-$compiler"
        New-Item -ItemType Directory -Force $runDir | Out-Null
        # Envo-S1 programs (tests/spec/s1-run) run under Stages 1 and 2 only.
        $runSuites = @('core-run')
        if ($compiler -ne 'envoc0') { $runSuites += 's1-run' }
        # programs only Stage 2 accepts (tests/spec/s2-run, M3.10)
        if ($compiler -eq 'envoc') { $runSuites += 's2-run' }
        foreach ($suite in $runSuites) {
        Say "run tests ($compiler): tests/spec/$suite"
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $Es "tests\spec\$suite") -Filter '*.envo' | Sort-Object Name) {
            $name = "$compiler spec/$suite/$($f.Name)"
            $text = Normalize ([IO.File]::ReadAllText($f.FullName, $Utf8))
            $lines = @([regex]::Matches($text, '(?m)^// expect: (.*)$') | ForEach-Object { $_.Groups[1].Value })
            $wantOut = ''
            if ($lines.Count -gt 0) { $wantOut = ($lines -join "`n") + "`n" }
            $wantCode = 0
            $m = [regex]::Match($text, '(?m)^// expect-exit: (\d+)')
            if ($m.Success) { $wantCode = [int]$m.Groups[1].Value }
            $panic = [regex]::Match($text, '(?m)^// expect-panic: (.*)$')
            if ($panic.Success) { $wantCode = 101 }
            $program = Join-Path $runDir ($f.BaseName + '.exe')
            $r = Invoke-Tool $exe @('build', $f.FullName, '-o', $program) $runDir
            if ($r.Code -ne 0) { Bad $name "build failed: $($r.Err.Trim())"; continue }
            if ($suite -eq 's2-run') {
                # Stage 1 rejects it, with the code the test names
                $m1 = [regex]::Match($text, '(?m)^// stage1-error: (E\d{4})')
                $r1 = Invoke-Tool (Join-Path $Build1 'envoc1.exe') @('check', $f.FullName) $runDir
                if (-not $m1.Success -or $r1.Code -ne 1 -or -not $r1.Err.Contains("error[$($m1.Groups[1].Value)]")) { Bad $name "envoc1 should reject it with the // stage1-error: code; exit $($r1.Code)"; continue }
            } elseif ($compiler -eq 'envoc') {
                if (-not (Test-SameBytes $program (Join-Path $Root "build\run-envoc1\$(Split-Path -Leaf $program)"))) { Bad $name 'the executable differs from the envoc1 build'; continue }
            }
            if ($compiler -eq 'envoc') {
                $problem = Test-Objects $exe $runDir $program @($f.FullName)
                if ($problem) { Bad $name $problem; continue }
                # the object holds the program's EIR, in the binary form
                $r1 = Invoke-Tool $exe @('eir', $f.FullName) $runDir
                $r2 = Invoke-Tool $exe @('eir-check', "$program.0.eo") $runDir
                if ($r2.Code -ne 0 -or -not [string]::Equals($r1.Out, $r2.Out)) { Bad $name "eir-check of the object differs from eir: exit $($r2.Code)"; continue }
            }
            $r = Invoke-Tool $program @() $runDir
            $out = Normalize $r.Out
            if (-not [string]::Equals($wantOut, $out)) { Bad $name 'stdout differs'; Show-Diff $wantOut $out; continue }
            if ($r.Code -ne $wantCode) { Bad $name "exit code $($r.Code), expected $wantCode; stderr: $($r.Err.Trim())"; continue }
            if ($panic.Success -and -not $r.Err.Contains("panic: $($panic.Groups[1].Value)")) { Bad $name "stderr: $($r.Err.Trim())"; continue }
            if ($compiler -eq 'envoc') {
                # -O2 (M3.8): the same output, exit code and panic
                $fast = Join-Path $runDir ($f.BaseName + '-O2.exe')
                $r = Invoke-Tool $exe @('build', '-O2', $f.FullName, '-o', $fast) $runDir
                if ($r.Code -ne 0) { Bad $name "-O2 build failed: $($r.Err.Trim())"; continue }
                $r = Invoke-Tool $fast @() $runDir
                if (-not [string]::Equals($wantOut, (Normalize $r.Out)) -or $r.Code -ne $wantCode) { Bad $name "-O2: stdout or exit code ($($r.Code)) differs"; continue }
                if ($panic.Success -and -not $r.Err.Contains("panic: $($panic.Groups[1].Value)")) { Bad $name "-O2 stderr: $($r.Err.Trim())"; continue }
            }
            Pass $name
        }
        }

        # Multi-file programs: one folder per test. main.envo is the entry file and holds
        # the annotations; the other .envo files follow in name order. Either
        # `// expect-error: E#### @ <file>:L:C` (envoc0 check) or `// expect:` lines (build, run).
        # Envo-S1 programs of several files (tests/spec/s1-multi) under Stages 1 and 2 only.
        $multiSuites = @('core-multi')
        if ($compiler -ne 'envoc0') { $multiSuites += 's1-multi' }
        foreach ($msuite in $multiSuites) {
        Say "multi-file tests ($compiler): tests/spec/$msuite"
        foreach ($d in Get-ChildItem -LiteralPath (Join-Path $Es "tests\spec\$msuite") -Directory | Sort-Object Name) {
            $name = "$compiler spec/$msuite/$($d.Name)"
            $files = @('main.envo') + @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.envo' | Where-Object { $_.Name -ne 'main.envo' } | Sort-Object Name | ForEach-Object { $_.Name })
            $text = Normalize ([IO.File]::ReadAllText((Join-Path $d.FullName 'main.envo'), $Utf8))
            $m = [regex]::Match($text, '(?m)^// expect-error: (E\d{4}) @ (\S+)$')
            if ($m.Success) {
                $want = "$($m.Groups[2].Value): error[$($m.Groups[1].Value)]"
                $r = Invoke-Tool $exe (@('check') + $files) $d.FullName
                if ($r.Code -eq 1 -and $r.Err.Contains($want)) { Pass $name }
                else { Bad $name "expected exit 1 with '$want'; got exit $($r.Code), stderr: $($r.Err.Trim())" }
                continue
            }
            $lines = @([regex]::Matches($text, '(?m)^// expect: (.*)$') | ForEach-Object { $_.Groups[1].Value })
            $wantOut = ''
            if ($lines.Count -gt 0) { $wantOut = ($lines -join "`n") + "`n" }
            $program = Join-Path $runDir ("$msuite-" + $d.Name + '.exe')
            $r = Invoke-Tool $exe (@('build') + $files + @('-o', $program)) $d.FullName
            if ($r.Code -ne 0) { Bad $name "build failed: $($r.Err.Trim())"; continue }
            if ($compiler -eq 'envoc') {
                if (-not (Test-SameBytes $program (Join-Path $Root "build\run-envoc1\$(Split-Path -Leaf $program)"))) { Bad $name 'the executable differs from the envoc1 build'; continue }
                $problem = Test-Objects $exe $d.FullName $program $files
                if ($problem) { Bad $name $problem; continue }
            }
            $r = Invoke-Tool $program @() $runDir
            $out = Normalize $r.Out
            if (-not [string]::Equals($wantOut, $out)) { Bad $name 'stdout differs'; Show-Diff $wantOut $out; continue }
            if ($r.Code -ne 0) { Bad $name "exit code $($r.Code); stderr: $($r.Err.Trim())"; continue }
            if ($compiler -eq 'envoc') {
                $fast = Join-Path $runDir ("$msuite-" + $d.Name + '-O2.exe')
                $r = Invoke-Tool $exe (@('build', '-O2') + $files + @('-o', $fast)) $d.FullName
                if ($r.Code -ne 0) { Bad $name "-O2 build failed: $($r.Err.Trim())"; continue }
                $r = Invoke-Tool $fast @() $runDir
                if (-not [string]::Equals($wantOut, (Normalize $r.Out)) -or $r.Code -ne 0) { Bad $name "-O2: stdout or exit code ($($r.Code)) differs"; continue }
            }
            Pass $name
        }
        }
    }
    $exe = $stage0Exe

    Say ''
    Say 'stage 1 smoke tests'
    $envoc1 = Join-Path $Build1 'envoc1.exe'
    $r = Invoke-Tool $envoc1 @('version') $Root
    if ($r.Code -eq 0 -and $r.Out.StartsWith('envoc1 ')) { Pass 'envoc1 version' } else { Bad 'envoc1 version' "exit $($r.Code), stdout: $($r.Out)" }
    $r = Invoke-Tool $envoc1 @('selftest') $Root
    if ($r.Code -eq 0 -and $r.Out.StartsWith('selftest: ok')) { Pass 'envoc1 selftest' } else { Bad 'envoc1 selftest' "exit $($r.Code), output: $($r.Out)$($r.Err)" }
    $r = Invoke-Tool $envoc1 @() $Root
    if ($r.Code -eq 2 -and $r.Err.StartsWith('usage: envoc1')) { Pass 'envoc1 no arguments' } else { Bad 'envoc1 no arguments' "exit $($r.Code), stderr: $($r.Err)" }
    $r = Invoke-Tool $envoc1 @('frobnicate') $Root
    if ($r.Code -eq 2 -and $r.Err.StartsWith("envoc1: error: unknown command 'frobnicate'")) { Pass 'envoc1 unknown command' } else { Bad 'envoc1 unknown command' "exit $($r.Code), stderr: $($r.Err)" }

    # The runtime embedded in envoc1 must be generated from the current runtime sources.
    $r = Invoke-Tool $envoc1 @('embed', 'runtime/common.envo', 'runtime/linux.envo', 'runtime/windows.envo', 'prelude/prelude.envo') $Stage1
    $expected = Normalize ([IO.File]::ReadAllText((Join-Path $Stage1 'runtime\embedded.envo'), $Utf8))
    if ($r.Code -eq 0 -and [string]::Equals($expected, (Normalize $r.Out))) { Pass 'envoc1 embedded runtime' }
    else { Bad 'envoc1 embedded runtime' 'stage1/runtime/embedded.envo is stale: regenerate it with envoc1 embed (see docs/stage1.md)' }

    # The x86-64 encoder and image writer: a minimal native program must exit with 42.
    $t42 = Join-Path $tmp 't42.exe'
    $r = Invoke-Tool $envoc1 @('selftest-image', $t42, 'windows') $Root
    if ($r.Code -eq 0) {
        $r = Invoke-Tool $t42 @() $Root
        if ($r.Code -eq 42) { Pass 'envoc1 selftest-image' } else { Bad 'envoc1 selftest-image' "exit $($r.Code), expected 42" }
    } else { Bad 'envoc1 selftest-image' "exit $($r.Code), stderr: $($r.Err)" }

    # Differential tests (PLAN D14). Golden suites: envoc1 must print exactly envoc0's
    # expected files, in --core mode and in Envo-S1 mode (Core programs mean the same in
    # S1). Spec suites: the same error code at the same position; lexical tests run in
    # both modes (E0901-E0904 become E0950 in S1), syntax tests in --core mode.
    # Keep these lists in step with bootstrap.sh.
    $stage1Golden = @(
        @{ Dir = 'lexer';  Command = 'lex';   Ext = '.tokens' },
        @{ Dir = 'parser'; Command = 'parse'; Ext = '.ast' },
        @{ Dir = 'check';  Command = 'check'; Ext = '.check' },
        @{ Dir = 's1-parser'; Command = 'parse'; Ext = '.ast'; Modes = @('s1') }
    )
    foreach ($suite in $stage1Golden) {
      $modes = @('--core', 's1')
      if ($suite.Modes) { $modes = $suite.Modes }
      foreach ($mode in $modes) {
        $pre = @()
        if ($mode -eq '--core') { $pre = @('--core') }
        Say "stage 1 golden tests ($mode): tests/golden/$($suite.Dir)"
        $dir = Join-Path $Es "tests\golden\$($suite.Dir)"
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.envo' | Sort-Object Name) {
            $name = "stage1 $mode golden/$($suite.Dir)/$($f.Name)"
            $r = Invoke-Tool $envoc1 ($pre + @($suite.Command, $f.Name)) $dir
            if ($r.Code -ne 0) { Bad $name "exit $($r.Code), stderr: $($r.Err.Trim())"; continue }
            $expected = Normalize ([IO.File]::ReadAllText(($f.FullName -replace '\.envo$', $suite.Ext), $Utf8))
            $actual = Normalize $r.Out
            if ([string]::Equals($expected, $actual)) { Pass $name } else { Bad $name 'output differs'; Show-Diff $expected $actual }
        }
      }
    }
    $stage1Spec = @(
        @{ Dir = '01-lexical';  Command = 'lex';   Modes = @('--core', 's1') },
        @{ Dir = 'core-syntax'; Command = 'parse'; Modes = @('--core') },
        @{ Dir = 'core-types';  Command = 'check'; Modes = @('--core') },
        @{ Dir = 's1-syntax';   Command = 'parse'; Modes = @('s1') },
        @{ Dir = 's1-types';    Command = 'check'; Modes = @('s1') },
        @{ Dir = 's1-own';      Command = 'check'; Modes = @('s1') }
    )
    foreach ($suite in $stage1Spec) {
      foreach ($mode in $suite.Modes) {
        $pre = @()
        if ($mode -eq '--core') { $pre = @('--core') }
        Say "stage 1 spec tests ($mode): tests/spec/$($suite.Dir)"
        $dir = Join-Path $Es "tests\spec\$($suite.Dir)"
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.envo' | Sort-Object Name) {
            $name = "stage1 $mode spec/$($suite.Dir)/$($f.Name)"
            $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($f.FullName))
            $m = [regex]::Match($text, '(?m)^// expect-error: (E\d{4}) @ (\d+:\d+)')
            if (-not $m.Success) { Bad $name 'no // expect-error: annotation with a position'; continue }
            $code = $m.Groups[1].Value
            if ($mode -eq 's1' -and $code -match '^E090[1-4]$') { $code = 'E0950' }
            $want = "$($f.Name):$($m.Groups[2].Value): error[$code]"
            $r = Invoke-Tool $envoc1 ($pre + @($suite.Command, $f.Name)) $dir
            if ($r.Code -eq 1 -and $r.Err.Contains($want)) { Pass $name }
            else { Bad $name "expected exit 1 with '$want'; got exit $($r.Code), stderr: $($r.Err.Trim())" }
        }
      }
    }
    # Multi-file error tests, and Stage 1 checking its own source (D14).
    Say 'stage 1 multi-file tests (--core): tests/spec/core-multi'
    foreach ($d in Get-ChildItem -LiteralPath (Join-Path $Es 'tests\spec\core-multi') -Directory | Sort-Object Name) {
        $main = Join-Path $d.FullName 'main.envo'
        $m = [regex]::Match([IO.File]::ReadAllText($main, $Utf8), '(?m)^// expect-error: (E\d{4}) @ (\S+)')
        if (-not $m.Success) { continue }
        $files = @('main.envo') + @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.envo' | Where-Object { $_.Name -ne 'main.envo' } | Sort-Object Name | ForEach-Object { $_.Name })
        $want = "$($m.Groups[2].Value): error[$($m.Groups[1].Value)]"
        $r = Invoke-Tool $envoc1 (@('--core', 'check') + $files) $d.FullName
        if ($r.Code -eq 1 -and $r.Err.Contains($want)) { Pass $d.Name }
        else { Bad "stage1 --core core-multi/$($d.Name)" "expected exit 1 with '$want'; got exit $($r.Code), stderr: $($r.Err.Trim())" }
    }
    # EIR v1 (M2.6): canonical printing round-trips, and verifier errors.
    Say 'stage 1 golden tests: tests/golden/eir'
    $dir = Join-Path $Es 'tests\golden\eir'
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.eir' | Sort-Object Name) {
        $expected = Normalize ([IO.File]::ReadAllText(($f.FullName -replace '\.eir$', '.out'), $Utf8))
        foreach ($input in @($f.Name, ($f.Name -replace '\.eir$', '.out'))) {
            $r = Invoke-Tool $envoc1 @('eir-check', $input) $dir
            $actual = Normalize $r.Out
            if ($r.Code -eq 0 -and [string]::Equals($expected, $actual)) { Pass $input }
            else { Bad "golden/eir/$input" "exit $($r.Code), stderr: $($r.Err.Trim())"; Show-Diff $expected $actual }
        }
    }
    Say 'stage 1 spec tests: tests/spec/eir'
    $dir = Join-Path $Es 'tests\spec\eir'
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.eir' | Sort-Object Name) {
        $m = [regex]::Match([IO.File]::ReadAllText($f.FullName, $Utf8), '(?m)^; expect-error: (E\d{4}) @ (\d+:\d+)')
        if (-not $m.Success) { Bad "spec/eir/$($f.Name)" 'no ; expect-error: annotation'; continue }
        $want = "$($f.Name):$($m.Groups[2].Value): error[$($m.Groups[1].Value)]"
        $r = Invoke-Tool $envoc1 @('eir-check', $f.Name) $dir
        if ($r.Code -eq 1 -and $r.Err.Contains($want)) { Pass $f.Name }
        else { Bad "spec/eir/$($f.Name)" "expected exit 1 with '$want'; got exit $($r.Code), stderr: $($r.Err.Trim())" }
    }
    Say 'stage 1 self-check: envoc1 --core check stage1'
    $files = @(Get-Content -LiteralPath (Join-Path $Stage1 'files.txt') | Where-Object { $_.Trim() -ne '' })
    $r = Invoke-Tool $envoc1 (@('--core', 'check') + $files) $Stage1
    if ($r.Code -eq 0) { Pass 'stage1 self-check' } else { Bad 'stage1 self-check' "exit $($r.Code), stderr: $($r.Err.Trim())" }


    Say ''
    Say 'stage 2: built by stage 1, it must behave as it does built by itself'
    $envoc = Join-Path $Build2 'envoc.exe'
    Say 'stage 2 against envoc1: lex and parse on every .envo file in compiler/, bootstrap/stage1/, tests/; check on the run programs and goldens; eir on the run programs'
    $sources = @((Join-Path $Es 'compiler'), $Stage1, (Join-Path $Es 'tests')) | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Filter '*.envo' -Recurse -File
    } | Sort-Object FullName
    foreach ($f in $sources) {
        $cmds = @('lex', 'parse')
        $base = $Es
        if ($f.FullName.StartsWith($Root + '\stage1')) { $base = $Root }
        $rel = $f.FullName.Substring($base.Length + 1)
        if ($rel -match '^tests\\golden\\') { $cmds = @('lex', 'parse', 'check') }
        if ($rel -match '^tests\\spec\\(core|s1)-run\\') { $cmds = @('lex', 'parse', 'check', 'eir') }
        # a program Stage 1 cannot parse (E0950, such as floats: RFC 0006) is compared as tokens
        if ([IO.File]::ReadAllText($f.FullName) -match '(?m)^// stage1-error: E0950') { $cmds = @('lex') }
        foreach ($cmd in $cmds) {
            $r1 = Invoke-Tool $envoc1 @($cmd, $f.Name) $f.DirectoryName
            $r2 = Invoke-Tool $envoc @($cmd, $f.Name) $f.DirectoryName
            if ($r1.Code -eq $r2.Code -and [string]::Equals($r1.Out, $r2.Out) -and [string]::Equals($r1.Err, $r2.Err)) { Pass $f.Name }
            else { Bad "stage2 $cmd $rel" "differs from envoc1 (exit $($r1.Code) vs $($r2.Code))" }
        }
    }
    foreach ($unit in @(@{ Dir = 'stage1'; Pre = @('--core', 'check') }, @{ Dir = 'compiler'; Pre = @('check') },
                        @{ Dir = 'stage1'; Pre = @('--core', 'eir') }, @{ Dir = 'compiler'; Pre = @('eir') })) {
        $dir = $Stage2
        if ($unit.Dir -eq 'stage1') { $dir = $Stage1 }
        $files = @(Get-Content -LiteralPath (Join-Path $dir 'files.txt') | Where-Object { $_.Trim() -ne '' })
        $r1 = Invoke-Tool $envoc1 ($unit.Pre + $files) $dir
        $r2 = Invoke-Tool $envoc ($unit.Pre + $files) $dir
        $what = "stage2 $($unit.Pre[-1]) $($unit.Dir)"
        if ($r1.Code -eq $r2.Code -and [string]::Equals($r1.Out, $r2.Out) -and [string]::Equals($r1.Err, $r2.Err)) { Pass $what }
        else { Bad $what "differs from envoc1 (exit $($r1.Code) vs $($r2.Code))" }
    }
    # Stage 2 builds Stage 1 as envoc1 does, and builds itself into the envoc that envoc1
    # built, for both targets (M3.6).
    $selfDir = Join-Path $Root 'build\run-envoc'
    foreach ($unit in @(@{ Dir = 'stage1'; Pre = @('--core', 'build'); Target = 'x86_64-windows' },
                        @{ Dir = 'compiler'; Pre = @('build'); Target = 'x86_64-windows' },
                        @{ Dir = 'compiler'; Pre = @('build'); Target = 'x86_64-linux' })) {
        $dir = $Stage2
        if ($unit.Dir -eq 'stage1') { $dir = $Stage1 }
        $files = @(Get-Content -LiteralPath (Join-Path $dir 'files.txt') | Where-Object { $_.Trim() -ne '' })
        $what = "stage2 build $($unit.Dir) ($($unit.Target))"
        if ($unit.Dir -eq 'compiler') {
            $want = Join-Path $Build2 'envoc'
            if ($unit.Target -eq 'x86_64-windows') { $want = Join-Path $Build2 'envoc.exe' }
        } else {
            $want = Join-Path $selfDir 'self-stage1-envoc1'
            $r = Invoke-Tool $envoc1 ($unit.Pre + $files + @('-o', $want, '--target', $unit.Target)) $dir
            if ($r.Code -ne 0) { Bad $what "envoc1 failed: exit $($r.Code)"; continue }
        }
        $self = Join-Path $selfDir "self-$($unit.Target)"
        $r = Invoke-Tool $envoc ($unit.Pre + $files + @('-o', $self, '--target', $unit.Target)) $dir
        if ($r.Code -eq 0 -and (Test-SameBytes $want $self)) { Pass $what }
        else { Bad $what "exit $($r.Code), or the executable differs from envoc1's" }
    }
    # Stage 2 at -O2 (M3.8): it builds Stage 2 into the same bytes as envoc1's build at
    # -O0, and into itself at -O2
    $dir = $Stage2
    $files = @(Get-Content -LiteralPath (Join-Path $dir 'files.txt') | Where-Object { $_.Trim() -ne '' })
    $fast = Join-Path $selfDir 'envoc-O2.exe'
    $byFast = Join-Path $selfDir 'by-O2.exe'
    $byFast2 = Join-Path $selfDir 'by-O2-O2.exe'
    $r = Invoke-Tool $envoc (@('build', '-O2') + $files + @('-o', $fast)) $dir
    if ($r.Code -eq 0) { $r = Invoke-Tool $fast (@('build') + $files + @('-o', $byFast)) $dir }
    if ($r.Code -eq 0) { $r = Invoke-Tool $fast (@('build', '-O2') + $files + @('-o', $byFast2)) $dir }
    if ($r.Code -eq 0 -and (Test-SameBytes $byFast (Join-Path $Build2 'envoc.exe')) -and (Test-SameBytes $fast $byFast2)) { Pass 'stage2 -O2 self-build' }
    else { Bad 'stage2 -O2 self-build' "exit $($r.Code), or the -O2 compiler's output differs" }
    # Stage 2 through an object of itself (M3.7), and link errors
    $dir = $Stage2
    $files = @(Get-Content -LiteralPath (Join-Path $dir 'files.txt') | Where-Object { $_.Trim() -ne '' })
    $obj = Join-Path $selfDir 'self.eo'
    $linked = Join-Path $selfDir 'self-linked.exe'
    $r = Invoke-Tool $envoc (@('compile') + $files + @('-o', $obj)) $dir
    if ($r.Code -eq 0) { $r = Invoke-Tool $envoc @('link', $obj, '-o', $linked) $dir }
    if ($r.Code -eq 0 -and (Test-SameBytes $linked (Join-Path $Build2 'envoc.exe'))) { Pass 'stage2 compile and link compiler' }
    else { Bad 'stage2 compile and link compiler' "exit $($r.Code), or the executable differs from build\stage2" }
    $none = Join-Path $selfDir 'none.exe'
    $r = Invoke-Tool $envoc @('link', (Join-Path $selfDir 'core-multi-program.exe.0.eo'), '-o', $none) $Root
    if ($r.Code -eq 1 -and $r.Err.Contains('no object defines @')) { Pass 'stage2 link with a unit missing' } else { Bad 'stage2 link with a unit missing' "exit $($r.Code): $($r.Err)" }
    $r = Invoke-Tool $envoc @('link', (Join-Path $selfDir 'core-multi-program.exe.0.eo'), (Join-Path $selfDir 's1-multi-namespaces.exe.0.eo'), '-o', $none) $Root
    if ($r.Code -eq 1 -and $r.Err.Contains('compiled from different programs')) { Pass 'stage2 link of two programs' } else { Bad 'stage2 link of two programs' "exit $($r.Code): $($r.Err)" }
    $v2 = Join-Path $selfDir 'v2.eo'
    [IO.File]::WriteAllBytes($v2, [byte[]](0x45, 0x49, 0x52, 0, 2, 0))
    $r = Invoke-Tool $envoc @('link', $v2, '-o', $none) $Root
    if ($r.Code -eq 1 -and $r.Err.Contains('binary EIR version 2; this envoc reads version 1')) { Pass 'stage2 link of an unknown version' } else { Bad 'stage2 link of an unknown version' "exit $($r.Code): $($r.Err)" }

    Say ''
    Say "$($script:passed) passed, $($script:failed) failed"
    if ($script:failed -gt 0) { exit 1 }
}

# ------------------------------------------------------------------- check
function Invoke-Check {
    $problems = New-Object System.Collections.Generic.List[string]
    # docs/eas.md: every jump states its size, so the bytes depend on the source alone.
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $Root '.') -Recurse -Filter '*.eas' | Where-Object { $_.FullName -notmatch '\\(build|envoscale)\\' }) {
        $hits = Select-String -LiteralPath $f.FullName -CaseSensitive -Pattern '^\s*j[a-z]+\s+[.A-Za-z_]' |
            Where-Object { $_.Line -notmatch '^\s*j[a-z]+\s+((short|near)\s|r[a-z0-9]+\s*(;|$))' }
        foreach ($h in $hits) { $problems.Add("jump without short/near: $($f.FullName.Substring($Root.Length + 1)):$($h.LineNumber)") }
    }
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { [Console]::Error.WriteLine("check: $p") }
        Fail "$($problems.Count) problem(s)"
    }
    Say 'check: ok'
}

# ------------------------------------------------------------------- seed
# The compilers EnvoScale builds itself from (its build scripts download them from this
# repository's releases): the fixed-point compilers, named by target, with SHA256SUMS.
function Invoke-Seed {
    Invoke-FixedPoint
    $rel = Join-Path $Root 'build\seed-release'
    if (Test-Path -LiteralPath $rel) { Remove-Item -Recurse -Force $rel }
    New-Item -ItemType Directory -Force $rel | Out-Null
    Copy-Item (Join-Path $Root 'build\stage2c\envoc') (Join-Path $rel 'envoc-x86_64-linux')
    Copy-Item (Join-Path $Root 'build\stage2c\envoc.exe') (Join-Path $rel 'envoc-x86_64-windows.exe')
    $lines = foreach ($f in Get-ChildItem -LiteralPath $rel -Filter 'envoc-*' | Sort-Object Name) {
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant())  $($f.Name)"
    }
    [IO.File]::WriteAllText((Join-Path $rel 'SHA256SUMS'), (($lines -join "`n") + "`n"), $Utf8)
    Say 'seed      build\seed-release'
    Get-Content -LiteralPath (Join-Path $rel 'SHA256SUMS')
}

switch ($Command) {
    'build' { Invoke-Build }
    'test'  { Invoke-Test }
    'fixedpoint' { Invoke-FixedPoint }
    'seed'  { Invoke-Seed }
    'check' { Invoke-Check }
    'clean' { if (Test-Path -LiteralPath (Join-Path $Root 'build')) { Remove-Item -Recurse -Force (Join-Path $Root 'build') }; Say 'removed build/' }
    default {
        Say 'usage: .\bootstrap.ps1 <build|test|fixedpoint|seed|check|clean>'
        if ($Command -ne 'help') { exit 2 }
    }
}
