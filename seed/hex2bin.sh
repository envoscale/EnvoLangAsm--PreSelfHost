#!/bin/sh
# hex2bin.sh <file.hex> <output>: the bytes written as hex digits in file.hex, with
# comments (# to the end of a line) and spaces ignored. POSIX sh, sed, tr, awk and
# printf only: the seed (PLAN D67) needs nothing that is not already on the system.
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: hex2bin.sh <file.hex> <output>" >&2
    exit 2
fi
digits=$(sed -e 's/#.*//' "$1" | tr -d ' \t\r\n')
case "$digits" in
    *[!0-9A-Fa-f]*) echo "hex2bin: $1 has something other than hex digits outside comments" >&2; exit 1 ;;
esac
if [ $(( ${#digits} % 2 )) -ne 0 ]; then
    echo "hex2bin: $1 has an odd number of hex digits" >&2
    exit 1
fi
# awk turns each pair into an octal escape; printf writes the bytes (NUL included).
# 4096 bytes per printf keeps each argument short.
printf '%s' "$digits" | awk '
    BEGIN { hex = "0123456789abcdef" }
    {
        s = tolower($0); n = 0; line = ""
        for (i = 1; i <= length(s); i += 2) {
            v = (index(hex, substr(s, i, 1)) - 1) * 16 + index(hex, substr(s, i + 1, 1)) - 1
            line = line sprintf("\\%03o", v)
            n++
            if (n == 4096) { print line; line = ""; n = 0 }
        }
        if (n > 0) print line
    }' | while IFS= read -r chunk; do printf "$chunk"; done > "$2"
