#!/bin/sh
# EnvoScaleAsm: builds the EnvoL compiler up from assembly, for Linux and Windows
# (Git Bash). bootstrap.ps1 is the Windows PowerShell twin; keep the two in step.
#
#   ./bootstrap.sh build       stage 0 from assembly (NASM, or the hex seed without it),
#                              stage 1 with it, then the EnvoScale compiler with stage 1
#   ./bootstrap.sh test        build, then the stage 0 and stage 1 tests, and check that
#                              the compiler built by stage 1 behaves as it does built by itself
#   ./bootstrap.sh fixedpoint  build, then the compiler by itself twice at -O2; both must match
#   ./bootstrap.sh seed        fixedpoint, then the seed compilers in build/seed-release
#   ./bootstrap.sh compare <a> <b>   two builds (copies of build/) must be byte-identical
#   ./bootstrap.sh check       every jump in the .eas sources states its size
#   ./bootstrap.sh clean
#
# The compiler's sources come from EnvoLang at the commit in envolang.ref: from
# $ENVOLANG if set, else ./envolang, cloned on first use.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD="$ROOT/build/stage0"
BUILD1="$ROOT/build/stage1"
BUILD2="$ROOT/build/stage2"
STAGE0="$ROOT/stage0"
STAGE1="$ROOT/stage1"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# envolang: the EnvoLang checkout the compiler is built from, at envolang.ref.
envolang() {
    ref=$(tr -d '\r\n ' < "$ROOT/envolang.ref")
    if [ -n "${ENVOLANG:-}" ]; then
        ES=$(cd "$ENVOLANG" && pwd)
    else
        ES="$ROOT/envolang"
        if [ ! -d "$ES/.git" ]; then
            say "clone     https://github.com/envoscale/EnvoLang -> envolang/"
            git clone -q https://github.com/envoscale/EnvoLang "$ES" || fail 'cloning EnvoLang failed'
        fi
        if [ "$(git -C "$ES" rev-parse HEAD)" != "$ref" ]; then
            git -C "$ES" fetch -q origin || true
            git -C "$ES" -c advice.detachedHead=false checkout -q "$ref" || fail "envolang/: cannot check out $ref"
        fi
    fi
    STAGE2="$ES/compiler"
}
envolang

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else echo "(no sha256 tool)"; fi
}

# host_suffix: "" on Linux, ".exe" on Windows; the native binaries' file suffix.
host_suffix() {
    case "$(uname -s)" in
        Linux) printf '' ;;
        MINGW*|MSYS*|CYGWIN*) printf '.exe' ;;
        *) fail "no native Stage 0 for $(uname -s) yet (supported: Linux, Windows); see EnvoScale/porting/CHECKLIST.md" ;;
    esac
}

# ------------------------------------------------------------------- build
# seed_asm0: asm0, the seed assembler (seed/), made from its hex with
# the OS's own tools; prints its path.
seed_asm0() {
    case "$(host_suffix)" in .exe) seed_os=windows ;; *) seed_os=linux ;; esac
    mkdir -p "$ROOT/build/seed"
    seed_bin="$ROOT/build/seed/asm0$(host_suffix)"
    sh "$ROOT/seed/hex2bin.sh" "$ROOT/seed/seed-$seed_os.hex" "$seed_bin" \
        || fail "hex2bin: seed/seed-$seed_os.hex"
    chmod +x "$seed_bin"
    printf '%s' "$seed_bin"
}

do_build() {
    mkdir -p "$BUILD"
    for unit in "envoc0-linux.eas:envoc0" "envoc0-windows.eas:envoc0.exe"; do
        src=${unit%%:*}
        out=${unit#*:}
        say "assemble  stage0/$src -> build/stage0/$out"
        set +e
        sh "$ROOT/nasm/assemble.sh" "$STAGE0/$src" "$BUILD/$out" "$STAGE0" 2> "$BUILD/assemble.err"
        arc=$?
        set -e
        if [ "$arc" -eq 127 ]; then
            # no NASM: the seed assembles Stage 0 to the same bytes (Phase B)
            say "          NASM not found: assembling with the seed (seed/)"
            seed_tool=$(seed_asm0)
            "$seed_tool" "$STAGE0/$src" "$BUILD/$out" || fail "assembling $src with the seed failed"
        elif [ "$arc" -ne 0 ]; then
            cat "$BUILD/assemble.err" >&2
            fail "assembling $src failed"
        fi
        size=$(wc -c < "$BUILD/$out" | tr -d ' ')
        say "          $size bytes  sha256 $(sha256 "$BUILD/$out")"
    done
    chmod +x "$BUILD/envoc0"

    # Stage 1 is an Envo-Core program (PLAN D11); the native envoc0 builds it for both OSes.
    mkdir -p "$BUILD1"
    envoc0="$BUILD/envoc0$(host_suffix)"
    set --
    while IFS= read -r f || [ -n "$f" ]; do
        f=$(printf '%s' "$f" | tr -d '\r')
        [ -n "$f" ] && set -- "$@" "$f"
    done < "$STAGE1/files.txt"
    for unit in "x86_64-linux:envoc1" "x86_64-windows:envoc1.exe"; do
        target=${unit%%:*}
        out=${unit#*:}
        say "build     stage1 -> build/stage1/$out"
        (cd "$STAGE1" && "$envoc0" build "$@" -o "$BUILD1/$out" --target "$target") \
            || fail "building Stage 1 ($target) failed"
        size=$(wc -c < "$BUILD1/$out" | tr -d ' ')
        say "          $size bytes  sha256 $(sha256 "$BUILD1/$out")"
    done
    chmod +x "$BUILD1/envoc1"

    # Stage 2 is an Envo-S1 program (PLAN D16); the native envoc1 builds it for both OSes.
    mkdir -p "$BUILD2"
    envoc1="$BUILD1/envoc1$(host_suffix)"
    set --
    while IFS= read -r f || [ -n "$f" ]; do
        f=$(printf '%s' "$f" | tr -d '\r')
        [ -n "$f" ] && set -- "$@" "$f"
    done < "$STAGE2/files.txt"
    for unit in "x86_64-linux:envoc" "x86_64-windows:envoc.exe"; do
        target=${unit%%:*}
        out=${unit#*:}
        say "build     envolang/compiler -> build/stage2/$out"
        (cd "$STAGE2" && "$envoc1" build "$@" -o "$BUILD2/$out" --target "$target") \
            || fail "building Stage 2 ($target) failed"
        size=$(wc -c < "$BUILD2/$out" | tr -d ' ')
        say "          $size bytes  sha256 $(sha256 "$BUILD2/$out")"
    done
    chmod +x "$BUILD2/envoc"
}
# ------------------------------------------------------------------- test
passed=0
failed=0
pass() { passed=$((passed + 1)); }
bad() { failed=$((failed + 1)); say "FAIL  $1"; [ -n "${2:-}" ] && say "      $2"; return 0; }

# run <dir> <args...>: runs the native envoc0 in <dir>; sets rc, and leaves
# stdout/stderr in $TMP/out and $TMP/err.
# Stage 2 only (M3.7): compiles each of the files to an object (--unit), links the objects
# and prints a problem unless the result is the executable `build` wrote. $1: the
# directory, $2: that executable, then the files.
objects() {
    odir=$1
    oprog=$2
    shift 2
    rm -f "$oprog".*.eo
    k=0
    for u in "$@"; do
        run "$odir" compile "$@" --unit "$u" -o "$oprog.$k.eo"
        if [ "$rc" -ne 0 ]; then echo "compile --unit $u failed: $(cat "$TMP/err")"; return; fi
        k=$((k + 1))
    done
    run "$odir" link "$oprog".*.eo -o "$oprog.linked"
    if [ "$rc" -ne 0 ]; then echo "link failed: $(cat "$TMP/err")"; return; fi
    if ! cmp -s "$oprog" "$oprog.linked"; then echo 'the linked executable differs from the build'; fi
}

run() {
    dir=$1; shift
    set +e
    (cd "$dir" && "$EXE" "$@") > "$TMP/out" 2> "$TMP/err"
    rc=$?
    set -e
}

do_test() {
    do_build
    EXE="$BUILD/envoc0$(host_suffix)"
    ENVOC1="$BUILD1/envoc1$(host_suffix)"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    # Hardening (PLAN D68): Stage 1 and Stage 2 executables keep code and data apart (W^X)
    # and can be loaded anywhere (ASLR): Linux ET_DYN with an R+X and an R+W segment;
    # Windows with DYNAMIC_BASE and HIGH_ENTROPY_VA and no section both writable and executable
    say ''
    say 'hardening: W^X and ASLR in the executables of Stages 1 and 2'
    u8at() { od -An -t u1 -j "$2" -N 1 "$1" | tr -d ' '; }
    u16at() { echo $(( $(u8at "$1" "$2") + 256 * $(u8at "$1" $(($2 + 1))) )); }
    u32at() { echo $(( $(u16at "$1" "$2") + 65536 * $(u16at "$1" $(($2 + 2))) )); }
    h_hsrc="$ES/tests/spec/core-run/$(ls "$ES/tests/spec/core-run" | head -n 1)"
    for h_comp in "$BUILD1/envoc1$(host_suffix)" "$BUILD2/envoc$(host_suffix)"; do
        set +e
        "$h_comp" build "$h_hsrc" -o "$TMP/h-linux" --target x86_64-linux > /dev/null 2>&1
        "$h_comp" build "$h_hsrc" -o "$TMP/h-win.exe" --target x86_64-windows > /dev/null 2>&1
        set -e
        h_et=$(u16at "$TMP/h-linux" 16)
        h_f0=$(u32at "$TMP/h-linux" 68)
        h_f1=$(u32at "$TMP/h-linux" 124)
        if [ "$h_et" -eq 3 ] && [ "$h_f0" -eq 5 ] && [ "$h_f1" -eq 6 ]; then pass; else bad "hardening: ELF from ${h_comp##*/}" "e_type $h_et, segment flags $h_f0 and $h_f1"; fi
        h_pe=$(u32at "$TMP/h-win.exe" 60)
        h_dll=$(u16at "$TMP/h-win.exe" $((h_pe + 94)))
        h_ns=$(u16at "$TMP/h-win.exe" $((h_pe + 6)))
        h_wx=0
        h_i=0
        while [ "$h_i" -lt "$h_ns" ]; do
            h_c=$(u32at "$TMP/h-win.exe" $((0x16C + 40 * h_i)))
            if [ $((h_c & 0x20000000)) -ne 0 ] && [ $((h_c & 0x80000000)) -ne 0 ]; then h_wx=1; fi
            h_i=$((h_i + 1))
        done
        if [ $((h_dll & 0x60)) -eq 96 ] && [ "$h_ns" -ge 2 ] && [ "$h_wx" -eq 0 ]; then pass; else bad "hardening: PE from ${h_comp##*/}" "DllCharacteristics $h_dll, $h_ns sections, writable code: $h_wx"; fi
    done

    # Phase B (PLAN D67): asm0 made from the hex seed with the OS's own tools assembles
    # itself, the other OS's asm0 and Stage 0 to exactly the bytes NASM gives
    say ''
    say 'seed: asm0 from seed/*.hex assembles itself, the other asm0 and Stage 0 byte for byte'
    seed_tool=$(seed_asm0)
    for other in linux windows; do
        sh "$ROOT/seed/hex2bin.sh" "$ROOT/seed/seed-$other.hex" "$TMP/asm0-$other.hex.bin"
        set +e
        "$seed_tool" "$ROOT/seed/asm0-$other.eas" "$TMP/asm0-$other.built" 2> "$TMP/err"
        rc=$?
        set -e
        if [ "$rc" -eq 0 ] && cmp -s "$TMP/asm0-$other.hex.bin" "$TMP/asm0-$other.built"; then pass; else bad "seed: asm0-$other.eas" "exit $rc: $(cat "$TMP/err")"; fi
    done
    for unit in "envoc0-linux.eas:envoc0" "envoc0-windows.eas:envoc0.exe"; do
        src=${unit%%:*}
        out=${unit#*:}
        set +e
        "$seed_tool" "$STAGE0/$src" "$TMP/$out.seed" 2> "$TMP/err"
        rc=$?
        set -e
        if [ "$rc" -eq 0 ] && cmp -s "$BUILD/$out" "$TMP/$out.seed"; then pass; else bad "seed: $src" "exit $rc: $(cat "$TMP/err")"; fi
    done

    say ''
    say 'smoke tests'
    run "$ROOT" version
    if [ "$rc" -eq 0 ] && grep -q '^envoc0 ' "$TMP/out"; then pass; else bad version "exit $rc"; fi
    run "$ROOT"
    if [ "$rc" -eq 2 ] && grep -q '^usage: envoc0' "$TMP/err"; then pass; else bad 'no arguments' "exit $rc"; fi
    run "$ROOT" frobnicate
    if [ "$rc" -eq 2 ] && grep -q "^envoc0: error: unknown command 'frobnicate'" "$TMP/err"; then pass; else bad 'unknown command' "exit $rc"; fi
    run "$ROOT" lex 'no such file.envol'
    if [ "$rc" -eq 1 ] && grep -q "^envoc0: error: cannot open 'no such file.envol'" "$TMP/err"; then pass; else bad 'missing file' "exit $rc"; fi
    # Paths are UTF-8 on every OS: a name with a space, a Latin, a CJK and a non-BMP character.
    uname=$(printf 'u\303\274nicode \346\227\245\360\237\230\200.envol')
    printf 'print("hi")\n' > "$TMP/$uname"
    run "$TMP" lex "$uname"
    if [ "$rc" -eq 0 ] && head -n 1 "$TMP/out" | grep -q '^1:1 n ident print'; then pass; else bad 'unicode path' "exit $rc: $(cat "$TMP/err")"; fi
    # Cross-compilation: this host builds the other OS's executable (it can only check the header).
    printf 'print("hi")
' > "$TMP/cross.envol"
    case "$EXE" in
        *.exe) other=x86_64-linux; magic='7f454c46' ;;
        *) other=x86_64-windows; magic='4d5a' ;;
    esac
    run "$TMP" build cross.envol -o cross-out --target "$other"
    got=$(od -A n -t x1 -N 4 "$TMP/cross-out" 2>/dev/null | tr -d ' \n')
    case "$got" in "$magic"*) pass ;; *) bad "cross build ($other)" "exit $rc, header $got" ;; esac

    # Golden suites: tests/golden/<dir>/<name>.envol -> <name><ext>, produced by
    # `envoc0 <command>`. Keep this list in step with bootstrap.ps1.
    for suite in lexer:lex:.tokens parser:parse:.ast check:check:.check; do
      sdir=${suite%%:*}; rest=${suite#*:}; cmd=${rest%%:*}; ext=${rest#*:}
      say "golden tests: tests/golden/$sdir"
      dir="$ES/tests/golden/$sdir"
      for f in "$dir"/*.envol; do
        base=$(basename "$f")
        name="golden/$sdir/$base"
        expected="${f%.envol}$ext"
        [ -f "$expected" ] || { bad "$name" "missing $ext file"; continue; }
        run "$dir" "$cmd" "$base"
        if [ "$rc" -ne 0 ]; then bad "$name" "exit $rc: $(tr -d '\r' < "$TMP/err")"; continue; fi
        tr -d '\r' < "$expected" > "$TMP/expected"
        tr -d '\r' < "$TMP/out" > "$TMP/actual"
        if cmp -s "$TMP/expected" "$TMP/actual"; then pass
        else bad "$name" 'output differs:'; diff "$TMP/expected" "$TMP/actual" | head -n 10 || true; fi
      done
    done

    # Spec error tests run through `envoc0 check`, which lexes and parses first, so
    # lexical and syntax errors are still reported by their own stage.
    # Keep this list in step with bootstrap.ps1.
    for sdir in 01-lexical core-syntax core-types; do
      say "spec tests: tests/spec/$sdir"
      dir="$ES/tests/spec/$sdir"
      for f in "$dir"/*.envol; do
        base=$(basename "$f")
        name="spec/$sdir/$base"
        line=$(LC_ALL=C grep -a -m1 '^// expect-error: ' "$f" | tr -d '\r' || true)
        [ -n "$line" ] || { bad "$name" 'no // expect-error: annotation'; continue; }
        code=$(printf '%s\n' "$line" | sed 's|^// expect-error: \(E[0-9][0-9][0-9][0-9]\).*|\1|')
        want="error[$code]"
        case "$line" in
            *' @ '*) pos=${line##* @ }; pos=${pos%% *}; want="$base:$pos: error[$code]" ;;
        esac
        run "$dir" check "$base"
        if grep -q -F '(no message for this error code)' "$TMP/err"; then bad "$name" "missing message: $(cat "$TMP/err")"
        elif [ "$rc" -eq 1 ] && LC_ALL=C grep -a -q -F "$want" "$TMP/err"; then pass
        else bad "$name" "expected exit 1 with '$want'; got exit $rc: $(tr -d '\r' < "$TMP/err")"; fi
      done
    done

    # Programs compiled and run: `// expect:` stdout lines, `// expect-exit: N`,
    # `// expect-panic: <reason>` (exit 101 and "panic: <reason>" on stderr).
    # Programs compiled and run: by Stage 0, then by Stage 1, which must give the same
    # output and exit codes (M2.7, PLAN D14); then by Stage 2, whose executables must be
    # byte-identical to Stage 1's (M3.6).
    stage0_exe=$EXE
    for compiler in envoc0 envoc1 envoc; do
    case $compiler in
        envoc0) EXE=$stage0_exe ;;
        envoc1) EXE="$BUILD1/envoc1$(host_suffix)" ;;
        envoc) EXE="$BUILD2/envoc$(host_suffix)" ;;
    esac
        rundir="$ROOT/build/run-$compiler"
        mkdir -p "$rundir"
        # Envo-S1 programs (tests/spec/s1-run) run under Stages 1 and 2 only.
        run_suites="core-run s1-run"
        [ "$compiler" = envoc0 ] && run_suites=core-run
        # programs only Stage 2 accepts (tests/spec/s2-run, M3.10)
        [ "$compiler" = envoc ] && run_suites="core-run s1-run s2-run"
        for suite in $run_suites; do
        say "run tests ($compiler): tests/spec/$suite"
        for f in "$ES"/tests/spec/$suite/*.envol; do
            base=$(basename "$f" .envol)
            name="$compiler spec/$suite/$base.envol"
            sed -n 's|^// expect: \(.*\)$|\1|p' "$f" | tr -d '\r' > "$TMP/expected"
            want_code=$(sed -n 's|^// expect-exit: \([0-9]*\).*|\1|p' "$f" | head -n 1)
            panic=$(sed -n 's|^// expect-panic: \(.*\)$|\1|p' "$f" | tr -d '\r' | head -n 1)
            [ -n "$want_code" ] || want_code=0
            [ -z "$panic" ] || want_code=101
            program="$rundir/$base"
            case "$EXE" in *.exe) program="$program.exe" ;; esac
            run "$rundir" build "$f" -o "$program"
            if [ "$rc" -ne 0 ]; then bad "$name" "build failed: $(cat "$TMP/err")"; continue; fi
            if [ "$suite" = s2-run ]; then
                # Stage 1 rejects it, with the code the test names
                stage1=$(sed -n 's|^// stage1-error: \(E[0-9]*\).*|\1|p' "$f" | tr -d '\r' | head -n 1)
                saved=$EXE
                EXE="$BUILD1/envoc1$(host_suffix)"
                mv "$TMP/out" "$TMP/run-out"
                run "$rundir" check "$f"
                mv "$TMP/run-out" "$TMP/out"
                EXE=$saved
                if [ -z "$stage1" ] || [ "$rc" -ne 1 ] || ! grep -q "error\[$stage1\]" "$TMP/err"; then bad "$name" "envoc1 should reject it with ${stage1:-a // stage1-error: code}: exit $rc"; continue; fi
            elif [ "$compiler" = envoc ]; then
                if ! cmp -s "$program" "$ROOT/build/run-envoc1/${program##*/}"; then bad "$name" 'the executable differs from the envoc1 build'; continue; fi
            fi
            if [ "$compiler" = envoc ]; then
                problem=$(objects "$rundir" "$program" "$f")
                if [ -n "$problem" ]; then bad "$name" "$problem"; continue; fi
                # the object holds the program's EIR, in the binary form
                run "$rundir" eir "$f"
                mv "$TMP/out" "$TMP/eir"
                run "$rundir" eir-check "$program.0.eo"
                if [ "$rc" -ne 0 ] || ! cmp -s "$TMP/eir" "$TMP/out"; then bad "$name" "eir-check of the object differs from eir: exit $rc"; continue; fi
            fi
            set +e
            (cd "$rundir" && "$program") > "$TMP/out" 2> "$TMP/err"
            rc=$?
            set -e
            tr -d '\r' < "$TMP/out" > "$TMP/actual"
            if ! cmp -s "$TMP/expected" "$TMP/actual"; then bad "$name" 'stdout differs:'; diff "$TMP/expected" "$TMP/actual" | head -n 10 || true; continue; fi
            if [ "$rc" -ne "$want_code" ]; then bad "$name" "exit code $rc, expected $want_code: $(cat "$TMP/err")"; continue; fi
            if [ -n "$panic" ] && ! grep -q -F "panic: $panic" "$TMP/err"; then bad "$name" "stderr: $(cat "$TMP/err")"; continue; fi
            if [ "$compiler" = envoc ]; then
                # -O2 (M3.8): the same output, exit code and panic
                fast="$rundir/$base-O2$(host_suffix)"
                run "$rundir" build -O2 "$f" -o "$fast"
                if [ "$rc" -ne 0 ]; then bad "$name" "-O2 build failed: $(cat "$TMP/err")"; continue; fi
                set +e
                (cd "$rundir" && "$fast") > "$TMP/out" 2> "$TMP/err"
                rc=$?
                set -e
                tr -d '\r' < "$TMP/out" > "$TMP/actual"
                if ! cmp -s "$TMP/expected" "$TMP/actual" || [ "$rc" -ne "$want_code" ]; then bad "$name" "-O2: stdout or exit code ($rc) differs"; continue; fi
                if [ -n "$panic" ] && ! grep -q -F "panic: $panic" "$TMP/err"; then bad "$name" "-O2 stderr: $(cat "$TMP/err")"; continue; fi
            fi
            pass
        done
        done

        # Multi-file programs: one folder per test. main.envol is the entry file and holds
        # the annotations; the other .envol files follow in name order. Either
        # `// expect-error: E#### @ <file>:L:C` (envoc0 check) or `// expect:` lines (build, run).
        # Envo-S1 programs of several files (tests/spec/s1-multi) under Stages 1 and 2 only.
        multi_suites="core-multi s1-multi"
        [ "$compiler" = envoc0 ] && multi_suites=core-multi
        for msuite in $multi_suites; do
        say "multi-file tests ($compiler): tests/spec/$msuite"
        for d in "$ES"/tests/spec/$msuite/*/; do
            d=${d%/}
            base=$(basename "$d")
            name="$compiler spec/$msuite/$base"
            set -- main.envol
            for f in "$d"/*.envol; do
                f=$(basename "$f")
                [ "$f" = main.envol ] || set -- "$@" "$f"
            done
            line=$(grep -m1 '^// expect-error: ' "$d/main.envol" | tr -d '\r' || true)
            if [ -n "$line" ]; then
                code=$(printf '%s\n' "$line" | sed 's|^// expect-error: \(E[0-9]*\) @ .*|\1|')
                want="${line##* @ }: error[$code]"
                run "$d" check "$@"
                if [ "$rc" -eq 1 ] && grep -q -F "$want" "$TMP/err"; then pass
                else bad "$name" "expected exit 1 with '$want'; got exit $rc: $(tr -d '\r' < "$TMP/err")"; fi
                continue
            fi
            sed -n 's|^// expect: \(.*\)$|\1|p' "$d/main.envol" | tr -d '\r' > "$TMP/expected"
            program="$rundir/$msuite-$base"
            case "$EXE" in *.exe) program="$program.exe" ;; esac
            run "$d" build "$@" -o "$program"
            if [ "$rc" -ne 0 ]; then bad "$name" "build failed: $(cat "$TMP/err")"; continue; fi
            if [ "$compiler" = envoc ]; then
                if ! cmp -s "$program" "$ROOT/build/run-envoc1/${program##*/}"; then bad "$name" 'the executable differs from the envoc1 build'; continue; fi
                problem=$(objects "$d" "$program" "$@")
                if [ -n "$problem" ]; then bad "$name" "$problem"; continue; fi
            fi
            set +e
            (cd "$rundir" && "$program") > "$TMP/out" 2> "$TMP/err"
            rc=$?
            set -e
            tr -d '\r' < "$TMP/out" > "$TMP/actual"
            if ! cmp -s "$TMP/expected" "$TMP/actual"; then bad "$name" 'stdout differs:'; diff "$TMP/expected" "$TMP/actual" | head -n 10 || true; continue; fi
            if [ "$rc" -ne 0 ]; then bad "$name" "exit code $rc: $(cat "$TMP/err")"; continue; fi
            if [ "$compiler" = envoc ]; then
                fast="$rundir/$msuite-$base-O2$(host_suffix)"
                run "$d" build -O2 "$@" -o "$fast"
                if [ "$rc" -ne 0 ]; then bad "$name" "-O2 build failed: $(cat "$TMP/err")"; continue; fi
                set +e
                (cd "$rundir" && "$fast") > "$TMP/out" 2> "$TMP/err"
                rc=$?
                set -e
                tr -d '\r' < "$TMP/out" > "$TMP/actual"
                if ! cmp -s "$TMP/expected" "$TMP/actual" || [ "$rc" -ne 0 ]; then bad "$name" "-O2: stdout or exit code ($rc) differs"; continue; fi
            fi
            pass
        done
        done
    done
    EXE=$stage0_exe

    say ''
    say 'stage 1 smoke tests'
    stage0_exe=$EXE
    EXE=$ENVOC1
    run "$ROOT" version
    if [ "$rc" -eq 0 ] && grep -q '^envoc1 ' "$TMP/out"; then pass; else bad 'envoc1 version' "exit $rc"; fi
    run "$ROOT" selftest
    if [ "$rc" -eq 0 ] && grep -q '^selftest: ok' "$TMP/out"; then pass; else bad 'envoc1 selftest' "exit $rc: $(cat "$TMP/out" "$TMP/err")"; fi
    run "$ROOT"
    if [ "$rc" -eq 2 ] && grep -q '^usage: envoc1' "$TMP/err"; then pass; else bad 'envoc1 no arguments' "exit $rc"; fi
    run "$ROOT" frobnicate
    if [ "$rc" -eq 2 ] && grep -q "^envoc1: error: unknown command 'frobnicate'" "$TMP/err"; then pass; else bad 'envoc1 unknown command' "exit $rc"; fi

    # The runtime embedded in envoc1 must be generated from the current runtime sources.
    run "$STAGE1" embed runtime/common.envol runtime/linux.envol runtime/windows.envol prelude/prelude.envol
    tr -d '\r' < "$STAGE1/runtime/embedded.envol" > "$TMP/expected"
    tr -d '\r' < "$TMP/out" > "$TMP/actual"
    if [ "$rc" -eq 0 ] && cmp -s "$TMP/expected" "$TMP/actual"; then pass
    else bad 'envoc1 embedded runtime' "stage1/runtime/embedded.envol is stale: regenerate it with envoc1 embed (see docs/stage1.md)"; fi

    # The x86-64 encoder and image writer: a minimal native program must exit with 42.
    case "$ENVOC1" in *.exe) host_os=windows ;; *) host_os=linux ;; esac
    run "$TMP" selftest-image "$TMP/t42" "$host_os"
    if [ "$rc" -eq 0 ]; then
        set +e
        "$TMP/t42"
        rc=$?
        set -e
        if [ "$rc" -eq 42 ]; then pass; else bad 'envoc1 selftest-image' "exit $rc, expected 42"; fi
    else
        bad 'envoc1 selftest-image' "exit $rc: $(cat "$TMP/err")"
    fi

    # Differential tests (PLAN D14). Golden suites: envoc1 must print exactly envoc0's
    # expected files, in --core mode and in Envo-S1 mode (Core programs mean the same in
    # S1). Spec suites: the same error code at the same position; lexical tests run in
    # both modes (E0901-E0904 become E0950 in S1), syntax tests in --core mode.
    # Keep these lists in step with bootstrap.ps1.
    for suite in lexer:lex:.tokens:both parser:parse:.ast:both check:check:.check:both s1-parser:parse:.ast:s1; do
      sdir=${suite%%:*}; rest=${suite#*:}; cmd=${rest%%:*}; rest=${rest#*:}; ext=${rest%%:*}; modes=${rest#*:}
      for mode in --core s1; do
        [ "$modes" = s1 ] && [ "$mode" = --core ] && continue
        say "stage 1 golden tests ($mode): tests/golden/$sdir"
        dir="$ES/tests/golden/$sdir"
        for f in "$dir"/*.envol; do
            base=$(basename "$f")
            name="stage1 $mode golden/$sdir/$base"
            if [ "$mode" = --core ]; then run "$dir" --core "$cmd" "$base"; else run "$dir" "$cmd" "$base"; fi
            if [ "$rc" -ne 0 ]; then bad "$name" "exit $rc: $(tr -d '\r' < "$TMP/err")"; continue; fi
            tr -d '\r' < "${f%.envol}$ext" > "$TMP/expected"
            tr -d '\r' < "$TMP/out" > "$TMP/actual"
            if cmp -s "$TMP/expected" "$TMP/actual"; then pass
            else bad "$name" 'output differs:'; diff "$TMP/expected" "$TMP/actual" | head -n 10 || true; fi
        done
      done
    done
    for suite in 01-lexical:lex:both core-syntax:parse:core core-types:check:core s1-syntax:parse:s1 s1-types:check:s1 s1-own:check:s1; do
      sdir=${suite%%:*}; rest=${suite#*:}; cmd=${rest%%:*}; modes=${rest#*:}
      for mode in --core s1; do
        [ "$modes" = core ] && [ "$mode" = s1 ] && continue
        [ "$modes" = s1 ] && [ "$mode" = --core ] && continue
        say "stage 1 spec tests ($mode): tests/spec/$sdir"
        dir="$ES/tests/spec/$sdir"
        for f in "$dir"/*.envol; do
            base=$(basename "$f")
            name="stage1 $mode spec/$sdir/$base"
            line=$(LC_ALL=C grep -a -m1 '^// expect-error: ' "$f" | tr -d '\r' || true)
            code=$(printf '%s\n' "$line" | sed 's|^// expect-error: \(E[0-9][0-9][0-9][0-9]\).*|\1|')
            if [ "$mode" = s1 ]; then
                case "$code" in E090[1-4]) code=E0950 ;; esac
            fi
            pos=${line##* @ }; pos=${pos%% *}
            want="$base:$pos: error[$code]"
            if [ "$mode" = --core ]; then run "$dir" --core "$cmd" "$base"; else run "$dir" "$cmd" "$base"; fi
            if [ "$rc" -eq 1 ] && LC_ALL=C grep -a -q -F "$want" "$TMP/err"; then pass
            else bad "$name" "expected exit 1 with '$want'; got exit $rc: $(tr -d '\r' < "$TMP/err")"; fi
        done
      done
    done
    # Multi-file error tests, and Stage 1 checking its own source (D14).
    say "stage 1 multi-file tests (--core): tests/spec/core-multi"
    for d in "$ES"/tests/spec/core-multi/*/; do
        line=$(grep -m1 '^// expect-error: ' "$d/main.envol" | tr -d '\r' || true)
        [ -n "$line" ] || continue
        set -- main.envol
        for f in "$d"*.envol; do
            f=$(basename "$f")
            [ "$f" = main.envol ] || set -- "$@" "$f"
        done
        code=$(printf '%s\n' "$line" | sed 's|^// expect-error: \(E[0-9]*\) @ .*|\1|')
        want="${line##* @ }: error[$code]"
        run "$d" --core check "$@"
        if [ "$rc" -eq 1 ] && grep -q -F "$want" "$TMP/err"; then pass
        else bad "stage1 --core core-multi/$(basename "$d")" "expected exit 1 with '$want'; got exit $rc: $(tr -d '\r' < "$TMP/err")"; fi
    done
    # EIR v1 (M2.6): canonical printing round-trips, and verifier errors.
    say 'stage 1 golden tests: tests/golden/eir'
    dir="$ES/tests/golden/eir"
    for f in "$dir"/*.eir; do
        base=$(basename "$f")
        tr -d '\r' < "${f%.eir}.out" > "$TMP/expected"
        for input in "$base" "${base%.eir}.out"; do
            run "$dir" eir-check "$input"
            tr -d '\r' < "$TMP/out" > "$TMP/actual"
            if [ "$rc" -eq 0 ] && cmp -s "$TMP/expected" "$TMP/actual"; then pass
            else bad "golden/eir/$input" "exit $rc: $(tr -d '\r' < "$TMP/err")"; diff "$TMP/expected" "$TMP/actual" | head -n 10 || true; fi
        done
    done
    say 'stage 1 spec tests: tests/spec/eir'
    dir="$ES/tests/spec/eir"
    for f in "$dir"/*.eir; do
        base=$(basename "$f")
        line=$(grep -m1 '^; expect-error: ' "$f" | tr -d '\r' || true)
        code=$(printf '%s\n' "$line" | sed 's|^; expect-error: \(E[0-9]*\) @ .*|\1|')
        pos=${line##* @ }; pos=${pos%% *}
        want="$base:$pos: error[$code]"
        run "$dir" eir-check "$base"
        if [ "$rc" -eq 1 ] && grep -q -F "$want" "$TMP/err"; then pass
        else bad "spec/eir/$base" "expected exit 1 with '$want'; got exit $rc: $(tr -d '\r' < "$TMP/err")"; fi
    done
    say 'stage 1 self-check: envoc1 --core check stage1'
    set --
    while IFS= read -r f || [ -n "$f" ]; do
        f=$(printf '%s' "$f" | tr -d '\r')
        [ -n "$f" ] && set -- "$@" "$f"
    done < "$STAGE1/files.txt"
    run "$STAGE1" --core check "$@"
    if [ "$rc" -eq 0 ]; then pass; else bad 'stage1 self-check' "exit $rc: $(head -c 300 "$TMP/err")"; fi


    say ''
    say 'stage 2: built by stage 1, it must behave as it does built by itself'
    envoc2="$BUILD2/envoc$(host_suffix)"
    say 'stage 2 against envoc1: lex and parse on every .envol file in compiler/, stage1/, tests/; check on the run programs and goldens; eir on the run programs'
    for f in $( (cd "$ES" && find compiler tests -name '*.envol'; cd "$ROOT" && find stage1 -name '*.envol') | LC_ALL=C sort); do
        case "$f" in stage1/*) froot=$ROOT ;; *) froot=$ES ;; esac
        dir="$froot/$(dirname "$f")"
        base=$(basename "$f")
        cmds='lex parse'
        case "$f" in
            tests/spec/core-run/*|tests/spec/s1-run/*) cmds='lex parse check eir' ;;
            tests/golden/*) cmds='lex parse check' ;;
        esac
        # a program Stage 1 cannot parse (E0950, such as floats: RFC 0006) is compared as tokens
        if grep -q '^// stage1-error: E0950' "$froot/$f"; then cmds='lex'; fi
        for cmd in $cmds; do
            EXE=$ENVOC1
            run "$dir" "$cmd" "$base"
            rc1=$rc
            mv "$TMP/out" "$TMP/out1"
            mv "$TMP/err" "$TMP/err1"
            EXE=$envoc2
            run "$dir" "$cmd" "$base"
            if [ "$rc" -eq "$rc1" ] && cmp -s "$TMP/out1" "$TMP/out" && cmp -s "$TMP/err1" "$TMP/err"; then pass
            else bad "stage2 $cmd $f" "differs from envoc1 (exit $rc1 vs $rc)"; fi
        done
    done
    for unit in stage1:--core compiler:s1 stage1:--core:eir compiler:s1:eir; do
        pass_eir=0
        case "$unit" in *:eir) pass_eir=1; unit=${unit%:eir} ;; esac
        case "${unit%%:*}" in stage1) dir=$STAGE1 ;; *) dir=$STAGE2 ;; esac
        cmd=check
        [ "$pass_eir" = 1 ] && cmd=eir
        if [ "${unit#*:}" = --core ]; then set -- --core "$cmd"; else set -- "$cmd"; fi
        while IFS= read -r f || [ -n "$f" ]; do
            f=$(printf '%s' "$f" | tr -d '\r')
            [ -n "$f" ] && set -- "$@" "$f"
        done < "$dir/files.txt"
        EXE=$ENVOC1
        run "$dir" "$@"
        rc1=$rc
        mv "$TMP/out" "$TMP/out1"
        mv "$TMP/err" "$TMP/err1"
        EXE=$envoc2
        run "$dir" "$@"
        if [ "$rc" -eq "$rc1" ] && cmp -s "$TMP/out1" "$TMP/out" && cmp -s "$TMP/err1" "$TMP/err"; then pass
        else bad "stage2 $cmd ${unit%%:*}" "differs from envoc1 (exit $rc1 vs $rc)"; fi
    done
    # Stage 2 builds Stage 1 as envoc1 does, and builds itself into the envoc that envoc1
    # built, for both targets (M3.6).
    selfdir="$ROOT/build/run-envoc"
    for unit in stage1:--core:x86_64-linux compiler::x86_64-linux compiler::x86_64-windows; do
        case "${unit%%:*}" in stage1) dir=$STAGE1 ;; *) dir=$STAGE2 ;; esac
        target=${unit##*:}
        set -- build
        case "$unit" in *:--core:*) set -- --core build ;; esac
        while IFS= read -r f || [ -n "$f" ]; do
            f=$(printf '%s' "$f" | tr -d '\r')
            [ -n "$f" ] && set -- "$@" "$f"
        done < "$dir/files.txt"
        what="stage2 build ${unit%%:*} ($target)"
        if [ "${unit%%:*}" = compiler ]; then
            want="$BUILD2/envoc"
            [ "$target" = x86_64-windows ] && want="$BUILD2/envoc.exe"
        else
            want="$selfdir/self-stage1-envoc1"
            EXE=$ENVOC1
            run "$dir" "$@" -o "$want" --target "$target"
            if [ "$rc" -ne 0 ]; then bad "$what" "envoc1 failed: exit $rc"; continue; fi
        fi
        EXE=$envoc2
        run "$dir" "$@" -o "$selfdir/self-$target" --target "$target"
        if [ "$rc" -eq 0 ] && cmp -s "$want" "$selfdir/self-$target"; then pass
        else bad "$what" "exit $rc, or the executable differs from envoc1's"; fi
    done
    # Stage 2 at -O2 (M3.8): it builds Stage 2 into the same bytes as envoc1's build at
    # -O0, and into itself at -O2
    set -- build
    while IFS= read -r f || [ -n "$f" ]; do
        f=$(printf '%s' "$f" | tr -d '\r')
        [ -n "$f" ] && set -- "$@" "$f"
    done < "$STAGE2/files.txt"
    fast="$selfdir/envoc-O2$(host_suffix)"
    run "$STAGE2" "$@" -O2 -o "$fast"
    saved=$EXE
    EXE=$fast
    [ "$rc" -eq 0 ] && run "$STAGE2" "$@" -o "$selfdir/by-O2$(host_suffix)"
    [ "$rc" -eq 0 ] && run "$STAGE2" "$@" -O2 -o "$selfdir/by-O2-O2$(host_suffix)"
    EXE=$saved
    if [ "$rc" -eq 0 ] && cmp -s "$selfdir/by-O2$(host_suffix)" "$BUILD2/envoc$(host_suffix)" && cmp -s "$fast" "$selfdir/by-O2-O2$(host_suffix)"; then pass
    else bad 'stage2 -O2 self-build' "exit $rc, or the -O2 compiler's output differs"; fi
    # Stage 2 through an object of itself (M3.7), and link errors
    set -- compile
    while IFS= read -r f || [ -n "$f" ]; do
        f=$(printf '%s' "$f" | tr -d '\r')
        [ -n "$f" ] && set -- "$@" "$f"
    done < "$STAGE2/files.txt"
    run "$STAGE2" "$@" -o "$selfdir/self.eo"
    [ "$rc" -eq 0 ] && run "$STAGE2" link "$selfdir/self.eo" -o "$selfdir/self-linked"
    if [ "$rc" -eq 0 ] && cmp -s "$selfdir/self-linked" "$BUILD2/envoc$(host_suffix)"; then pass
    else bad 'stage2 compile and link compiler' "exit $rc, or the executable differs from build/stage2"; fi
    run "$ROOT" link "$selfdir/core-multi-program$(host_suffix).0.eo" -o "$selfdir/none"
    if [ "$rc" -eq 1 ] && grep -q 'no object defines @' "$TMP/err"; then pass; else bad 'stage2 link with a unit missing' "exit $rc: $(cat "$TMP/err")"; fi
    run "$ROOT" link "$selfdir/core-multi-program$(host_suffix).0.eo" "$selfdir/s1-multi-namespaces$(host_suffix).0.eo" -o "$selfdir/none"
    if [ "$rc" -eq 1 ] && grep -q 'compiled from different programs' "$TMP/err"; then pass; else bad 'stage2 link of two programs' "exit $rc: $(cat "$TMP/err")"; fi
    printf 'EIR\000\002\000' > "$selfdir/v2.eo"
    run "$ROOT" link "$selfdir/v2.eo" -o "$selfdir/none"
    if [ "$rc" -eq 1 ] && grep -q 'binary EIR version 2; this envoc reads version 1' "$TMP/err"; then pass; else bad 'stage2 link of an unknown version' "exit $rc: $(cat "$TMP/err")"; fi
    EXE=$stage0_exe

    say ''
    say "$passed passed, $failed failed"
    [ "$failed" -eq 0 ] || exit 1
}

# ------------------------------------------------------------------- check

# ------------------------------------------------------------------- check
do_check() {
    # docs/eas.md: every jump states its size, so the bytes depend on the source alone.
    # EnvoLang/spec/eas.md: every jump states its size, so the bytes depend on the source alone.
    unsized=$(find "$ROOT/seed" "$ROOT/stage0" -name '*.eas' -exec grep -n -E '^[[:space:]]*j[a-z]+[[:space:]]+[.A-Za-z_]' /dev/null {} + \
        | grep -v -E ':[[:space:]]*j[a-z]+[[:space:]]+((short|near)[[:space:]]|r[a-z0-9]+[[:space:]]*(;|$))' || true)
    [ -z "$unsized" ] || problem "jumps without short/near: $unsized"
    say "check: ok"
}

# compare <dir-a> <dir-b>: both builds (each a copy of build/, with stage0/, stage1/ and
# stage2/) must be byte-identical (brief 4.1).
# The fixed point (PLAN D18, M3.9): stage2a (build/stage2, built by envoc1) builds Stage 2
# at -O2 into build/stage2b, and stage2b builds it again into build/stage2c, for both
# targets. stage2b and stage2c must be byte-identical.
do_fixedpoint() {
    do_build
    set --
    while IFS= read -r f || [ -n "$f" ]; do
        f=$(printf '%s' "$f" | tr -d '\r')
        [ -n "$f" ] && set -- "$@" "$f"
    done < "$STAGE2/files.txt"
    for step in stage2:stage2b stage2b:stage2c; do
        from=${step%%:*}
        to=${step#*:}
        mkdir -p "$ROOT/build/$to"
        exe="$ROOT/build/$from/envoc$(host_suffix)"
        for unit in "x86_64-linux:envoc" "x86_64-windows:envoc.exe"; do
            target=${unit%%:*}
            out=${unit#*:}
            say "build     compiler -> build/$to/$out (by build/$from/envoc$(host_suffix), -O2)"
            (cd "$STAGE2" && "$exe" build "$@" -O2 -o "$ROOT/build/$to/$out" --target "$target") \
                || fail "building Stage 2 ($target) with build/$from failed"
            say "          $(wc -c < "$ROOT/build/$to/$out" | tr -d ' ') bytes  sha256 $(sha256 "$ROOT/build/$to/$out")"
        done
        chmod +x "$ROOT/build/$to/envoc"
    done
    for out in envoc envoc.exe; do
        if cmp -s "$ROOT/build/stage2b/$out" "$ROOT/build/stage2c/$out"; then say "fixed point: stage2b/$out = stage2c/$out"
        else fail "no fixed point: build/stage2b/$out and build/stage2c/$out differ"; fi
    done
}

do_compare() {
    [ "$#" -eq 2 ] || fail "usage: ./bootstrap.sh compare <dir-a> <dir-b>"
    differ=0
    files='stage0/envoc0 stage0/envoc0.exe stage1/envoc1 stage1/envoc1.exe stage2/envoc stage2/envoc.exe'
    # after `fixedpoint`, the fixed-point compilers too
    [ -d "$1/stage2c" ] && files="$files stage2c/envoc stage2c/envoc.exe"
    # after `dist`, the release archive's digest (EnvoScale/guides/offline-install.md)
    [ -f "$1/dist/SHA256SUMS" ] && files="$files dist/SHA256SUMS"
    for f in $files; do
        [ -f "$1/$f" ] || fail "missing $1/$f"
        [ -f "$2/$f" ] || fail "missing $2/$f"
        say "$f"
        say "  $1: $(wc -c < "$1/$f" | tr -d ' ') bytes  sha256 $(sha256 "$1/$f")"
        say "  $2: $(wc -c < "$2/$f" | tr -d ' ') bytes  sha256 $(sha256 "$2/$f")"
        if cmp -s "$1/$f" "$2/$f"; then say "  identical"
        else say "  DIFFERENT: $(cmp "$1/$f" "$2/$f" | head -n 1)"; differ=1; fi
    done
    [ "$differ" -eq 0 ] || fail "the builds are not byte-identical"
}

# ------------------------------------------------------------------- seed
# seed: the compilers EnvoScale builds itself from (its build.sh downloads them from this
# repository's releases): the fixed-point compilers, named by target, with SHA256SUMS.
do_seed() {
    do_fixedpoint
    rel="$ROOT/build/seed-release"
    rm -rf "$rel"
    mkdir -p "$rel"
    cp "$ROOT/build/stage2c/envoc" "$rel/envoc-x86_64-linux"
    cp "$ROOT/build/stage2c/envoc.exe" "$rel/envoc-x86_64-windows.exe"
    (cd "$rel" && for f in envoc-*; do printf '%s  %s\n' "$(sha256 "$f")" "$f"; done > SHA256SUMS)
    say "seed      build/seed-release (EnvoScale $(git -C "$ES" rev-parse --short HEAD))"
    cat "$rel/SHA256SUMS"
}

case "${1:-help}" in
    build) do_build ;;
    test)  do_test ;;
    fixedpoint) do_fixedpoint ;;
    seed)  do_seed ;;
    compare) shift; do_compare "$@" ;;
    check) do_check ;;
    clean) rm -rf "$ROOT/build"; say 'removed build/' ;;
    help|*)
        say 'usage: ./bootstrap.sh <build|test|fixedpoint|seed|compare|check|clean>'
        [ "${1:-help}" = help ] || exit 2 ;;
esac
