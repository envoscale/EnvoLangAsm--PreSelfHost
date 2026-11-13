# EAS — Envo Assembly (`.eas`)

> **Status:** Normative for the **Stage 0 subset** (§2–§6), which the Phase A adapter
> (NASM), the hex seed's asm0 (`seed/`), and `envo asm` must all assemble to
> identical bytes. NASM and asm0 do, checked in CI.
> The full syntax used by `envo asm` and `asm { }` blocks (§7) is a draft.

## 1. Design

`.eas` is Intel-syntax x86-64 assembly. **The Stage 0 subset is a strict subset of NASM
syntax, assembled in flat-binary mode.** That choice is deliberate:

- NASM can assemble Stage 0 today (Phase A) with no extra tooling: `nasm -f bin`.
- The hex seed (Phase B) only needs to implement this subset and write raw bytes. No
  object files, no linker, no relocations: Stage 0 writes its own PE/ELF headers as data.
- `envo asm` (M3) must accept the same files. CI compares all three outputs byte for byte.

Anything NASM accepts that is not listed here is **not** `.eas`, even if it would work.

## 2. Lines

```
line      = label? statement? comment?
label     = name ':'
comment   = ';' any-text-to-end-of-line
```

- One statement per line. Lines end at LF; a CR before the LF is ignored.
- Names: `[A-Za-z_.$?@][A-Za-z0-9_.$?@]*`, case-sensitive. A name starting with `.` is a
  **local label**, scoped to the preceding non-local label (`.loop` after `lex:` is
  `lex.loop`).
- Registers, mnemonics and directive names are case-insensitive; Stage 0 sources use
  lowercase.

## 3. Directives

| Directive | Meaning |
|---|---|
| `bits 64` | must appear once, before any code |
| `default rel` | memory operands naming a label use RIP-relative addressing |
| `org <expr>` | sets the address of the first byte of output; must precede any output |
| `<name> equ <expr>` | defines a constant; `<expr>` may not reference labels defined later |
| `db` `dw` `dd` `dq` `<expr>, …` | emit 1/2/4/8-byte little-endian values; `db` also takes strings |
| `times <expr> <db/dw/dd/dq …>` | repeat a data directive; `<expr>` may only use constants, `$` and `$$` |
| `align <n>, db 0` | pad with zero bytes to a multiple of `n` (relative to `$$`); the `, db 0` is required |
| `%include "path"` | textual inclusion; paths are relative to the top-level file's directory |

## 4. Expressions

- Integers: decimal (`42`), hex (`0x2A`). No other bases, no suffixes.
- Character constants: `'a'`, `'MZ'` — up to 8 characters, packed little-endian
  (`'MZ'` = `0x5A4D`). No escapes inside quotes; write a backslash as `0x5C` and a
  single quote as `0x27`.
- Strings in `db`: `'text'` or `"text"`, no escapes.
- Operators, by precedence: unary `-` `~`; `*` `/` `%`; `+` `-`; `<<` `>>`; `&`; `^`;
  `|`. Parentheses group. Arithmetic is 64-bit; `/` and `%` are unsigned.
- `$` is the address of the current line's first byte; `$$` is the `org` address.
- `label - $$` is the label's offset in the file, which equals its RVA in a Stage 0 image
  (see [bootstrap.md](bootstrap.md)).
- A forward reference (to a label or an `equ` constant defined later) is allowed in
  `db`/`dw`/`dd`/`dq` data and in instruction operands, but not in `equ`, `times` or
  `align`.
- A forward-referenced value may not change an instruction's **size**, with one
  exception: jumps. So forward-referenced constants appear only in fixed-size forms
  (`mov r32, imm32`, data directives), and constants used as `imm8`-eligible operands are
  defined first (this is why `stage0` includes `src/tokens.eas` before the code
  that uses token kinds).
- **Every jump states its size**: `jmp short .x` / `jz short .x` (rel8, 2 bytes) or
  `jmp near .x` / `jz near .x` (rel32, 5 or 6 bytes). (An indirect `jmp rax` has no
  size to state.) The assembler never chooses, and a
  `short` jump whose target is out of range is an error, not a silent widening.
  `bootstrap.* check` rejects a jump without a size.

  *Rationale:* letting the assembler pick ("jump relaxation") made the output depend on
  the assembler: NASM 2.16 and 3.02 settled on different sizes for the same source
  (issue #20). With explicit sizes, the bytes are a function of the source text alone,
  and the seed needs no relaxation pass. When editing, write `short`; if the assembler
  reports the target out of range, change that jump to `near`.
- **Write the instruction you mean, in its shortest spelling.** Assemblers may quietly
  substitute an equivalent shorter instruction (NASM 3 turns `movsxd rax, eax` into
  `cdqe`; NASM 2.16 does not), so the source must already use the short form: `cdqe`,
  not `movsxd rax, eax`. Found by comparing NASM 2.16 and 3.02 output (issue #20).
- **Immediates and displacements** whose value is known use the shortest encoding: a
  sign-extended 8-bit immediate or displacement when the value fits, otherwise 32 bits
  (NASM's default `-Ox`). Because constants are defined before the code that uses them
  (above), this choice never depends on later code. RIP-relative operands are always
  32-bit displacements.

## 5. Instructions (Stage 0 subset)

Operands:

- 64/32/16/8-bit general registers: `rax…r15`, `eax…r15d`, `ax…r15w`, `al…r15b`
  (plus `sil`, `dil`, `spl`, `bpl`); `ah`-style high-byte registers are not allowed.
- Immediates: an expression. Its size is inferred from the instruction form.
- Memory: `[base + index*scale + disp]` with any part optional, or `[label + disp]`.
  Size prefixes `byte`, `word`, `dword`, `qword` are required when no register operand
  fixes the size.

Mnemonics:

```
mov movzx movsx movsxd lea  xchg
add sub adc sbb imul mul idiv div neg inc dec
and or xor not test cmp
shl shr sar rol ror
push pop call ret jmp      (jmp also through a 64-bit register)
setcc lodsb
jcc   (jo jno jb jae je jne jbe ja js jns jp jnp jl jge jle jg, and aliases jc jnc jz jnz)
setcc cmovcc   (same condition codes)
cqo cdq cdqe
rep movsb   rep stosb
syscall nop ud2 int3 hlt
```

Every instruction that Stage 0 uses must be in this list; adding one means updating this
document and, once it exists, the seed.

## 6. Style

- Every routine starts with a header comment: what it does, inputs, outputs, and which
  registers it clobbers beyond the calling convention.
- Comments explain *why*. Assembly makes the *what* hard to see, so a short line saying
  what a block achieves is welcome too.
- Constants get names (`TK_EOF equ 0`); raw numbers appear only where the number is the
  meaning (`syscall` numbers next to a comment naming them).
- Character constants for printable ASCII; hex for quotes, backslash and control bytes.

## 7. Full `.eas` (draft, for `envo asm` and `asm { }`)

`envo asm` will extend the subset with: sections and symbols for object output, all
instruction set extensions through per-architecture encoding tables (SSE/AVX/AVX-512,
AArch64, RISC-V), macros written in Envo `comptime` instead of a text preprocessor, and
`{name}` operand bindings for inline `asm` blocks. Inline `asm { }` blocks use Envo
comments (`//`) instead of `;`. This section becomes normative with M3.
