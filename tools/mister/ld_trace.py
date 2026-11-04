#!/usr/bin/env python3
"""Trace the Laserdisc core's DDR3 mailbox while launching it (runs ON the MiSTer, python3, standard library).

usage: ld_trace.py [--from-menu] [--mgl PATH] [--seconds N]

Prints a line whenever the header (written by the Laserdisc Main) or the core's status block changes, including
the diagnostics word w4 (core/rtl/ld_stream.sv): control and frame sequencer states, bursts in flight, header
and auxiliary words returned, line words left. With --from-menu the menu core is loaded first, which is the
launch that starts a fresh Laserdisc Main.
"""
import mmap
import os
import struct
import sys
import time

C = ['IDLE', 'WST', 'RHD', 'WAIT', 'PARSE', 'PPS', 'HOLD', '?7']
F = ['IDLE', 'SETUP', 'RUN', 'AUD', 'VBI', 'DONE', '?6', '?7']


def cmd(c):
    with open('/dev/MiSTer_cmd', 'w') as f:
        f.write(c + '\n')


def main():
    a = sys.argv
    mgl = a[a.index('--mgl') + 1] if '--mgl' in a else '/media/fat/_Custom Cores/Laserdisc - Community North.mgl'
    secs = float(a[a.index('--seconds') + 1]) if '--seconds' in a else 20
    if '--from-menu' in a:
        cmd('load_core /media/fat/menu.rbf')
        time.sleep(8)
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x30000000)
    cmd('load_core ' + mgl)
    t0 = time.time()
    last = None
    while time.time() - t0 < secs:
        hgen = struct.unpack_from('<H', m, 6)[0]
        htype = (struct.unpack_from('<I', m, 20)[0] >> 16) & 1
        hvalid = m[0:4] == b'LDH1'
        seq = struct.unpack_from('<I', m, 0x404)[0]
        cgen = struct.unpack_from('<H', m, 0x40E)[0]
        flags = m[0x40C]
        w4 = struct.unpack_from('<Q', m, 0x420)[0]
        diag = (C[w4 & 7], F[(w4 >> 3) & 7], (w4 >> 6) & 31, (w4 >> 11) & 63, (w4 >> 17) & 2047,
                (w4 >> 28) & 1023, (w4 >> 38) & 1, (w4 >> 39) & 1, (w4 >> 40) & 1, (w4 >> 41) & 1, w4 >> 48)
        v = (hgen, htype, hvalid, cgen, flags, diag)
        if v != last:
            print('%5.1f s seq %5d | hdr gen %d type %d valid %d | core gen %d flags %02x | c=%s f=%s tags %d hdr %d '
                  'aux %d lf %d wr %d cw %d fresh %d loaded %d busyflips %d'
                  % ((time.time() - t0, seq, hgen, htype, hvalid, cgen, flags) + diag), flush=True)
            last = v
        time.sleep(0.1)
    print('end: seq %d' % struct.unpack_from('<I', m, 0x404)[0])


if __name__ == '__main__':
    main()
