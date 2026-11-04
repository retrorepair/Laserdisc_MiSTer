"""Render a page (or a clipped region) of the LD-V4300D service manual to PNG.

Usage:
  render_page.py <pdf> <page(1-based)> <out.png> [dpi] [x0 y0 x1 y1]

The clip rectangle is given as fractions (0..1) of the page width/height so
crops can be chosen from a low-res overview without knowing the page size.
"""
import sys
import pymupdf


def main():
    pdf, page, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    dpi = int(sys.argv[4]) if len(sys.argv) > 4 else 100
    p = pymupdf.open(pdf)[page - 1]
    clip = None
    if len(sys.argv) > 8:
        fx0, fy0, fx1, fy1 = (float(v) for v in sys.argv[5:9])
        r = p.rect
        clip = pymupdf.Rect(r.width * fx0, r.height * fy0, r.width * fx1, r.height * fy1)
    pix = p.get_pixmap(dpi=dpi, clip=clip)
    pix.save(out)
    print(out, pix.width, pix.height)


if __name__ == "__main__":
    main()
