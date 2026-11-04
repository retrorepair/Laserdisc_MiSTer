"""Render every page of a PDF to PNG files (pNNN.png) in an output directory.

Usage: render_all.py <pdf> <outdir> [dpi]
"""
import os
import sys
import pymupdf


def main():
    pdf, outdir = sys.argv[1], sys.argv[2]
    dpi = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    os.makedirs(outdir, exist_ok=True)
    d = pymupdf.open(pdf)
    for i, p in enumerate(d):
        p.get_pixmap(dpi=dpi).save(os.path.join(outdir, 'p%03d.png' % (i + 1)))
    print(pdf, d.page_count, 'pages ->', outdir)


if __name__ == '__main__':
    main()
