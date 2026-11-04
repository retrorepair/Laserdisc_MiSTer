"""CLD-1750 OSD MOCK-UP renderer (for visual review only; not a faithful reproduction).

Renders OSD screens with the transcribed glyphs (tools/osd/font_cld1750.json) into real PAL
TBC lines (sync and burst from a decoded disc field), mixing in the composite domain as the
M50552 does (CV IN -> CV OUT), then decodes with the core's PAL decoder model, so composite
artefacts appear as they would through the core.

Geometry (docs/osd_dot_grid.md): 12x18 cell, 14-row glyphs, one dot row = one line per field,
dot clock 7.03 MHz (=2.523 4fsc samples per dot), 24 columns centred in the active line,
row 0 centre at ~15% of picture height. Colours, border rule and the glyphs marked GUESS
are assumptions for the mock-up.

Usage: mockup.py <black_field_source.tbc> <out_prefix>
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'model'))
import pal_decode as pd       # noqa: E402  (float golden model)
import pal_decode_fx as fx    # noqa: E402  (bit-exact core decoder)

W, H = 1135, 313
BLANK, WHITE = 14442.0, 54016.0
DOT = 17.734475 / 7.03                # 4fsc samples per OSD dot
X0 = 185 + (922 - 24 * 12 * DOT) / 2  # column 0 left edge
ROW0_TOP = 22 + int(0.15 * 288) - 7   # field line of row 0's first dot row
BLUE = (0.05, 0.10, 0.70)             # background raster RGB (assumption)

# glyphs constructed for the mock-up where no clean evidence exists yet (GUESS)
GUESS = {
    'H': ['##......##..'] * 6 + ['##########..'] * 2 + ['##......##..'] * 6,
    'F': ['##########..'] * 2 + ['##..........'] * 4 + ['########....'] * 2 + ['##..........'] * 6,
    '-': ['............'] * 6 + ['..#######...'] * 2 + ['............'] * 6,   # F1: ~7 dots from dot 2
    'G': ['..######....', '.########...', '###....###..', '##......##..', '##..........', '##..........',
          '##...#####..', '##...#####..', '##......##..', '##......##..', '##......##..', '###....###..',
          '.########...', '..######....'],
    '.': ['............'] * 12 + ['....##......'] * 2,
    ' ': ['............'] * 14,
}


def load_font():
    f = json.load(open(os.path.join(HERE, 'font_cld1750.json')))['glyphs']
    font, used_guess = {}, set()
    for ch, g in f.items():
        if g['status'] != 'review':
            font[ch] = g['bits']
    for ch in ('N', 'O', 'V', 'B'):                       # review glyphs: shapes look plausible, flagged
        if ch in f and ch not in font:
            font[ch] = f[ch]['bits']
    for ch, bits in GUESS.items():
        if ch not in font:
            font[ch] = bits
    return font


def screen_mask(font, rows, guess_log):
    """rows: list of (row, col, text). Returns (lit, border) masks in dot units, 18*12 rows x 288 cols."""
    lit = np.zeros((12 * 18, 24 * 12), bool)
    for r, c, text in rows:
        for i, ch in enumerate(text):
            if ch in GUESS and ch != ' ':
                guess_log.add(ch)
            if ch in ('N', 'O', 'V', 'B'):
                guess_log.add(ch + '(review)')
            bits = font[ch]
            for gy in range(14):
                for gx in range(12):
                    if bits[gy][gx] == '#':
                        lit[r * 18 + gy, (c + i) * 12 + gx] = True
    # border: 1 dot all round, plus 1 extra dot of shadow right and below (assumption from F1/2850 photos)
    b = np.zeros_like(lit)
    pad = np.pad(lit, 2)                                  # pad, not roll: no wrap-around at the edges
    hh, ww = lit.shape
    for dy in (-1, 0, 1, 2):
        for dx in (-1, 0, 1, 2):
            if (dy == 2 or dx == 2) and not (dy >= 0 and dx >= 0):
                continue
            b |= pad[2 - dy:2 - dy + hh, 2 - dx:2 - dx + ww]
    border = b & ~lit
    return lit, border


def synth_field(src, lit, border, background):
    """Write the OSD (and optional blue raster) into the active part of a real TBC field."""
    out = src.copy().astype(float)
    Y = 0.299 * BLUE[0] + 0.587 * BLUE[1] + 0.114 * BLUE[2]
    U, V = 0.493 * (BLUE[2] - Y), 0.877 * (BLUE[0] - Y)
    prev_alpha = None
    for ln in range(H):
        line = out[ln]
        z = pd.demod(line)
        b = z[pd.BURST[0] + 4:pd.BURST[1] - 4].mean()
        amp, alpha = abs(b), np.angle(b, deg=True)
        if amp < pd.BURST_NOMINAL / 4:
            prev_alpha = None
            continue
        inverted = False
        if prev_alpha is not None:
            d = (alpha - prev_alpha + 180.0) % 360.0 - 180.0
            inverted = abs(d) < 90.0
        prev_alpha = alpha
        u_axis = np.deg2rad(alpha - (225.0 if inverted else 135.0))
        dot_row = ln - ROW0_TOP
        xs = np.arange(185, 1107)
        dcol = np.floor((xs - X0) / DOT).astype(int)
        inside = (dcol >= 0) & (dcol < 24 * 12)
        y = np.zeros(len(xs)); c = np.zeros(len(xs), complex)
        if background:
            y[:] = Y
            c[:] = (U + 1j * (-V if inverted else V)) * np.exp(1j * u_axis) * (amp / pd.BURST_NOMINAL)
        if 0 <= dot_row < 12 * 18:
            on = np.zeros(len(xs), bool); bd = np.zeros(len(xs), bool)
            on[inside] = lit[dot_row, dcol[inside]]
            bd[inside] = border[dot_row, dcol[inside]]
            y[on] = 1.0; c[on] = 0
            y[bd] = 0.0; c[bd] = 0
        if background or (0 <= dot_row < 12 * 18):
            keep = background | (0 <= dot_row) & (dot_row < 12 * 18) & (inside & (lit[max(dot_row, 0) % (12 * 18), np.clip(dcol, 0, 287)] | border[max(dot_row, 0) % (12 * 18), np.clip(dcol, 0, 287)]))
            n = xs
            comp = BLANK + (y + np.real(c * np.exp(1j * n * np.pi / 2))) * (WHITE - BLANK)
            line[185:1107] = np.where(keep, comp, line[185:1107])
    return np.clip(np.round(out), 0, 65535).astype(np.uint16)


def render(src_path, rows, out_png, background=True):
    font = load_font()
    guesses = set()
    lit, border = screen_mask(font, rows, guesses)
    f0 = fx.read_field(src_path, 0)
    f1 = fx.read_field(src_path, 1)
    a = fx.decode_field_fx(synth_field(f0, lit, border, background))
    b = fx.decode_field_fx(synth_field(f1, lit, border, background))
    img = np.empty((2 * H, a.shape[1], 3), np.uint8)
    img[0::2], img[1::2] = a, b
    vis = img[2 * 22:2 * 310]                                 # visible 576 lines
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.image as mpimg
    from PIL import Image
    Image.fromarray(vis).resize((768, 576), Image.LANCZOS).save(out_png)
    return sorted(guesses)


SCREENS = {
    'load':  [(0, 0, 'LASERDISC'), (1, 1, '-PAL-'), (0, 17, 'PLAY'), (1, 17, 'SIDE -A')],
    'pause': [(0, 17, 'PAUSE'), (1, 0, 'CHAPTER   1'), (2, 0, 'TIME   0.00'), (2, 17, 'EDITING'), (3, 17, 'COMPUTE')]
             + [(r, c, '--') for r in range(4, 8) for c in (1, 5, 9, 13, 17, 21)],
    'stop':  [(0, 17, 'STOP')],
}

if __name__ == '__main__':
    src, prefix = sys.argv[1], sys.argv[2]
    for name, rows in SCREENS.items():
        g = render(src, rows, '%s_%s.png' % (prefix, name))
        print(name, '-> %s_%s.png' % (prefix, name), 'guessed/review glyphs:', g)
