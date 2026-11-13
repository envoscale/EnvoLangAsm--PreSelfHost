#!/bin/sh
# Phase A bootstrap adapter: assemble one .eas unit with NASM in flat-binary mode.
# Usage: assemble.sh <input.eas> <output-file> <include-dir>
# This is the only file in the repository that knows NASM exists (besides assemble.ps1).
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: assemble.sh <input.eas> <output-file> <include-dir>" >&2
    exit 2
fi

nasm_bin=${NASM:-}
if [ -z "$nasm_bin" ]; then
    nasm_bin=$(command -v nasm 2>/dev/null || true)
fi
if [ -z "$nasm_bin" ]; then
    echo "error: NASM not found. Install it (e.g. 'sudo apt-get install nasm') or set NASM=/path/to/nasm." >&2
    echo "       See adapters/bootstrap/nasm/README.md" >&2
    exit 127
fi

# NASM requires the include prefix to end with a path separator.
inc=${3%/}/
# In EAS a `near` jump is always rel32 (docs/spec/eas.md). NASM 3.01 treats `near` as a
# hint and shortens jumps that fit in rel8; "strict near" keeps the EAS meaning in every
# NASM version, and leaves the bytes of versions that already honour `near` unchanged.
exec "$nasm_bin" -f bin -w+all "-dnear=strict near" -I "$inc" -o "$2" "$1"
