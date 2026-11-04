"""Transcribe M50552-family glyphs from a photo/capture of a full OSD screen.

For each text line (given top to bottom, text without spaces is matched to glyph blobs in
order) the tool finds the line's vertical extent (= 14 dot rows for capitals), segments the
glyph blobs, fits the character pitch on the 12-dot grid, assigns columns, and samples the
12x14 dot centres. Repeated letters are voted per dot; disagreement is reported.

Usage:
  glyph_photo.py <image> <out.json> <channel r|g|b|y> "LINE TEXT" ["LINE TEXT" ...]
Lines are detected automatically; pass the texts in on-screen order (spaces are ignored for
matching). Use "-" as a line text to skip a detected line.
"""
import json
import sys

import numpy as np
from PIL import Image

COLS, ROWS = 12, 14


def otsu(v):
    h, e = np.histogram(v, 256)
    c = (e[:-1] + e[1:]) / 2
    w = np.cumsum(h); m = np.cumsum(h * c)
    tot, mt = w[-1], m[-1]
    best, t = -1, c[0]
    for i in range(1, 255):
        w0, w1 = w[i], tot - w[i]
        if w0 == 0 or w1 == 0:
            continue
        mu0, mu1 = m[i] / w0, (mt - m[i]) / w1
        b = w0 * w1 * (mu0 - mu1) ** 2
        if b > best:
            best, t = b, c[i]
    return t


def bilinear(g, x, y):
    xi, yi = int(np.floor(x)), int(np.floor(y))
    fx, fy = x - xi, y - yi
    return ((1 - fx) * (1 - fy) * g[yi, xi] + fx * (1 - fy) * g[yi, xi + 1]
            + (1 - fx) * fy * g[yi + 1, xi] + fx * fy * g[yi + 1, xi + 1])


def runs(mask, min_len=1, max_gap=0):
    out, i, n = [], 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            out.append([i, j])
            i = j
        else:
            i += 1
    merged = []
    for r in out:
        if merged and r[0] - merged[-1][1] <= max_gap:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    return [r for r in merged if r[1] - r[0] >= min_len]


def main():
    img = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(float)
    ch = sys.argv[3]
    texts = sys.argv[4:]
    if texts and texts[0].startswith('--crop='):           # x0,y0,x1,y1: restrict to the screen area
        x0c, y0c, x1c, y1c = (int(v) for v in texts[0][7:].split(','))
        img = img[y0c:y1c, x0c:x1c]
        texts = texts[1:]
    g = img.mean(axis=2) if ch == 'y' else img[:, :, 'rgb'.index(ch)]
    thr = otsu(g.reshape(-1)[::7])
    lit = g > thr
    rowprof = lit.mean(axis=1)
    lines = [r for r in runs(rowprof > 0.004, min_len=8, max_gap=2)]
    med = np.median([b - a for a, b in lines])
    split = []
    for a, b in lines:                                     # rows that touch: split into equal bands
        n = int(round((b - a) / med))
        if n > 1:
            # cut at the emptiest rows near each nominal boundary
            cuts = [a]
            for k in range(1, n):
                c = a + k * (b - a) / n
                lo, hi = int(c - med * 0.25), int(c + med * 0.25)
                cuts.append(lo + int(np.argmin(rowprof[lo:hi])))
            cuts.append(b)
            for u, v in zip(cuts[:-1], cuts[1:]):
                prof = rowprof[u:v] > 0.004
                idx = np.where(prof)[0]
                split.append([u + idx[0], u + idx[-1] + 1])
        else:
            split.append([a, b])
    lines = split
    if len(lines) != len(texts):
        print('detected %d lines, %d texts given:' % (len(lines), len(texts)), lines)
        sys.exit(1)
    glyphs = {}
    report = []
    for (y0, y1), text in zip(lines, texts):
        if text == '-':
            continue
        chars = [c for c in text if c != ' ']
        # glyph top/bottom = 50% crossings of the row profile (cap tops/bottoms are solid strokes);
        # the low-threshold band includes blur halo, which would stretch the 14-row grid
        rp = rowprof[y0:y1]
        half = 0.5 * rp.max()
        above = np.where(rp > half)[0]
        i0, i1 = above[0], above[-1]
        t0 = y0 + i0 - (rp[i0] - half) / max(rp[i0] - (rp[i0 - 1] if i0 > 0 else 0), 1e-9)
        t1 = y0 + i1 + (rp[i1] - half) / max(rp[i1] - (rp[i1 + 1] if i0 + 1 < len(rp) else 0), 1e-9)
        y0f = t0
        band = lit[y0:y1]
        colprof = band.mean(axis=0)
        segs = runs(colprof > 0.10, min_len=2, max_gap=1)
        # drop wide background boxes / bezels: keep segments narrower than ~1.3 cells (estimated later)
        if len(segs) != len(chars):
            print('line "%s": %d blobs for %d chars, skipped' % (text, len(segs), len(chars)), segs)
            continue
        vp = (t1 - t0 + 1) / ROWS
        lefts = np.array([s[0] for s in segs], float)
        rights = np.array([s[1] for s in segs], float)
        # pitch from adjacent letters: neighbours within a word differ by one cell
        d = np.diff(lefts)
        est = np.median(d[d < 1.6 * np.median(d)])
        col = np.round((lefts - lefts[0]) / est).astype(int)
        # refine with glyphs whose right edge sits at dot 10 (most): fit right = x0 + (col*12+10)*p
        A = np.vstack([np.ones(len(col)), col * 12 + 10]).T
        x0, p = np.linalg.lstsq(A, rights, rcond=None)[0]
        res = rights - (x0 + (col * 12 + 10) * p)
        keep = np.abs(res) < 0.6 * p
        x0, p = np.linalg.lstsq(A[keep], rights[keep], rcond=None)[0]
        report.append('line y%d-%d "%s": dot %.3f px, row %.3f px, cols %s' % (y0, y1, text, p, vp, list(col)))
        for c, ci in zip(chars, col):
            # sub-dot alignment: pick the offset (within +/- half a dot/row, never a whole dot) where the
            # sampled dots are most decisively on or off; absorbs keystone and line-split error
            best = None
            for ox in np.linspace(-0.45, 0.45, 7):
                for oy in np.linspace(-0.45, 0.45, 7):
                    v = np.array([[bilinear(g, x0 + (ci * 12 + k + 0.5 + ox) * p, y0f - 0.5 + (r + 0.5 + oy) * vp)
                                   for k in range(COLS)] for r in range(ROWS)])
                    score = np.abs(v - thr).sum()
                    if best is None or score > best[0]:
                        best = (score, v)
            v = best[1]
            bits = [''.join('#' if q > thr else '.' for q in row) for row in v]
            glyphs.setdefault(c, []).append(bits)
    print('\n'.join(report))
    voted = {}
    for c, insts in glyphs.items():
        a = np.array([[[1 if q == '#' else 0 for q in row] for row in b] for b in insts])
        m = a.mean(axis=0)
        bits = [''.join('#' if v > 0.5 else '.' for v in row) for row in m]
        unsure = int(((m > 0.2) & (m < 0.8)).sum())
        voted[c] = {'bits': bits, 'instances': len(insts), 'uncertain_dots': unsure}
    json.dump(voted, open(sys.argv[2], 'w'), indent=1)
    keys = sorted(voted)
    for i in range(0, len(keys), 8):
        blk = keys[i:i + 8]
        print('  '.join(('%s x%d u%d' % (k, voted[k]['instances'], voted[k]['uncertain_dots'])).ljust(12) for k in blk))
        for r in range(ROWS):
            print('  '.join(voted[k]['bits'][r] for k in blk))
        print()


if __name__ == '__main__':
    main()
