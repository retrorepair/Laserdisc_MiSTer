"""Generate the OSD ROM images for core/rtl/osd_m50552.v from tools/osd/font_cld1750.json.

  core/rtl/osd_font.hex    : 2048 x 12 bits, addr = {code[6:0], glyph_row[3:0]}; bit 11 = leftmost dot.
                             Rows 14/15 are zero. Codes are ASCII; unknown codes are blank.
  core/rtl/osd_screens.hex : 8 x 512 x 7 bits, addr = {screen[2:0], cell[8:0]}, cell = row*24 + col
                             (cells 288..511 unused). Screens as driven by core/rtl/player.v (docs/player_logic.md):
                             0 none, 1 disc info, 2 PAUSE, 3 STOP, 4 CLOSE, 5 PLAY (spin-up), 6 OPEN (EST), 7 spare.

Glyph provenance: font_cld1750.json statuses confirmed/direct/photo are used as is; 'review'
glyphs (B F H N O V) and the mock-up GUESS glyphs (tools/osd/mockup.py) fill the gaps and are
listed by this script so nothing guessed is hidden.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mockup  # noqa: E402

RTL = os.path.join(HERE, '..', '..', 'core', 'rtl')


# player screens (positions from footage F1/F3; docs/player_logic.md)
PLAYER_SCREENS = {
    1: [(0, 0, 'LASERDISC'), (1, 1, '-PAL-'), (0, 17, 'PLAY'), (1, 17, 'SIDE -A')],
    2: [(0, 17, 'PAUSE')],
    3: [(0, 17, 'STOP')],
    4: [(0, 17, 'CLOSE')],
    5: [(0, 17, 'PLAY')],
    6: [(0, 17, 'OPEN')],
}


def main():
    font = json.load(open(os.path.join(HERE, 'font_cld1750.json')))['glyphs']
    glyphs, provenance = {}, {}
    for ch, g in font.items():
        glyphs[ch] = g['bits']
        provenance[ch] = g['status']
    for ch, bits in mockup.GUESS.items():
        if ch not in glyphs or provenance.get(ch) == 'review':
            if ch != ' ' and ch not in glyphs:
                provenance[ch] = 'GUESS'
            glyphs.setdefault(ch, bits)
            if provenance.get(ch) == 'review' and ch in ('H', 'F'):
                glyphs[ch] = bits                           # review photo glyph worse than the style guess
                provenance[ch] = 'GUESS'
    glyphs[' '] = ['.' * 12] * 14
    with open(os.path.join(RTL, 'osd_font.hex'), 'w') as o:
        for code in range(128):
            bits = glyphs.get(chr(code))
            for row in range(16):
                v = 0
                if bits and row < 14:
                    for x, c in enumerate(bits[row]):
                        if c == '#':
                            v |= 1 << (11 - x)
                o.write('%03x\n' % v)
    with open(os.path.join(RTL, 'osd_screens.hex'), 'w') as o:
        for sid in range(8):
            cells = [0x20] * 512
            for r, c, text in PLAYER_SCREENS.get(sid, []):
                for i, ch in enumerate(text):
                    cells[r * 24 + c + i] = ord(ch)
            for v in cells:
                o.write('%02x\n' % v)
    used = sorted(set(''.join(t for s in PLAYER_SCREENS.values() for _, _, t in s)) - {' '})
    print('glyphs used by the test screens and their status:')
    for ch in used:
        print('  %r: %s' % (ch, provenance.get(ch, 'MISSING')))


if __name__ == '__main__':
    main()
