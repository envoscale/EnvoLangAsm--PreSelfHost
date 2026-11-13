# EnvoScaleAsm

The Envo compiler, built up from assembly.

[EnvoScale](https://github.com/envoscale/EnvoScale) compiles itself. A compiler that
compiles itself has to start from *some* binary, and you have to trust that binary. This
repository is how you don't have to: it rebuilds the Envo compiler from a few kilobytes of
assembly you can read, and checks the result.

```
seed/     asm0, a tiny assembler written as hex you can check by eye
  ↓ assembles
stage0/   envoc0, a compiler for a small subset of Envo, in x86-64 assembly
  ↓ compiles
stage1/   envoc1, a bigger compiler, written in that subset
  ↓ compiles
EnvoScale's compiler/   envoc, the real compiler
  ↓ compiles itself, twice; both copies must be the same bytes
```

Each step is small enough to read in an afternoon, and each is built by the one before.
Stage 0 builds the same way with NASM or with the hex seed, and Linux and Windows produce
byte-identical compilers.

## Use

```bash
./bootstrap.sh test
```

On Windows, without Git Bash:

```powershell
.\bootstrap.ps1 test
```

This clones EnvoScale at the commit in [`envoscale.ref`](envoscale.ref) into `envoscale/`
(set `ENVOSCALE` to use a checkout you already have), builds every stage, and runs their
tests. NASM is used if it is installed; otherwise the hex seed does the assembling.

| Command | What it does |
|---|---|
| `build` | stage 0, then stage 1, then EnvoScale's compiler |
| `test` | build, then the stage 0 and 1 tests, and checks the compiler built by stage 1 behaves exactly as the one built by itself |
| `fixedpoint` | build, then the compiler compiles itself twice; the two must match |
| `seed` | fixedpoint, then the compilers EnvoScale starts from, in `build/seed-release` |
| `compare <a> <b>` | two builds must be byte-identical |

## The seed

EnvoScale's build downloads its starting compiler from this repository's
[releases](https://github.com/envoscale/EnvoScaleAsm/releases). Each `seed-*` release is
built by CI from this repository on Linux and Windows, and is only published when both
hosts produced the same bytes. You can rebuild it yourself with `./bootstrap.sh seed` and
compare against `SHA256SUMS`.

## More

- [docs/bootstrap.md](docs/bootstrap.md): how the stages fit together and why
- [docs/stage1.md](docs/stage1.md): the stage 1 compiler
- [docs/eas.md](docs/eas.md): the assembly dialect stage 0 is written in
- [seed/README.md](seed/README.md), [stage0/README.md](stage0/README.md), [stage1/README.md](stage1/README.md)

## License

Same as EnvoScale: see [LICENSE](LICENSE).
