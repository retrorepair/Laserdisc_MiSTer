"""Sample OSD glyphs from a direct video capture onto the M50552 dot grid.

Grid (docs/osd_dot_grid.md): 12 dots per character cell horizontally, glyphs 14 dot rows
tall, one dot row = 2 frame lines (one line per field). The horizontal dot pitch and phase
are fitted from the glyph edges themselves (edge positions modulo pitch), so no capture
sample rate is assumed.

Usage: glyph_sample.py <avg.npy> <y_top> <x_first_cell> <text> [<x_first_cell> <text> ...]
Prints each glyph as a 12x14 bitmap and writes them to glyphs_<name>.json.
"""
import json
import sys

import numpy as np

COLS, ROWS = 12, 14


def fit_pitch(g, y0, x_lo, x_hi, thr):
    edges = []
    for y in range(y0 + 1, y0 + 2 * ROWS - 1):
        r = g[y, x_lo:x_hi]
        for i in range(len(r) - 1):
            a, b = r[i] - thr, r[i + 1] - thr
            if a * b < 0:
                edges.append(x_lo + i + a / (a - b))
    e = np.array(edges)
    best = max((abs(np.exp(2j * np.pi * e / p).mean()), p) for p in np.arange(1.60, 1.90, 0.0005))
    p = best[1]
    phase = (np.angle(np.exp(2j * np.pi * e / p).mean()) / (2 * np.pi)) * p   # an edge position mod p
    return p, phase % p, best[0]


def bilinear(g, x, y):
    xi, yi = int(np.floor(x)), int(np.floor(y))
    fx, fy = x - xi, y - yi
    return ((1 - fx) * (1 - fy) * g[yi, xi] + fx * (1 - fy) * g[yi, xi + 1]
            + (1 - fx) * fy * g[yi + 1, xi] + fx * fy * g[yi + 1, xi + 1])


def main():
    g = np.load(sys.argv[1])
    y0 = int(sys.argv[2])
    groups = [(float(sys.argv[i]), sys.argv[i + 1]) for i in range(3, len(sys.argv), 2)]
    bg = np.median(g)
    hi = np.percentile(g[y0:y0 + 2 * ROWS, :], 99)
    thr = (bg + hi) / 2
    x_lo = int(min(x for x, _ in groups)) - 4
    x_hi = int(max(x + 12 * 1.75 * len(t) for x, t in groups)) + 4
    p, phase, R = fit_pitch(g, y0, x_lo, x_hi, thr)
    print('dot pitch %.4f px (R=%.3f), edge phase %.3f px' % (p, R, phase))
    # vertical: the glyph's lit extent spans exactly ROWS dot rows; use its sub-line top/bottom edges
    prof = (g[y0 - 4:y0 + 2 * ROWS + 6, x_lo:x_hi] > thr).mean(axis=1)
    lit = np.where(prof > 0.02)[0]
    top = y0 - 4 + lit[0] - 0.5
    bot = y0 - 4 + lit[-1] + 0.5
    vp = (bot - top) / ROWS
    vtop = top
    print('dot row pitch %.3f lines, glyph top %.1f bottom %.1f' % (vp, top, bot))
    out = {}
    for x0, text in groups:
        # snap the cell origin to the nearest dot edge
        k = round((x0 - phase) / p)
        cx = phase + k * p
        for ci, ch in enumerate(text):
            if ch == ' ':
                continue
            bits = []
            for row in range(ROWS):
                yc = vtop + (row + 0.5) * vp          # dot-row centre (capture lines are rescaled)
                line = ''
                for col in range(COLS):
                    x = cx + (ci * COLS + col + 0.5) * p
                    v = bilinear(g, x, yc)
                    line += '#' if v > thr else '.'
                bits.append(line)
            out.setdefault(ch, []).append(bits)
            print("'%s'" % ch)
            print('\n'.join('   ' + b for b in bits))
    json.dump({'pitch': p, 'phase': phase, 'glyphs': out}, open('glyphs_sampled.json', 'w'), indent=1)


if __name__ == '__main__':
    main()
