# Stage S: the hex seed

> **Status:** Done (M13, PLAN D67). Checked in CI on every push.

The seed lets EnvoScale be built from nothing but the operating system: no NASM, no
other compiler. It is **asm0**, an assembler for the Stage 0 subset of EAS
([`docs/eas.md`](https://github.com/envoscale/EnvoScale/blob/main/bootstrap/eas.md)), written down as commented hexadecimal:

| File | What it is |
|---|---|
| `seed-linux.hex`, `seed-windows.hex` | asm0 for x86-64 Linux (ELF, 16 KB) and Windows (PE, 24 KB): every byte, with each statement's offset and source as a comment |
| `hex2bin.sh`, `hex2bin.ps1` | turn a `.hex` file into the program with the OS alone (POSIX `sh`, `sed`, `tr`, `awk`, `printf`; or PowerShell) |
| `asm0-linux.eas`, `asm0-windows.eas`, `src/` | asm0's source, in the same EAS subset: Stage 0's own header, runtime block and support routines (`stage0/platform`, `src/mem.eas`, `src/io.eas`), then the assembler |
| `mkhex.py`, `mkdata.py` | development tools: the `.hex` from a NASM listing; `src/data.eas` (tables) from lists |

## The ladder

```
seed-<os>.hex --hex2bin--> asm0 --asm0--> envoc0 (Stage 0) --> envoc1 --> envoc
```

`bootstrap.sh build` / `bootstrap.ps1 build` assemble Stage 0 with NASM when it is
installed, and with the seed when it is not; the bytes are the same either way.

## What CI checks (both bootstrap scripts, `test`)

1. asm0, made from `seed-<host>.hex` by `hex2bin`, assembles `asm0-linux.eas` and
   `asm0-windows.eas` to exactly the bytes in `seed-linux.hex` and `seed-windows.hex`:
   the hex is the documented source, for both OSes, on either host.
2. It assembles `envoc0-linux.eas` and `envoc0-windows.eas` to exactly the bytes NASM
   gives (`build/stage0`).

## How asm0 works

Two passes over the source and its `%include`s (paths relative to the top-level file).
Pass 1 gives every label its address; pass 2 writes the bytes. Statements are numbered
the same way in both passes, and a value is *known* when every name in it was defined
by an earlier statement; only known values may choose a shorter encoding, so sizes never
depend on what comes later (eas.md section 4). It follows NASM's choices where the
subset leaves one: the accumulator forms of the ALU instructions, sign-extended 8-bit
immediates and displacements, `mov r64, imm` as `mov r32, imm32` when the value fits,
the MR forms for register-to-register operations, shifts by 1 as `D1 /n`.

Size: 16 KB on Linux rather than the 4 KB first hoped for: asm0 carries Stage 0's
runtime block and support routines (the same audited code Stage 0 runs on), a symbol
table and the instruction tables. Auditing it means reading `src/` (about 3,500 lines, a third of them data tables and comments)
and checking that the hex is its assembly, which CI does.

Regenerate the hex after changing `src/`:

```
nasm -f bin -I seed/ seed/asm0-linux.eas -o asm0 -l asm0.lst
python seed/mkhex.py linux asm0 asm0.lst      (in seed/; likewise windows)
```
