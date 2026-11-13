# Architecture: Stage 0 (`envoc0`)

> **Status:** M1 in progress. The whole pipeline works: lexer, parser, checker, x86-64
> code generation and PE/ELF output. What remains of M1 is a broader test suite.

This note explains how Stage 0 is put together and why. The user-facing overview of the
whole ladder is [the README](../README.md).

## Goals, in order

1. **Correct.** Every behaviour is pinned by a test.
2. **Auditable.** Under ~15k lines of heavily commented assembly, readable top to bottom.
3. **Small surface.** Only the `.eas` subset in [`eas.md`](eas.md), so the hex
   seed can assemble it.
4. **Fast enough.** No optimizer, simple algorithms. Speed is Stage 2's job.

## Build units

Stage 0 is assembled as **one flat binary per target**, from a top-level file that
`%include`s everything else:

```
stage0/
├── envoc0-windows.eas     top-level unit → build/stage0/envoc0.exe
├── envoc0-linux.eas       top-level unit → build/stage0/envoc0
├── platform/
│   ├── windows.eas        PE header, kernel32 imports, shim, argv parsing, entry point
│   └── linux.eas          ELF header, syscall shim, entry point
└── src/                   identical for every target
    ├── main.eas           command dispatch (lex, version, help)
    ├── mem.eas            arena allocator, memory helpers
    ├── io.eas             buffered writers, decimal output, whole-file reads, exit
    ├── diag.eas           error reporting with line/column
    ├── utf8.eas           UTF-8 validation
    ├── tokens.eas         token kinds and the kind table
    └── lexer.eas          the lexer
```

The platform file comes first (it holds the executable header), then `src/*`, then the
top-level file defines `image_end` and, for PE, pads the file.

## Executable layout

Both formats use the simplest layout the loaders accept, so the headers fit on one
screen and the seed only ever writes bytes:

| | Windows (PE32+) | Linux (ELF64) |
|---|---|---|
| Base address | `0x400000` | `0x400000` |
| Sections / segments | one section, `.text`, read+write+execute | one `PT_LOAD`, RWX, plus `PT_GNU_STACK` (RW) |
| Alignment | file alignment = section alignment = `0x1000` | page alignment `0x1000` |
| Relocations | none (`IMAGE_FILE_RELOCS_STRIPPED`, no ASLR) | none (`ET_EXEC`) |
| Imports | `KERNEL32.dll` only, by name | none (raw syscalls) |
| Timestamps | `TimeDateStamp = 0` | n/a |

Because file alignment equals section alignment on PE, and the ELF segment maps the file
from offset 0, **every label's file offset equals its RVA**: `label - $$` is used for
both. One RWX region also means code and data can sit next to each other.

*Trade-off:* RWX images and a fixed base are not what a production linker would emit.
They are acceptable for a bootstrap tool that only ever reads source files and writes
binaries, and they remove relocation handling from the seed entirely. The programs that
Stages 1 and 2 build are W^X and ASLR-enabled (PLAN D68).

## Calling convention inside Stage 0

All Stage 0 routines use the **System V AMD64 register order on every OS**:

- arguments: `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`; return in `rax` (and `rdx`)
- callee-saved: `rbx`, `rbp`, `r12`–`r15`; everything else may be clobbered
- `rsp` is 16-byte aligned at every `call`

Routines that never return (`diag_error`, `fatal`, `exit_process`) realign the stack
themselves, so they can be jumped to from anywhere.

On Linux this is the kernel's own convention, so the shim is a handful of `syscall`s.
On Windows, the shim converts to the Win64 convention at the kernel32 boundary: it
realigns the stack, reserves the 32-byte shadow space, and moves arguments into `rcx`,
`rdx`, `r8`, `r9` and stack slots. Win64 preserves `rsi`/`rdi` in callees, which is a
superset of what our convention requires.

## The platform shim

Exactly eight routines, the whole OS interface of Stage 0:

| Routine | In | Out |
|---|---|---|
| `sys_open` | `rdi` = NUL-terminated path, `rsi` = mode (0 read, 1 write/create/truncate, 2 same but executable) | `rax` = fd, or negative on error |
| `sys_read` | `rdi` = fd, `rsi` = buffer, `rdx` = length | `rax` = bytes read (0 at end), negative on error |
| `sys_write` | `rdi` = fd, `rsi` = buffer, `rdx` = length | `rax` = bytes written (may be partial), negative on error |
| `sys_close` | `rdi` = fd | `rax` = 0 or negative |
| `sys_alloc` | `rdi` = size | `rax` = zeroed, page-aligned memory, or 0 |
| `sys_free` | `rdi` = pointer, `rsi` = size | — |
| `sys_exit` | `rdi` = exit code | does not return |
| `sys_args` | — | `rax` = argc, `rdx` = argv (array of NUL-terminated strings) |

File descriptors 0, 1 and 2 are stdin, stdout and stderr on both OSes. On Windows they
map to the handles from `GetStdHandle`; other fds are the kernel `HANDLE` values, which
are never 0, 1 or 2.

Paths and arguments are **UTF-8 on every OS**. Windows builds `argv` from
`GetCommandLineW`, converted to UTF-8 with `WideCharToMultiByte`, using the Microsoft C
runtime's quoting rules (backslashes before quotes, `""` inside quotes); `sys_open`
converts its UTF-8 path with `MultiByteToWideChar` and calls `CreateFileW`.

## Memory

One bump-pointer **arena** (`arena_alloc`) backed by 64 MiB chunks from `sys_alloc`.
Nothing is freed: Stage 0 is a short-lived batch process, so freeing would only add code.
Allocations larger than a chunk get a dedicated mapping. Memory from `sys_alloc` is
zeroed by the OS, so arena memory is zeroed too.

## Output and errors

`io.eas` has two buffered writers (stdout, stderr, 64 KiB each). All output goes through
them and every exit path flushes them (`exit_process`). Diagnostics follow the format in
[`errors.md`](https://github.com/envoscale/EnvoScale/blob/main/docs/spec/errors.md); Stage 0 stops at the first error.

Exit codes: 0 success, 1 compile error, 2 usage error, 70 internal error.

## The lexer

- The whole file is read into memory (limit 16 MiB) and validated as UTF-8 once, up
  front, so the lexer can treat any byte ≥ 0x80 as part of a valid sequence.
- Tokens go into one array allocated for the worst case (`len + 1` tokens), so there is
  no growth logic. Each token is 16 bytes: kind (u16), flags (u16), start offset (u32),
  length (u32), line (u32). Columns are computed on demand, only for output.
- Keywords and punctuation share one **kind table**: 16-byte entries of
  `length, spelling`. Keyword lookup scans the keyword range; punctuation matching scans
  the punctuation range, which is ordered longest spelling first, so the first match is
  the maximal munch. Linear scans are slow in theory and irrelevant at Stage 0's scale.
- Literal *values* are not computed by the lexer: it validates them and records their
  spans. The parser converts the ones it needs.
- **Several files** (`envoc0 check a.envol b.envol`) are one program. `load_files` copies
  them into one source buffer, each followed by a newline so that a file's end offset is
  never the next file's start, and records a file table (base, length, path). Each file
  is validated and lexed on its own, with `diag_base` turning the lexer's file-relative
  offsets into buffer offsets; the token arrays are then merged with global offsets, each
  file keeping its own EOF token. The parser parses each file's token range separately
  (no statement can span two files) and joins the item lists; a statement outside the
  entry file is E0210. Every later stage sees one program, and diagnostics find the
  file, line and column from the table.

## The parser

- **Recursive descent**, one routine per rule of the Envo-Core grammar
  ([`envo-core.md`](https://github.com/envoscale/EnvoScale/blob/main/docs/spec/envo-core.md) §5.1). Binary operators use precedence
  climbing driven by `tok_class`, a byte per token kind (operator level, assignment,
  not-in-Core, Core keyword), so precedence lives in data, not in code.
- **Nodes** are 32-byte records in one array, addressed by 32-bit index: kind, operator,
  token, four child slots, a `next` link for lists, and flags. Index 0 means "none".
  The array is allocated once for the worst case, so nodes never move and children
  are plain integers. Lists are built by linking `next`.
- **Ambiguity** between declarations and expressions (`u8[16] buf;` vs `buf[i] = 1;`)
  is resolved by speculation: `try_type` parses a type without reporting errors, and
  the caller rewinds the token position and the node count if no declaration follows.
  Types are kept simple enough (array sizes are literals or names) that speculation
  never needs an expression parser.
- **Errors** never return, like the lexer's. `diag_header` + `diag_finish` let the
  parser build messages such as ``expected `;`, found `var` ``.
- **Depth limit.** Every recursive construct counts toward a 256-level limit (E0104),
  so hostile input cannot overflow the 1 MiB stack, here or in later passes.

## The checker

- **Three passes.** Collect every item's name (so items can be used before they are
  declared); then declarations in program order; then bodies, with the top-level
  statements checked as the body of `main`.
- **Lazy declarations with cycle detection.** A struct is laid out when something needs
  its size, a `const` is evaluated when first used, and both carry an in-progress state:
  meeting an in-progress struct is E0303 and an in-progress constant is E0309. This
  gives a single pass over declarations without a separate dependency sort.
- **Interned types.** A 32-byte entry per type; pointer, slice and array types are found
  by linear search before being created, so type equality is an index comparison.
- **Side tables** parallel to the node array hold each node's type, constant value or
  field offset, and resolved symbol, so the tree itself stays immutable after parsing.
- **Untyped literals** are recognised syntactically ([core.expr.2]) and typed from
  context, then evaluated at once, so overflow in `200 + 100` assigned to `u8` is a
  compile-time error.
- **Constants** are 64-bit values sign- or zero-extended by type; arithmetic checks the
  CPU's overflow or carry flag, then whether the result fits the narrower type.
- **Independent reference model.** As with the lexer and parser, every expected output
  and error position in the tests comes from a separate model of
  [`envo-core.md`](https://github.com/envoscale/EnvoScale/blob/main/docs/spec/envo-core.md) §5.2–5.3, not from `envoc0`.

## Code generation

- **Programs reuse envoc0's runtime.** Each platform file is a position-independent
  *runtime block*: entry point, the eight OS routines, argument parsing, the Windows
  import table, and the built-ins. envoc0 runs its native block itself, and `envoc0
  build` copies a block's bytes into every program (both blocks are in every envoc0,
  so it cross-compiles). The writer zeroes the copy's mutable data, points its call to
  `main` at the program's `__main`, and on Windows moves the import RVAs. A block starts
  with a table of 5-byte jumps, so built-in *k* is at offset 5*k* on both OSes
  (`platform/runtime-abi.eas`).
- **A stack machine.** An expression leaves a scalar in `rax`, a `str` or slice in
  `rax`/`rdx`, or the address of a struct or array in `rax`. Temporaries are pushed;
  every local, parameter and aggregate temporary has a fixed `rbp` slot assigned before
  the body is generated. Machine code comes from small byte templates.
- **Calling convention.** Arguments are pushed left to right (8 bytes per scalar, 16
  per `str`, the size rounded up to 8 per aggregate), then the address of the result
  slot when a struct or array is returned. The caller pops everything; results come back
  in `rax`(/`rdx`). Built-ins use the same convention.
- **Run-time checks.** Values are kept canonical (sign- or zero-extended to 64 bits),
  so overflow is the CPU's overflow/carry flag for 64-bit types and "does it survive
  re-normalization" for narrower ones. Bounds, division and shift checks are compares.
  Every failing check jumps to a shared stub that calls the runtime's trap entry, which
  prints `panic: <reason>` and exits with 101.
- **Image layout.** One section: [runtime block][trap stubs][functions][data], with
  data reached RIP-relative (fixups resolved once the code size is known) and absolute
  addresses (a `static str`'s pointer) filled in once the image address is known.
  Hello world is 8 KB on Windows.

## Testing

- `tests/golden/lexer/*.envol` → `*.tokens`: exact token dumps.
- `tests/golden/parser/*.envol` → `*.ast`: exact syntax tree dumps.
- `tests/golden/check/*.envol` → `*.check`: typed trees with layouts and constant values.
- `tests/spec/core-run/`: programs compiled with `envoc0 build` and run; stdout, exit
  code and panic message must match.
- `tests/spec/01-lexical/`, `core-syntax/` and `core-types/`: one error each,
  with `// expect-error: EXXXX @ line:col`.
- `tests/spec/core-multi/`: one folder per multi-file program; `main.envol` is the entry
  file and says either what the program prints or which error is reported in which file.

The runners are in `bootstrap.ps1` and `bootstrap.sh` (OS tools only). Both binaries are
assembled on every host; each host runs its native one.
