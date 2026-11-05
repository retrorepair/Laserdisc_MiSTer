"""Bit-exact integer model of core/rtl/modpal.v (MOD. PAL, docs/mod_pal.md), for the testbench and for checks.

Works per 4fsc sample on the 8-bit composite codes, n = the sample's index in its 910-sample line:
  d    = x - x(previous line, same n)                 1H comb: NTSC chroma inverts line to line
  c4   = 2 d[n-2] - d[n] - d[n-4]                     -(1 - z^-2)^2: band-pass at fsc, centred on n-2 (where
                                                       the filter's delay makes it -1 at fsc); chroma(n-2) = c4 / 8
  y8   = 8 x[n-2] - c4                                luma x 8 (the comb's luma)
  zr/zi held quadrature samples of c4 (n%4 = 0,1,2,3 -> zr, -zi, -zr, zi)
  q    = z e^{j33 deg}, (cos, sin) = (27482, 17847) / 32768: the NTSC burst onto the real axis
  s    = sign of sum(qr) over n = 80..107 (this line's burst), used from n = 108
  U, V = -s qr, -s qi; in the burst window n = 74..113: U = -|qr| / sqrt2, V = +|qr| / sqrt2 (PAL burst, 135 deg)
  out  = clamp(round(y8[n - 2 adv] / 8) + (U sin + vsw V cos) >> 14), vsw toggling each line, NCO 4.43361875 MHz
"""
import math

INC4 = (4 * round(4433618.75 / (315e6 / 88 * 16) * (1 << 32))) & 0xFFFFFFFF
SIN = [round(2047 * math.sin(2 * math.pi * i / 1024)) for i in range(1024)]
C33, S33 = 27482, 17847
R2 = 23170                      # 1/sqrt2 * 32768


def asr(v, k):
    return v >> k               # Python >> on ints is arithmetic (floor), as Verilog >>> on signed


class ModPal:
    def __init__(self):
        self.mem = [0] * 910
        self.xh = [0, 0]        # x[n-1], x[n-2]
        self.dh = [0] * 4       # d[n-1..n-4]
        self.yh = [0] * 15      # y8 history for the chroma advance
        self.zr = self.zi = 0
        self.pacc = 0
        self.s = 1
        self.vsw = 1
        self.ph = 0

    def step(self, x, n, adv=0):
        if n == 0:
            self.vsw = -self.vsw
            self.pacc = 0
        prev = self.mem[n]
        self.mem[n] = x
        d = x - prev
        c4 = 2 * self.dh[1] - d - self.dh[3]
        y8 = 8 * self.xh[1] - c4
        self.dh = [d] + self.dh[:3]
        self.xh = [x, self.xh[0]]
        k = n & 3
        if k == 0: self.zr = c4
        elif k == 1: self.zi = -c4
        elif k == 2: self.zr = -c4
        else: self.zi = c4
        qr = asr(self.zr * C33 - self.zi * S33, 15)
        qi = asr(self.zr * S33 + self.zi * C33, 15)
        if 80 <= n < 108:
            self.pacc += qr
        if n == 108:
            self.s = 1 if self.pacc >= 0 else -1
        if 74 <= n < 114:
            a = asr(abs(qr) * R2, 15)
            U, V = -a, a
        else:
            U, V = -self.s * qr, -self.s * qi
        self.yh = [y8] + self.yh[:14]
        yd = self.yh[2 * adv]
        i = self.ph >> 22
        chroma = asr(U * SIN[i] + self.vsw * V * SIN[(i + 256) & 1023], 14)
        self.ph = (self.ph + INC4) & 0xFFFFFFFF
        out = asr(yd + 4, 3) + chroma
        return 0 if out < 0 else 255 if out > 255 else out


if __name__ == '__main__':
    open('modpal_sin.hex', 'w', newline='').write(''.join('%03x\n' % (v & 0xFFF) for v in SIN))
    print('INC4 = %d (0x%08x)' % (INC4, INC4))
