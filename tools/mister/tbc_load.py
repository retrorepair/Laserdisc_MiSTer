#!/usr/bin/env python3
"""Load a .tbc chunk into the Laserdisc_MiSTer core's DDR3 window (runs ON the MiSTer, python3, no numpy).

Usage: tbc_load.py <chunk.tbc>

Layout (must match core/rtl/tbc_reader.v):
  phys 0x30000000 : header  u32 "TBC1" (0x31434254), u32 field count
  phys 0x30001000 : fields; each line padded 1135 -> 1136 samples (2272 bytes), 313 lines per field
Writes the data first and the header last; reset the core from its OSD afterwards so the
reader picks up the header.
"""
import mmap
import os
import struct
import sys

W, H = 1135, 313
LINE_IN, LINE_OUT = W * 2, (W + 1) * 2
FIELD_IN, FIELD_OUT = LINE_IN * H, LINE_OUT * H
BASE, DATA_OFF = 0x30000000, 0x1000
WINDOW = 0x10000000                       # 256 MB below 0x40000000 used by this loader
PAD = struct.pack('<H', 14442)            # blanking level


def main():
    path = sys.argv[1]
    size = os.path.getsize(path)
    fields = size // FIELD_IN
    fields -= fields & 1
    max_fields = (WINDOW - DATA_OFF) // FIELD_OUT
    if fields > max_fields:
        fields = max_fields - (max_fields & 1)
    span = DATA_OFF + fields * FIELD_OUT
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    mem = mmap.mmap(fd, (span + 0xFFF) & ~0xFFF, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
    mem[0:8] = b'\0' * 8                   # invalidate while loading
    with open(path, 'rb') as f:
        for n in range(fields):
            data = f.read(FIELD_IN)
            o = DATA_OFF + n * FIELD_OUT
            for ln in range(H):
                mem[o + ln * LINE_OUT:o + ln * LINE_OUT + LINE_IN] = data[ln * LINE_IN:(ln + 1) * LINE_IN]
                mem[o + ln * LINE_OUT + LINE_IN:o + (ln + 1) * LINE_OUT] = PAD
            if n % 50 == 0:
                print('field %d/%d' % (n, fields), flush=True)
    mem[0:8] = struct.pack('<II', 0x31434254, fields)
    # no mem.flush(): msync is not supported on /dev/mem (EINVAL); O_SYNC mapping is uncached
    mem.close()
    os.close(fd)
    print('loaded %d fields (%.1f s); reset the core from its OSD' % (fields, fields / 50.0))


if __name__ == '__main__':
    main()
