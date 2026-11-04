"""Reference PAL decoder for ld-decode .tbc fields (4fsc, line-locked).

This is the golden model for the core's FPGA PAL decoder (composite -> RGB). The core
outputs RGB "for now" (user direction 2026-11-03), so this decoder stands in for the
TV's decoder; it is NOT part of the CLD-1750 itself, whose output is composite. It is
written as a plain, conventional delay-line ("PAL-D") TV decoder:

  * per-line burst phase measurement (TBC is line-locked, not subcarrier-locked, so the
    subcarrier phase moves ~-89.4 deg/line and must be measured on every line)
  * PAL V-switch identified from the burst swing (135 / 225 deg), as a TV's ident does
  * synchronous demodulation at fs/4, 7-tap triangular low-pass (nulls at fsc and 2fsc)
  * PAL delay-line averaging of U/V with the previous line
  * ACC (chroma gain from burst amplitude), luma from a double notch at fsc
  * ITU-R BT.601-style PAL YUV -> RGB

Usage: pal_decode.py <file.tbc> <frame_index> <out.png>
"""
import sys
import numpy as np

W, H = 1135, 313                 # samples per line, lines per (padded) field
FIELD_BYTES = W * H * 2
BURST = (98, 138)                # from .tbc.json videoParameters
ACTIVE = (185, 1107)
BLANK, WHITE = 14442.0, 54016.0  # 16-bit IRE levels from videoParameters
BURST_NOMINAL = 0.15 / 0.70      # PAL burst amplitude (150 mV) relative to 700 mV luma

# fs/4 mixing sequence e^{-j n pi/2} = 1, -j, -1, j
MIX = np.array([1, -1j, -1, 1j])
LPF = np.array([1, 2, 3, 4, 3, 2, 1], dtype=float) / 16.0   # boxcar4 * boxcar4


def read_field(path, index):
    with open(path, 'rb') as f:
        f.seek(index * FIELD_BYTES)
        raw = np.frombuffer(f.read(FIELD_BYTES), dtype='<u2')
    return raw.reshape(H, W).astype(float)


def demod(line):
    """Return baseband complex chroma (2x gain restores amplitude) for a whole line."""
    n = np.arange(W)
    z = (line - BLANK) / (WHITE - BLANK) * MIX[n % 4]
    return 2.0 * np.convolve(z, LPF, mode='same')


def decode_field(field):
    rgb = np.zeros((H, ACTIVE[1] - ACTIVE[0], 3))
    prev_alpha = None
    prev_uv = None
    for ln in range(H):
        line = field[ln]
        z = demod(line)
        b = z[BURST[0] + 4:BURST[1] - 4].mean()        # skip burst envelope edges
        amp, alpha = abs(b), np.angle(b, deg=True)
        if amp < BURST_NOMINAL / 4:                      # no/weak burst (VBI, sync): mono, colour killer
            y = (line - BLANK) / (WHITE - BLANK)
            y = np.convolve(y, np.array([1, 0, 2, 0, 1]) / 4.0, mode='same')   # notch always in circuit
            rgb[ln] = y[ACTIVE[0]:ACTIVE[1], None]
            prev_alpha, prev_uv = None, None
            continue
        # Ident: with line-locked 4fsc sampling the burst moves -89.4 deg/line; the PAL swing
        # adds +/-90. A measured step near 0 deg means this line's burst is at 225 deg (V inverted).
        inverted = False
        if prev_alpha is not None:
            d = (alpha - prev_alpha + 180.0) % 360.0 - 180.0
            inverted = abs(d) < 90.0
        u_axis = alpha - (225.0 if inverted else 135.0)  # burst sits at 180 +/- 45 from +U
        rot = np.exp(-1j * np.deg2rad(u_axis))
        acc = BURST_NOMINAL / amp                         # <= 4 given the colour-killer threshold
        uv = z * rot * acc
        if inverted:
            uv = uv.real - 1j * uv.imag
        out_uv = uv if prev_uv is None else 0.5 * (uv + prev_uv)   # PAL delay line
        prev_alpha, prev_uv = alpha, uv
        # luma: double notch at fsc ([1,0,1]/2 applied twice)
        y = (line - BLANK) / (WHITE - BLANK)
        y = np.convolve(y, np.array([1, 0, 2, 0, 1]) / 4.0, mode='same')
        u, v = out_uv.real, out_uv.imag
        r = y + v / 0.877
        bb = y + u / 0.493
        g = (y - 0.299 * r - 0.114 * bb) / 0.587
        rgb[ln] = np.stack([r, g, bb], axis=-1)[ACTIVE[0]:ACTIVE[1]]
    return np.clip(rgb, 0.0, 1.0)


def decode_frame(path, frame):
    f1 = decode_field(read_field(path, 2 * frame))
    f2 = decode_field(read_field(path, 2 * frame + 1))
    out = np.empty((2 * H, f1.shape[1], 3))
    out[0::2], out[1::2] = f1, f2
    return out


def main():
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.image as mpimg
    path, frame, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    img = decode_frame(path, frame)
    # 922 active samples at 4fsc -> display at 4:3 (922 x 576 visible lines ~ 768 square px wide)
    mpimg.imsave(out, img)
    print(out, img.shape)


if __name__ == '__main__':
    main()
