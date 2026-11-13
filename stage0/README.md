# Stage 0: `envoc0`

> **Status:** In progress (M1). `envoc0 build` compiles Envo-Core programs to working
> x86-64 executables for Windows and Linux; lexer, parser, checker, code generator and
> writers are all tested. What remains of M1 is a broader Envo-Core test suite.
> See [the README](../README.md) for how it is tested.

`envoc0` compiles **Envo-Core** ([Envo-Core](https://github.com/envoscale/EnvoLang/blob/main/spec/envo-core.md))
to x86-64 executables for Windows (PE) and Linux (ELF). It is written in `.eas`
([`docs/eas.md`](https://github.com/envoscale/EnvoScale/blob/main/bootstrap/eas.md)), a strict subset of NASM syntax, and has
no dependencies beyond the OS.

Goal: **correct, small and auditable, not fast.** Target: under ~15k lines of
heavily commented assembly, single- or two-pass, no optimizer.

## Build and test

From the repository root:

```powershell
.\bootstrap.ps1 build     # Windows
.\bootstrap.ps1 test
```

```sh
./bootstrap.sh build      # Linux
./bootstrap.sh test
```

## Layout

| File | Purpose |
|---|---|
| `envoc0-windows.eas` | Top-level unit for Windows; includes everything below |
| `envoc0-linux.eas` | Top-level unit for Linux |
| `platform/windows.eas` | Windows runtime block: kernel32 imports, shim, argv parsing, built-ins |
| `platform/linux.eas` | Linux runtime block: syscall shim, built-ins |
| `src/main.eas` | Command dispatch |
| `src/mem.eas` | Arena allocator and memory helpers |
| `src/io.eas` | Buffered stdout/stderr, decimal output, file reading, exit |
| `src/diag.eas` | Diagnostics with line and column |
| `src/utf8.eas` | UTF-8 validation |
| `src/tokens.eas` | Token kinds and the kind table |
| `src/nodes.eas` | Syntax tree node kinds and parser lookup tables |
| `src/lexer.eas` | The lexer |
| `src/parser.eas` | The parser and the syntax tree printer |
| `src/check.eas` | Names, types, layouts and constants (the checker) |
| `src/codegen.eas` | x86-64 code generation |
| `src/writer.eas` | PE/ELF output and `envoc0 build` |
| `platform/pe.eas`, `platform/elf.eas` | envoc0's own executable headers |
| `platform/runtime-abi.eas` | The interface between compiled code and the runtime blocks |

How it fits together, and why it is built this way:
[`docs/bootstrap.md`](https://github.com/envoscale/EnvoScale/blob/main/bootstrap/bootstrap.md).

## Usage (today)

```
envoc0 lex <file.envol>     print the token stream
envoc0 parse <file.envol>   print the syntax tree
envoc0 check <file.envol>   check names and types; print the typed tree
envoc0 build <file.envol> -o <exe> [--target x86_64-windows|x86_64-linux]
envoc0 version             print the version
envoc0 help                print usage
```
