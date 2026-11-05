"""Generate the OSD ROM images for core/rtl/osd_m50552.v from tools/osd/font_cld1750.json.

  core/rtl/osd_font.hex    : 2048 x 12 bits, addr = {code[6:0], glyph_row[3:0]}; bit 11 = leftmost dot.
                             Rows 14/15 are zero. Codes are ASCII; unknown codes are blank.
  core/rtl/osd_screens.hex : 4 languages x 8 screens x 512 x 7 bits, addr = {lang[1:0], screen[2:0], cell[8:0]},
                             cell = row*24 + col (cells 288..511 unused). Screens as driven by core/rtl/player.v
                             (docs/player_logic.md): 0 none, 1 disc info, 2 PAUSE, 3 STOP, 4 CLOSE, 5 PLAY (spin-up),
                             6 OPEN, 7 the variable text (written by core/rtl/osd_text.v; language 0's copy is used).
                             Languages (LANGUAGE button, European OM p.40): English, French, German, Italian, with the
                             words of the OM's display tables (p.44-45): OUVERT/AUF/APERTO, FERME/ZU/CHIUSO,
                             ARRET/STOP/STOP, LECTURE/WIEDERG/RIPROD, PAUSE/PAUSE/PAUSA; the side word from the
                             one-side-repeat words (FACE/SEITE/LATO). LASERDISC has no translation in the OM.

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


# player screens (positions from footage F1/F3; docs/player_logic.md), per language (OM p.44-45 words)
WORDS = {   # play, pause, stop, close, open, side (the side word's column: 'SEITE -A' needs 8 cells, from 16: EST)
    0: ('PLAY', 'PAUSE', 'STOP', 'CLOSE', 'OPEN', 'SIDE -A', 17),
    1: ('LECTURE', 'PAUSE', 'ARRET', 'FERME', 'OUVERT', 'FACE -A', 17),
    2: ('WIEDERG', 'PAUSE', 'STOP', 'ZU', 'AUF', 'SEITE -A', 16),
    3: ('RIPROD', 'PAUSA', 'STOP', 'CHIUSO', 'APERTO', 'LATO -A', 17),
}
def player_screens(lang):
    play, pause, stop, close, open_, side, sc = WORDS[lang]
    return {
        1: [(0, 0, 'LASERDISC'), (1, 1, '-PAL-'), (0, 17, play), (1, sc, side)],
        2: [(0, 17, pause)],
        3: [(0, 17, stop)],
        4: [(0, 17, close)],
        5: [(0, 17, play)],
        6: [(0, 17, open_)],
    }
PLAYER_SCREENS = player_screens(0)


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
    with open(os.path.join(RTL, 'osd_font.hex'), 'w', newline='') as o:
        for code in range(128):
            bits = glyphs.get(chr(code))
            for row in range(16):
                v = 0
                if bits and row < 14:
                    for x, c in enumerate(bits[row]):
                        if c == '#':
                            v |= 1 << (11 - x)
                o.write('%03x\n' % v)
    with open(os.path.join(RTL, 'osd_screens.hex'), 'w', newline='') as o:
        for lang in range(4):
            screens = player_screens(lang)
            for sid in range(8):
                cells = [0x20] * 512
                for r, c, text in screens.get(sid, []):
                    for i, ch in enumerate(text):
                        cells[r * 24 + c + i] = ord(ch)
                for v in cells:
                    o.write('%02x\n' % v)
    used = sorted(set(''.join(t for lang in range(4) for s in player_screens(lang).values() for _, _, t in s)) - {' '})
    print('glyphs used by the test screens and their status:')
    for ch in used:
        print('  %r: %s' % (ch, provenance.get(ch, 'MISSING')))


if __name__ == '__main__':
    main()
