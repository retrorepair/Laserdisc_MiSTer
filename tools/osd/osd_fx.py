"""Bit-exact model of core/rtl/osd_m50552.v (composite-domain OSD mixer).

Per field line ln and sample x (line-locked 4fsc TBC), with the current line's burst vector
(br, bi), colour flag and V-inversion flag as computed by pal_decoder (pal_decode_fx):

  dot row  d  = ln - ROW0                          (one dot row per field line, both fields)
  dot col  dc = (ACC0 + (x - XS) * STEP) >> 16     for XS <= x < 1107   (7.03 MHz dot clock)
  lit(d,dc)  from the font/screen ROMs (12x14 glyph in a 12x18 cell, 24x12 cells)
  border(d,dc) = !lit and any lit at (d-dy, dc-dx), dy,dx in -1..2 except (2,-1) and (-1,2)

  in the active window (lines 22..309, x 185..1106) with a screen selected:
    lit -> 54016 (white), border -> 14442 (black), else background:
    blue  -> 14442 + YB + chroma(x), chroma from K = (Q * B) >> 24 (Q per V-inversion), x%4 phase
    black -> 14442;  none -> the original sample.

The blue raster's chroma is derived from the line's own burst because the ld-decode TBC is
line-locked (the real player's M50552 runs from the TBC's reference 4fsc, to which the disc
burst is locked); this keeps the raster in phase exactly as on the player.
"""
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, '..', '..', 'core', 'rtl')

W, H = 1135, 313
BLANK, WHITE = 14442, 54016
FSC4 = 17.734475
DOTCLK = 7.03
STEP = int(round(65536 * DOTCLK / FSC4))
X0F = 185 + (922 - 288 * FSC4 / DOTCLK) / 2
XS = 283
ACC0 = int(round((XS - X0F) * STEP))
ROW0 = 58
NROWS = 12 * 18
NCOLS = 24 * 12
BG_RGB = (0.05, 0.10, 0.70)                 # blue raster (mock-up value, approved "close enough")
BNOM = 0.15 / 0.70
_Y = 0.299 * BG_RGB[0] + 0.587 * BG_RGB[1] + 0.114 * BG_RGB[2]
_U, _V = 0.493 * (BG_RGB[2] - _Y), 0.877 * (BG_RGB[0] - _Y)
YB = int(round(_Y * (WHITE - BLANK)))


def _q(uv, off_deg):
    q = uv * np.exp(-1j * np.deg2rad(off_deg)) / (256 * BNOM) * 2 ** 24
    return int(round(q.real)), int(round(q.imag))


QN = _q(_U + 1j * _V, 135.0)                # normal line (burst at 135 deg)
QI = _q(_U - 1j * _V, 225.0)                # V-inverted line (burst at 225 deg)


def load_roms():
    font = [int(l, 16) for l in open(os.path.join(RTL, 'osd_font.hex'))]
    scr = [int(l, 16) for l in open(os.path.join(RTL, 'osd_screens.hex'))]
    return font, scr


def lit_table(screen):
    font, scr = load_roms()
    lit = np.zeros((NROWS, NCOLS), bool)
    for d in range(NROWS):
        cr, gr = d // 18, d % 18
        for cc in range(24):
            code = scr[screen * 512 + cr * 24 + cc] & 0x7F
            bits = font[code * 16 + gr] if gr < 14 else 0
            for gx in range(12):
                lit[d, cc * 12 + gx] = bool(bits >> (11 - gx) & 1)
    return lit


def border_table(lit):
    def L(d, c):
        return lit[d, c] if 0 <= d < NROWS and 0 <= c < NCOLS else False
    bd = {}
    for d in range(-2, NROWS + 2):
        row = np.zeros(NCOLS, bool)
        for c in range(NCOLS):
            if L(d, c):
                continue
            on = False
            for dy in (-1, 0, 1, 2):
                for dx in (-1, 0, 1, 2):
                    if (dy, dx) in ((2, -1), (-1, 2)):
                        continue
                    if L(d - dy, c - dx):
                        on = True
            row[c] = on
        bd[d] = row
    return bd


def line_bursts(field):
    """Per line (br, bi, col, inv) exactly as pal_decoder computes them (state reset per field)."""
    import sys
    sys.path.insert(0, os.path.join(HERE, '..', 'model'))
    import pal_decode_fx as fx
    out = []
    prev = None
    for ln in range(H):
        d = field[ln].astype(np.int64) - BLANK
        x = np.arange(W)
        zr = np.where(x % 4 == 0, d, np.where(x % 4 == 2, -d, 0))
        zi = np.where(x % 4 == 1, -d, np.where(x % 4 == 3, d, 0))
        w = np.array(fx.LPF_W)
        Lr = np.convolve(zr, w)[:W]; Li = np.convolve(zi, w)[:W]    # causal L[x] = sum w_k z[x-k]
        Lrc, Lic = Lr[3:], Li[3:]                                   # centre index
        br = int(Lrc[fx.BURST_C[0]:fx.BURST_C[1]].sum()); bi = int(Lic[fx.BURST_C[0]:fx.BURST_C[1]].sum())
        if br * br + bi * bi < fx.KILL2:
            out.append((br, bi, False, False)); prev = None
        else:
            inv = prev is not None and (br * prev[0] + bi * prev[1]) > 0
            out.append((br, bi, True, inv)); prev = (br, bi)
    return out


def mix_field(field, screen, bg, lit=None, bd=None):
    """bg: 0 none (overlay), 1 blue raster, 2 black raster."""
    out = field.astype(np.int64).copy()
    if screen == 0:
        return out.astype(np.uint16)
    if lit is None:
        lit = lit_table(screen); bd = border_table(lit)
    bursts = line_bursts(field)
    xs = np.arange(185, 1107)
    dc = np.where(xs >= XS, (ACC0 + (xs - XS) * STEP) >> 16, -1)
    dvalid = (dc >= 0) & (dc < NCOLS)
    for ln in range(22, 310):
        br, bi, col, inv = bursts[ln]
        qr, qi = QI if inv else QN
        kr = (qr * br - qi * bi) >> 24
        ki = (qr * bi + qi * br) >> 24
        ph = xs % 4
        chroma = np.where(ph == 0, kr, np.where(ph == 1, -ki, np.where(ph == 2, -kr, ki))) if col else 0
        if bg == 1:
            line = BLANK + YB + chroma + np.zeros(len(xs), np.int64)
        elif bg == 2:
            line = np.full(len(xs), BLANK, np.int64)
        else:
            line = out[ln, 185:1107].copy()
        d = ln - ROW0
        if -2 <= d < NROWS + 2:
            lt = np.zeros(len(xs), bool); bb = np.zeros(len(xs), bool)
            if 0 <= d < NROWS:
                lt[dvalid] = lit[d, dc[dvalid]]
            bb[dvalid] = bd[d][dc[dvalid]]
            line = np.where(lt, WHITE, np.where(bb, BLANK, line))
        out[ln, 185:1107] = line
    return np.clip(out, 0, 65535).astype(np.uint16)


if __name__ == '__main__':
    print('STEP', STEP, 'X0F %.3f' % X0F, 'ACC0', ACC0, 'YB', YB, 'QN', QN, 'QI', QI)
