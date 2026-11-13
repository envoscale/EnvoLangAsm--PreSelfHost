# Writes seed-<os>.hex: asm0's bytes as commented hexadecimal, each statement's bytes on
# a line with its offset and its source line from NASM's listing. The hex files are
# checked in; CI checks that asm0 built from them assembles asm0-<os>.eas to the same
# bytes, so the hex is exactly the documented source.
#
#   python mkhex.py <os> <asm0 binary> <NASM listing>     (os: linux or windows)
import re
import sys

os_name, binary, listing = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(binary, 'rb').read()
starts = {}
for line in open(listing, encoding='latin-1'):
    m = re.match(r'\s*\d+\s+([0-9A-F]{8})\s+([0-9A-F]+)-?\s*(?:<\d+>)?\s*(.*)$', line)
    if not m:
        continue
    off = int(m.group(1), 16)
    src = m.group(3).strip()
    if off not in starts and src:
        src = re.sub(r'\s+', ' ', src.split(';')[0]).strip()
        if src:
            starts[off] = src

out = []
out.append('# seed-%s.hex - asm0, the seed assembler, for x86-64 %s, as commented' % (os_name, os_name.capitalize()))
out.append('# hexadecimal (PLAN D67). Made from bootstrap/seed/asm0-%s.eas by mkhex.py.' % os_name)
out.append('#')
out.append('# A comment runs from # to the end of the line; everything else is pairs of hex')
out.append('# digits, the bytes of the program in order. Each line starts with the bytes of')
out.append('# one statement; the comment gives its file offset and source. Turn it into the')
out.append('# program with the OS alone:')
out.append('#     sh hex2bin.sh seed-%s.hex asm0          (POSIX sh, awk, printf)' % os_name)
out.append('#     .\\hex2bin.ps1 seed-%s.hex asm0.exe     (PowerShell)' % os_name)
out.append('# CI checks that this asm0 assembles asm0-%s.eas to exactly these bytes, and' % os_name)
out.append('# Stage 0 to exactly the bytes NASM gives.')
out.append('')
points = sorted(o for o in starts if o < len(data))
if not points or points[0] != 0:
    points = [0] + points
points.append(len(data))
for k in range(len(points) - 1):
    a, b = points[k], points[k + 1]
    chunk = data[a:b]
    comment = starts.get(a, '')
    first = True
    for i in range(0, len(chunk), 16):
        piece = chunk[i:i + 16].hex().upper()
        if first:
            out.append('%-34s # %06X %s' % (piece, a, comment))
            first = False
        else:
            out.append(piece)
open('seed-%s.hex' % os_name, 'w', encoding='ascii', newline='\n').write('\n'.join(out) + '\n')
print('seed-%s.hex: %d bytes, %d lines' % (os_name, len(data), len(out)))
