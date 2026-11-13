# Generates seed/src/data.eas: asm0's register, condition and mnemonic tables, its
# messages and its state. The output is checked in; run this after changing the lists.
import os

HERE = os.path.dirname(os.path.abspath(__file__))
lines = []
A = lines.append
A('; =============================================================================')
A("; seed/src/data.eas - asm0's tables, messages and state (made by seed/mkdata.py)")
A('; =============================================================================')
A('')
A('        align   8, db 0')
A('; ---------------------------------------------------------------- registers')
A('reg_table:')
r64 = ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi'] + ['r%d' % i for i in range(8, 16)]
r32 = ['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi'] + ['r%dd' % i for i in range(8, 16)]
r16 = ['ax', 'cx', 'dx', 'bx', 'sp', 'bp', 'si', 'di'] + ['r%dw' % i for i in range(8, 16)]
r8 = ['al', 'cl', 'dl', 'bl', 'spl', 'bpl', 'sil', 'dil'] + ['r%db' % i for i in range(8, 16)]


def ent(n, num, size, rex8):
    pad = 8 - len(n)
    zeros = (', ' + ', '.join(['0'] * pad)) if pad else ''
    A("        db      '%s'%s, %d, %d, %d, %d, 0, 0, 0, 0" % (n, zeros, len(n), num, size, rex8))


for i, n in enumerate(r64):
    ent(n, i, 8, 0)
for i, n in enumerate(r32):
    ent(n, i, 4, 0)
for i, n in enumerate(r16):
    ent(n, i, 2, 0)
for i, n in enumerate(r8):
    ent(n, i, 1, 1 if n in ('spl', 'bpl', 'sil', 'dil') else 0)
A('        times 16 db 0                   ; the end')
A('')
A('; ---------------------------------------------------------------- conditions')
A('; name[4], length, code, padding')
A('cond_table:')
conds = [('o', 0), ('no', 1), ('b', 2), ('c', 2), ('nae', 2), ('ae', 3), ('nb', 3), ('nc', 3), ('e', 4), ('z', 4),
         ('ne', 5), ('nz', 5), ('be', 6), ('na', 6), ('a', 7), ('nbe', 7), ('s', 8), ('ns', 9), ('p', 10), ('pe', 10),
         ('np', 11), ('po', 11), ('l', 12), ('nge', 12), ('ge', 13), ('nl', 13), ('le', 14), ('ng', 14), ('g', 15), ('nle', 15)]
for n, c in conds:
    pad = 4 - len(n)
    zeros = (', ' + ', '.join(['0'] * pad)) if pad else ''
    A("        db      '%s'%s, %d, %d, 0, 0" % (n, zeros, len(n), c))
A('        times 8 db 0')
A('')
A('; ---------------------------------------------------------------- mnemonics')
A('; name, length, handler, argument')
A('        align   8, db 0')
A('mnemonics:')
mn = [('add', 'h_alu', '0'), ('or', 'h_alu', '1'), ('adc', 'h_alu', '2'), ('sbb', 'h_alu', '3'), ('and', 'h_alu', '4'),
      ('sub', 'h_alu', '5'), ('xor', 'h_alu', '6'), ('cmp', 'h_alu', '7'),
      ('mov', 'h_mov', '0'), ('movzx', 'h_movx', '0xB6'), ('movsx', 'h_movx', '0xBE'), ('movsxd', 'h_movsxd', '0'),
      ('lea', 'h_lea', '0'), ('test', 'h_test', '0'), ('xchg', 'h_xchg', '0'),
      ('inc', 'h_group', '0xFF00'), ('dec', 'h_group', '0xFF01'), ('not', 'h_group', '0xF702'), ('neg', 'h_group', '0xF703'),
      ('mul', 'h_group', '0xF704'), ('div', 'h_group', '0xF706'), ('idiv', 'h_group', '0xF707'), ('imul', 'h_imul', '0'),
      ('rol', 'h_shift', '0'), ('ror', 'h_shift', '1'), ('shl', 'h_shift', '4'), ('shr', 'h_shift', '5'), ('sar', 'h_shift', '7'),
      ('push', 'h_push', '0'), ('pop', 'h_push', '1'), ('call', 'h_call', '0'),
      ('ret', 'h_fixed', '0x01000000000000C3'), ('syscall', 'h_fixed', '0x020000000000050F'), ('nop', 'h_fixed', '0x0100000000000090'),
      ('ud2', 'h_fixed', '0x0200000000000B0F'), ('int3', 'h_fixed', '0x01000000000000CC'), ('hlt', 'h_fixed', '0x01000000000000F4'),
      ('cqo', 'h_fixed', '0x0200000000009948'), ('cdq', 'h_fixed', '0x0100000000000099'), ('cdqe', 'h_fixed', '0x0200000000009848'),
      ('lodsb', 'h_fixed', '0x01000000000000AC')]
for n, h, a in mn:
    A('        dq      s_m_%s, %d, %s, %s' % (n, len(n), h, a))
A('        dq      0, 0, 0, 0')
A('')
for n, h, a in mn:
    A("s_m_%s:%sdb '%s'" % (n, ' ' * (9 - len(n)), n))
A('')
A('; ---------------------------------------------------------------- words')
words = ['equ', 'include', 'bits', 'default', 'org', 'align', 'times', 'byte', 'word', 'dword', 'qword', 'rep', 'movsb',
         'stosb', 'short', 'near', 'jmp', 'set', 'cmov']
for w in words:
    A("s_%s:%sdb '%s'" % (w, ' ' * (10 - len(w)), w))
A('')
A('; ---------------------------------------------------------------- messages')
msgs = [('usage', 'usage: asm0 <file.eas> <output>', True), ('write', 'cannot write the output', False),
        ('passes', 'the passes disagree on the size', False), ('deep', '%include nested too deeply', False),
        ('read', 'asm0: cannot read ', False), ('prefix', 'asm0: ', False), ('long', 'line or name too long', False),
        ('char', 'unexpected character', False), ('string', 'unterminated string', False), ('twice', 'a name defined twice', False),
        ('moved', 'a label moved between the passes (an instruction changed size)', False),
        ('div', 'division by zero in an expression', False), ('expr', 'malformed expression', False),
        ('undefined', 'undefined name', False), ('syntax', 'syntax error', False),
        ('extra', 'unexpected text after the statement', False), ('full', 'output larger than 16 MiB', False),
        ('org', 'org after output', False), ('align', 'align takes n, db 0', False),
        ('times', 'times takes a known count and a data directive', False), ('operand', 'bad operands', False),
        ('mnemonic', 'unknown instruction', False), ('jump_size', 'a jump must say short or near', False),
        ('far', 'short jump out of range', False)]
for k, t, nl in msgs:
    if nl:
        A("msg_%s:%sdb '%s', 10" % (k, ' ' * (10 - len(k)), t))
    else:
        A("msg_%s:%sdb '%s'" % (k, ' ' * (10 - len(k)), t))
    A('msg_%s_len%sequ $ - msg_%s' % (k, ' ' * (10 - len(k)), k))
A("msg_colon:      db ': '")
A('')
A('; ---------------------------------------------------------------- state')
A('        align   8, db 0')
state = ['g_pass', 'g_addr', 'g_org', 'g_here', 'g_stmt', 'g_size', 'g_seen_out', 'g_known', 'g_syms', 'g_out', 'g_toks',
         'g_ntok', 'g_top', 'g_dir_len', 'g_depth', 'g_file', 'g_line', 'g_global', 'g_global_len', 'g_nops', 'g_ilen',
         'g_rip_at', 'g_rip_target']
for v in state:
    A('%s:%sdq 0' % (v, ' ' * (15 - len(v))))
A('g_ib:           times 32 db 0')
A('g_ops:          times 192 db 0')
A('g_name:         times 512 db 0')
open(os.path.join(HERE, 'src', 'data.eas'), 'w', encoding='utf-8', newline='\n').write('\n'.join(lines) + '\n')
