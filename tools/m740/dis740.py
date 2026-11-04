"""Recursive-descent disassembler for Mitsubishi MELPS 740 code (6502 superset).

Written for the LD-V4300D mechanism-control EPROM (DYW1362 PAL / DYW1385 NTSC),
which is mapped at $8000-$FFFF on the CONT assembly IC1 bus.

Usage:
  dis740.py <rom.bin> [--base 0x8000] [--entry 0xADDR ...] > listing.asm

Entry points default to every vector in $FFF4-$FFFF (the vector block this
ROM populates). Code reached from those is disassembled; everything else is
emitted as `.byte` data so nothing in the image is hidden.

The T flag (SET/CLT) changes ALU ops to operate on (X) instead of A; the
encoding is identical, so it does not affect disassembly, only semantics.
"""
import argparse
import sys

# Addressing modes -> (operand length, formatter)
IMP, ACC, IMM, ZP, ZPX, ZPY, ABS, ABX, ABY, IND, IZX, IZY, REL, ZIND, SPG, \
    BBA, BBZ, LDM = range(18)
LEN = {IMP: 0, ACC: 0, IMM: 1, ZP: 1, ZPX: 1, ZPY: 1, ABS: 2, ABX: 2, ABY: 2,
       IND: 2, IZX: 1, IZY: 1, REL: 1, ZIND: 1, SPG: 1, BBA: 1, BBZ: 2, LDM: 2}

OPS = {}


def op(code, mnem, mode):
    OPS[code] = (mnem, mode)


# --- 6502 base set (as present on the 740) ---
for base, m in ((0x00, 'ORA'), (0x20, 'AND'), (0x40, 'EOR'), (0x60, 'ADC'),
                (0xC0, 'CMP'), (0xE0, 'SBC')):
    op(base + 0x01, m, IZX); op(base + 0x05, m, ZP); op(base + 0x09, m, IMM)
    op(base + 0x0D, m, ABS); op(base + 0x11, m, IZY); op(base + 0x15, m, ZPX)
    op(base + 0x19, m, ABY); op(base + 0x1D, m, ABX)
op(0x81, 'STA', IZX); op(0x85, 'STA', ZP); op(0x8D, 'STA', ABS); op(0x91, 'STA', IZY)
op(0x95, 'STA', ZPX); op(0x99, 'STA', ABY); op(0x9D, 'STA', ABX)
op(0xA1, 'LDA', IZX); op(0xA5, 'LDA', ZP); op(0xA9, 'LDA', IMM); op(0xAD, 'LDA', ABS)
op(0xB1, 'LDA', IZY); op(0xB5, 'LDA', ZPX); op(0xB9, 'LDA', ABY); op(0xBD, 'LDA', ABX)
for base, m in ((0x00, 'ASL'), (0x20, 'ROL'), (0x40, 'LSR'), (0x60, 'ROR')):
    op(base + 0x06, m, ZP); op(base + 0x0A, m, ACC); op(base + 0x0E, m, ABS)
    op(base + 0x16, m, ZPX); op(base + 0x1E, m, ABX)
op(0xC6, 'DEC', ZP); op(0xCE, 'DEC', ABS); op(0xD6, 'DEC', ZPX); op(0xDE, 'DEC', ABX)
op(0xE6, 'INC', ZP); op(0xEE, 'INC', ABS); op(0xF6, 'INC', ZPX); op(0xFE, 'INC', ABX)
op(0x24, 'BIT', ZP); op(0x2C, 'BIT', ABS)
op(0xA0, 'LDY', IMM); op(0xA4, 'LDY', ZP); op(0xAC, 'LDY', ABS); op(0xB4, 'LDY', ZPX); op(0xBC, 'LDY', ABX)
op(0xA2, 'LDX', IMM); op(0xA6, 'LDX', ZP); op(0xAE, 'LDX', ABS); op(0xB6, 'LDX', ZPY); op(0xBE, 'LDX', ABY)
op(0x84, 'STY', ZP); op(0x8C, 'STY', ABS); op(0x94, 'STY', ZPX)
op(0x86, 'STX', ZP); op(0x8E, 'STX', ABS); op(0x96, 'STX', ZPY)
op(0xC0, 'CPY', IMM); op(0xC4, 'CPY', ZP); op(0xCC, 'CPY', ABS)
op(0xE0, 'CPX', IMM); op(0xE4, 'CPX', ZP); op(0xEC, 'CPX', ABS)
for code, m in ((0x10, 'BPL'), (0x30, 'BMI'), (0x50, 'BVC'), (0x70, 'BVS'), (0x90, 'BCC'),
                (0xB0, 'BCS'), (0xD0, 'BNE'), (0xF0, 'BEQ'), (0x80, 'BRA')):
    op(code, m, REL)
op(0x4C, 'JMP', ABS); op(0x6C, 'JMP', IND); op(0x20, 'JSR', ABS)
for code, m in ((0x00, 'BRK'), (0x08, 'PHP'), (0x18, 'CLC'), (0x28, 'PLP'), (0x38, 'SEC'),
                (0x40, 'RTI'), (0x48, 'PHA'), (0x58, 'CLI'), (0x60, 'RTS'), (0x68, 'PLA'),
                (0x78, 'SEI'), (0x88, 'DEY'), (0x8A, 'TXA'), (0x98, 'TYA'), (0x9A, 'TXS'),
                (0xA8, 'TAY'), (0xAA, 'TAX'), (0xB8, 'CLV'), (0xBA, 'TSX'), (0xC8, 'INY'),
                (0xCA, 'DEX'), (0xD8, 'CLD'), (0xE8, 'INX'), (0xEA, 'NOP'), (0xF8, 'SED')):
    op(code, m, IMP)

# --- 740 extensions ---
for n in range(8):
    op(n * 0x20 + 0x03, 'BBS%d' % n, BBA); op(n * 0x20 + 0x07, 'BBS%d' % n, BBZ)
    op(n * 0x20 + 0x13, 'BBC%d' % n, BBA); op(n * 0x20 + 0x17, 'BBC%d' % n, BBZ)
    op(n * 0x20 + 0x0B, 'SEB%d' % n, ACC); op(n * 0x20 + 0x0F, 'SEB%d' % n, ZP)
    op(n * 0x20 + 0x1B, 'CLB%d' % n, ACC); op(n * 0x20 + 0x1F, 'CLB%d' % n, ZP)
op(0x02, 'JSR', ZIND); op(0x22, 'JSR', SPG); op(0xB2, 'JMP', ZIND)
op(0x12, 'CLT', IMP); op(0x32, 'SET', IMP); op(0x42, 'STP', IMP); op(0xC2, 'WIT', IMP)
op(0x1A, 'DEC', ACC); op(0x3A, 'INC', ACC)
op(0x3C, 'LDM', LDM); op(0x44, 'COM', ZP); op(0x64, 'TST', ZP); op(0x82, 'RRF', ZP)
op(0x62, 'MUL', ZPX); op(0xE2, 'DIV', ZPX)  # 7450-series only; flagged if seen

FLOW_END = {'RTS', 'RTI', 'BRK', 'STP'}
VECTORS = {0xFFF4: 'VEC_FFF4', 0xFFF6: 'VEC_FFF6', 0xFFF8: 'VEC_FFF8',
           0xFFFA: 'VEC_FFFA', 0xFFFC: 'VEC_FFFC', 0xFFFE: 'RESET'}


class Rom:
    def __init__(self, data, base):
        self.d, self.base = data, base

    def has(self, a):
        return self.base <= a < self.base + len(self.d)

    def b(self, a):
        return self.d[a - self.base]

    def w(self, a):
        return self.b(a) | (self.b(a + 1) << 8)


def decode(rom, pc):
    """Return (mnem, mode, length, operand_value(s), targets, falls_through)."""
    o = rom.b(pc)
    if o not in OPS:
        return None
    mnem, mode = OPS[o]
    n = LEN[mode]
    if not rom.has(pc + n):
        return None
    raw = [rom.b(pc + 1 + i) for i in range(n)]
    targets, falls = [], mnem not in FLOW_END
    if mode == REL:
        t = (pc + 2 + ((raw[0] ^ 0x80) - 0x80)) & 0xFFFF
        targets.append(t)
        if mnem == 'BRA':
            falls = False
    elif mode in (BBA, BBZ):
        t = (pc + 1 + n + ((raw[-1] ^ 0x80) - 0x80)) & 0xFFFF
        targets.append(t)
    elif mnem in ('JMP', 'JSR') and mode == ABS:
        targets.append(raw[0] | raw[1] << 8)
        if mnem == 'JMP':
            falls = False
    elif mnem == 'JSR' and mode == SPG:
        targets.append(0xFF00 | raw[0])
    elif mnem == 'JMP' and mode in (IND, ZIND):
        falls = False
    return mnem, mode, n + 1, raw, targets, falls


def fmt(mnem, mode, raw, pc, labels):
    def lab(a):
        return labels.get(a, '$%04X' % a)
    if mode in (IMP,):
        return mnem
    if mode == ACC:
        return mnem + ' A'
    if mode == IMM:
        return '%s #$%02X' % (mnem, raw[0])
    if mode == ZP:
        return '%s $%02X' % (mnem, raw[0])
    if mode == ZPX:
        return '%s $%02X,X' % (mnem, raw[0])
    if mode == ZPY:
        return '%s $%02X,Y' % (mnem, raw[0])
    w = raw[0] | (raw[1] << 8) if len(raw) >= 2 else 0
    if mode == ABS:
        return '%s %s' % (mnem, lab(w) if mnem in ('JMP', 'JSR') else '$%04X' % w)
    if mode == ABX:
        return '%s $%04X,X' % (mnem, w)
    if mode == ABY:
        return '%s $%04X,Y' % (mnem, w)
    if mode == IND:
        return '%s ($%04X)' % (mnem, w)
    if mode == IZX:
        return '%s ($%02X,X)' % (mnem, raw[0])
    if mode == IZY:
        return '%s ($%02X),Y' % (mnem, raw[0])
    if mode == ZIND:
        return '%s ($%02X)' % (mnem, raw[0])
    if mode == SPG:
        return '%s \\$%02X' % (mnem, raw[0])
    if mode == REL:
        return '%s %s' % (mnem, lab((pc + 2 + ((raw[0] ^ 0x80) - 0x80)) & 0xFFFF))
    if mode == BBA:
        return '%s A,%s' % (mnem, lab((pc + 2 + ((raw[0] ^ 0x80) - 0x80)) & 0xFFFF))
    if mode == BBZ:
        return '%s $%02X,%s' % (mnem, raw[0], lab((pc + 3 + ((raw[1] ^ 0x80) - 0x80)) & 0xFFFF))
    if mode == LDM:
        return '%s #$%02X,$%02X' % (mnem, raw[0], raw[1])
    return mnem


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom')
    ap.add_argument('--base', type=lambda s: int(s, 0), default=0x8000)
    ap.add_argument('--entry', type=lambda s: int(s, 0), action='append', default=[])
    a = ap.parse_args()
    rom = Rom(open(a.rom, 'rb').read(), a.base)

    labels, code, insn = {}, set(), {}
    work = []
    for v, name in VECTORS.items():
        if rom.has(v + 1):
            t = rom.w(v)
            if rom.has(t):
                labels.setdefault(t, name)
                work.append(t)
    for e in a.entry:
        labels.setdefault(e, 'ENTRY_%04X' % e)
        work.append(e)

    xrefs = {}
    while work:
        pc = work.pop()
        while rom.has(pc) and pc not in insn:
            r = decode(rom, pc)
            if r is None or any(pc + i in code for i in range(1, r[2])):
                break
            mnem, mode, ln, raw, targets, falls = r
            insn[pc] = r
            code.update(range(pc, pc + ln))
            for t in targets:
                xrefs.setdefault(t, set()).add(pc)
                if rom.has(t):
                    pre = 'SUB' if mnem == 'JSR' else 'L'
                    labels.setdefault(t, '%s_%04X' % (pre, t))
                    work.append(t)
            if not falls:
                break
            pc += ln

    out = sys.stdout
    out.write('; MELPS 740 disassembly of %s (base $%04X)\n' % (a.rom, a.base))
    out.write('; code bytes: %d / %d\n' % (len(code), len(rom.d)))
    pc, end = a.base, a.base + len(rom.d)
    while pc < end:
        if pc in insn:
            mnem, mode, ln, raw, _, _ = insn[pc]
            if pc in labels:
                xr = xrefs.get(pc)
                out.write('\n%s:%s\n' % (labels[pc], ('  ; xref ' + ' '.join('$%04X' % x for x in sorted(xr)[:8])) if xr else ''))
            bytes_ = ' '.join('%02X' % rom.b(pc + i) for i in range(ln))
            out.write('  %04X  %-9s  %s\n' % (pc, bytes_, fmt(mnem, mode, raw, pc, labels)))
            pc += ln
        else:
            s = pc
            while pc < end and pc not in insn and pc - s < 16:
                pc += 1
            if s in labels:
                out.write('\n%s:\n' % labels[s])
            out.write('  %04X  .byte %s\n' % (s, ','.join('$%02X' % rom.b(x) for x in range(s, pc))))


if __name__ == '__main__':
    main()
