# Stage 0 compiler sources

> **Status:** In progress (M1): runtime helpers and lexer written; parser and code generator next.

The platform-independent part of `envoc0`, in `.eas`. One file per concern: `mem.eas` (arena), `io.eas` (buffered output, file reading), `diag.eas` (diagnostics), `utf8.eas`, `tokens.eas` (token kinds), `lexer.eas`, `main.eas` (commands). Later: `parser.eas`, `check.eas`, `codegen.eas`, and the *output* writers `pe.eas` / `elf.eas`. See `bootstrap/stage0/README.md`.
