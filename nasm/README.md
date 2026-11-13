# `nasm/`: assembling stage 0 with NASM

> **Status:** Active, optional. Since M13 the hex seed (`seed/`) builds
> Stage 0 to the same bytes when NASM is not installed; CI compares the two.

Assembles Stage 0 (`stage0/*.eas`) with [NASM](https://www.nasm.us/) while the
hex seed is being written (brief §5.4). It is **outside the core** and never needed to
*use* EnvoScale: only to build `envoc0` from source.

## Installing NASM

Any NASM 2.14 or newer works; CI and local builds with NASM 2.16, 3.01 and 3.02 produce
identical bytes. NASM is not committed to this repository.

| OS | Command |
|---|---|
| Windows | `winget install NASM.NASM` (or the installer from nasm.us) |
| Debian/Ubuntu | `sudo apt-get install nasm` |
| Fedora | `sudo dnf install nasm` |
| macOS | `brew install nasm` |

The scripts find NASM in this order:

1. the `NASM` environment variable (full path to the executable)
2. `nasm` on `PATH`
3. Windows only: `%ProgramFiles%\NASM\nasm.exe` and `%LOCALAPPDATA%\bin\NASM\nasm.exe`

## Interface

The adapter is one script per host shell. Both take the same three arguments and do
nothing except run NASM in flat-binary mode:

```
assemble.ps1 <input.eas> <output-file> <include-dir>
assemble.sh  <input.eas> <output-file> <include-dir>
```

Both run NASM as `nasm -f bin -w+all "-dnear=strict near" -I <include-dir>`. The
`near` definition keeps EAS's meaning of `near` (always a rel32 jump, `docs/eas.md`):
NASM 3.01 treats `near` as a hint and shortens jumps that fit in rel8, which changed the
bytes of Stage 0 and broke the fixed-size jump table of its runtime block. With `strict`,
every NASM version emits rel32, and versions that already honoured `near` produce the
same bytes as before.

`bootstrap.ps1` / `bootstrap.sh` call these and nothing else knows NASM exists. When they
report NASM missing (exit 127), the scripts assemble with the seed's asm0 instead, and
their `test` compares the seed's output with NASM's byte for byte.

## Why flat binary

Stage 0 writes its own PE and ELF headers as data in `.eas`, so the assembler never has
to understand object files or linking. That keeps the `.eas` subset small enough for the
seed to implement, and means NASM, the seed and `envo asm` can be held to identical bytes.
