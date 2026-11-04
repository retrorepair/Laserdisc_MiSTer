"""Bit-exact fixed-point model of the core's PAL decoder (rtl/pal_decoder.sv).

Same algorithm as pal_decode.py (the float golden model), restated in the integer
arithmetic the FPGA performs. The RTL simulation must reproduce decode_line_fx()
output exactly; pal_decode.py checks that this arithmetic is still a correct decoder.

All quantities are per line of 1135 samples; d = sample - BLANK (signed).

Usage: pal_decode_fx.py <file.tbc> <frame_index> <out.png>   (also prints PSNR vs float)
"""
import sys
import numpy as np

W, H = 1135, 313
FIELD_BYTES = W * H * 2
BLANK = 14442
ACTIVE = (185, 1107)
BURST_C = (102, 134)            # centre positions summed for the burst vector (32 samples)
LPF_W = (1, 2, 3, 4, 3, 2, 1)   # sum 16; output centred 3 samples back

# --- constants derived in docs/core_architecture.md ------------------------------
# uv8 = 255 * Bnom * 32 / sqrt2 * L * conj(B) * (-1 +/- j) / |B|^2, Bnom = 0.15/0.70
K_UV = 255.0 * (0.15 / 0.70) * 32.0 / np.sqrt(2.0)
N_DIV = int(round(K_UV * 2 ** 48))                 # numerator of the once-per-line divide
# colour killer: |b_f| < Bnom/4, with b_f = 2*B/(16*32*39574)  ->  |B|^2 < KILL2
KILL2 = int(((0.15 / 0.70) / 4 * 16 * 32 * (54016 - BLANK) / 2) ** 2)
Y_MUL, Y_SH = 6757, 20                             # Y8 = (yn * 6757) >> 20  (255/39574)
CR_V, CB_U, CG_U, CG_V = 4671, 8308, 1617, 2378    # Q12: 1.1403, 2.0284, 0.3947, 0.5806


def mix(d, x):
    """fs/4 demodulation: d * e^{-j x pi/2} -> (re, im)."""
    p = x & 3
    return ((d, 0), (0, -d), (-d, 0), (0, d))[p]


class LineState:
    def __init__(self):
        self.prev_b = None       # previous line's burst vector (None = no colour on previous line)
        self.prev_uv = None


def decode_line_fx(samples, st):
    """samples: 1135 uint16. Returns (Y8, U, V, R, G, B) int arrays over the whole line."""
    d = samples.astype(np.int64) - BLANK
    zr = np.zeros(W, np.int64); zi = np.zeros(W, np.int64)
    for x in range(W):
        zr[x], zi[x] = mix(int(d[x]), x)
    # LPF, causal: L[x] = sum_k w_k z[x-k]; centre is x-3. Re-index to centre: Lc[x] = L[x+3]
    Lr = np.zeros(W, np.int64); Li = np.zeros(W, np.int64)
    for x in range(W):
        sr = si = 0
        for k, w in enumerate(LPF_W):
            if x - k >= 0:
                sr += w * zr[x - k]; si += w * zi[x - k]
        Lr[x], Li[x] = sr, si
    Lrc = np.zeros(W, np.int64); Lic = np.zeros(W, np.int64)
    Lrc[:W - 3], Lic[:W - 3] = Lr[3:], Li[3:]
    # luma double notch [1,0,2,0,1]/4 centred: yn[x] = (d[x-2] + 2d[x] + d[x+2]) >> 2
    yn = np.zeros(W, np.int64)
    for x in range(2, W - 2):
        yn[x] = (d[x - 2] + 2 * d[x] + d[x + 2]) >> 2
    y8 = (yn * Y_MUL) >> Y_SH

    br = int(Lrc[BURST_C[0]:BURST_C[1]].sum()); bi = int(Lic[BURST_C[0]:BURST_C[1]].sum())
    mag2 = br * br + bi * bi
    if mag2 < KILL2:
        st.prev_b, st.prev_uv = None, None
        u = np.zeros(W, np.int64); v = np.zeros(W, np.int64)
    else:
        inverted = False
        if st.prev_b is not None:
            inverted = (br * st.prev_b[0] + bi * st.prev_b[1]) > 0
        q = N_DIV // mag2                                   # once per line
        if not inverted:   # burst at 135 deg: conj(B)*(-1+j) = (-br+bi) + j(br+bi)
            c0r, c0i = -br + bi, br + bi
        else:              # burst at 225 deg: conj(B)*(-1-j) = (-br-bi) + j(bi-br)
            c0r, c0i = -br - bi, bi - br
        cr = (q * c0r) >> 24
        ci = (q * c0i) >> 24
        ur = (Lrc * cr - Lic * ci) >> 24                    # complex multiply, real = U
        vi = (Lrc * ci + Lic * cr) >> 24                    # imag = V
        if inverted:
            vi = -vi
        if st.prev_uv is None:
            u, v = ur, vi
        else:
            u, v = (ur + st.prev_uv[0]) >> 1, (vi + st.prev_uv[1]) >> 1
        st.prev_b, st.prev_uv = (br, bi), (ur, vi)
    r = y8 + ((v * CR_V) >> 12)
    b = y8 + ((u * CB_U) >> 12)
    g = y8 - ((u * CG_U + v * CG_V) >> 12)
    clamp = lambda a: np.clip(a, 0, 255)
    return y8, u, v, clamp(r), clamp(g), clamp(b)


def decode_field_fx(field):
    st = LineState()
    out = np.zeros((H, ACTIVE[1] - ACTIVE[0], 3), np.uint8)
    for ln in range(H):
        _, _, _, r, g, b = decode_line_fx(field[ln], st)
        out[ln] = np.stack([r, g, b], axis=-1)[ACTIVE[0]:ACTIVE[1]]
    return out


def read_field(path, index):
    with open(path, 'rb') as f:
        f.seek(index * FIELD_BYTES)
        return np.frombuffer(f.read(FIELD_BYTES), dtype='<u2').reshape(H, W)


def main():
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.image as mpimg
    sys.path.insert(0, __import__('os').path.dirname(__file__))
    import pal_decode
    path, frame, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    f1 = decode_field_fx(read_field(path, 2 * frame))
    f2 = decode_field_fx(read_field(path, 2 * frame + 1))
    img = np.empty((2 * H, f1.shape[1], 3), np.uint8); img[0::2], img[1::2] = f1, f2
    mpimg.imsave(out, img)
    ref = np.round(pal_decode.decode_frame(path, frame) * 255.0)
    err = img.astype(float) - ref
    mse = (err ** 2).mean()
    print(out, 'PSNR vs float model: %.1f dB, max abs err %d' % (10 * np.log10(255 ** 2 / max(mse, 1e-9)), np.abs(err).max()))


if __name__ == '__main__':
    main()
