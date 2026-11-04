"""Prepare field.hex for tb_pal_decoder and compare its rgb_rtl.txt with the fixed-point model.

  compare_pal.py prep <file.tbc> <field_index>     -> writes field.hex (+ field_index.txt)
  compare_pal.py check <file.tbc>                  -> compares rgb_rtl.txt with pal_decode_fx
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools', 'model'))
import pal_decode_fx as fx  # noqa: E402


def prep(tbc, field):
    f = fx.read_field(tbc, field)
    with open(os.path.join(HERE, 'field.hex'), 'w') as o:
        for v in f.reshape(-1):
            o.write('%04x\n' % v)
    with open(os.path.join(HERE, 'field_index.txt'), 'w') as o:
        o.write(str(field))
    print('field.hex written for field', field)


def check(tbc):
    field = int(open(os.path.join(HERE, 'field_index.txt')).read())
    ref = fx.decode_field_fx(fx.read_field(tbc, field))           # (313, 922, 3)
    rows = np.loadtxt(os.path.join(HERE, 'rgb_rtl.txt'), dtype=np.int64)
    got = np.full(ref.shape, -1, np.int64)
    for ln, x, r, g, b in rows:
        got[ln, x - fx.ACTIVE[0]] = (r, g, b)
    missing = int((got[:, :, 0] < 0).sum())
    diff = np.abs(got - ref.astype(np.int64))
    diff[got < 0] = 0
    bad = np.argwhere(diff.max(axis=2) > 0)
    print('pixels compared: %d, missing: %d, mismatching: %d' % (rows.shape[0], missing, len(bad)))
    for ln, x in bad[:10]:
        print('  ln %d x %d rtl %s model %s' % (ln, x + fx.ACTIVE[0], got[ln, x], ref[ln, x]))
    return 0 if (missing == 0 and len(bad) == 0) else 1


if __name__ == '__main__':
    if sys.argv[1] == 'prep':
        prep(sys.argv[2], int(sys.argv[3]))
    else:
        sys.exit(check(sys.argv[2]))
