"""Test vectors for core/sim/tb_modpal.sv: NTSC TBC lines through modpal_ref.ModPal.
usage: modpal_vectors.py TBC OUTDIR  -> OUTDIR/modpal_in.hex (x, n, adv per sample) and modpal_out.hex (expected)."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import modpal_ref as r

W, H = 910, 263
tbc, outdir = sys.argv[1], sys.argv[2]
f = open(tbc, 'rb')
m = r.ModPal()
vin, vout = [], []
# a red field (25000) then a busier one (4000), with the chroma advance at 0 and then 3
for fi, l0, l1, adv in ((25000, 100, 106, 0), (4000, 30, 40, 0), (4000, 120, 126, 3)):
    f.seek(fi * W * H * 2)
    raw = np.frombuffer(f.read(W * H * 2), '<u2').reshape(H, W)
    codes = np.clip(np.round(raw * 255.0 / 51200), 0, 255).astype(int)
    for li in range(l0, l1):
        for n in range(W):
            x = int(codes[li][n])
            vin.append('%02x%03x%x' % (x, n, adv))
            vout.append('%02x' % m.step(x, n, adv))
open(os.path.join(outdir, 'modpal_in.hex'), 'w', newline='').write('\n'.join(vin) + '\n')
open(os.path.join(outdir, 'modpal_out.hex'), 'w', newline='').write('\n'.join(vout) + '\n')
print(len(vin), 'samples')
