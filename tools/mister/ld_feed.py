#!/usr/bin/env python3
"""Feed a DSCV stream to the Laserdisc_MiSTer core through DDR3 (runs ON the MiSTer: python3, standard library).

usage: ld_feed.py FILE.dscv [--ahead N]

This is the reader-thread half of the planned Main fork (docs/streaming_design.md), so the core can be run on
hardware before that exists. It reads only the stream's real frames; it never makes up a picture.
  - Writes the header block (PPS, frame count, geometry) at 0x30000000 with a new disc generation.
  - Every few ms it reads the core's status block at 0x30000400. It keeps the wanted frame and the next N frames
    in the direction of travel (the step between successive wanted frames) in the 16 slots at 0x30100000.
  - A slot is never replaced while it holds the frame the core wants or is decoding. Its table entry is
    cleared before the data is overwritten, and set again after.
Ctrl-C or kill (SIGTERM) removes the disc (header magic cleared).
The layout must match core/rtl/ld_stream.sv.
"""
import mmap
import os
import signal
import struct
import sys
import time

BASE = 0x30000000
HDR, STAT, RING, SLOT = 0x0, 0x400, 0x100000, 0x100000
SLOTS = 16
EMPTY = 0xFFFFFFFF
TABLE = HDR + 20 * 8                       # 16 x u32
MAP_LEN = RING + SLOTS * SLOT


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    ahead = int(sys.argv[sys.argv.index('--ahead') + 1]) if '--ahead' in sys.argv else 8
    fd = os.open(path, os.O_RDONLY)
    h = os.pread(fd, 512, 0)
    if h[:4] != b'DSCV':
        sys.exit(f'{path}: not a DSCV stream')
    (ver, hsize, src_w, src_h, crop_x, crop_y, w, ht, f0, f0n, f1, f1n) = struct.unpack_from('<12H', h, 4)
    count, fdur, flags, fbytes, stride = struct.unpack_from('<5I', h, 28)
    frames_off, vbi_off = struct.unpack_from('<2Q', h, 48)
    pps = h[128:256]
    aud_off = struct.unpack_from('<I', h, 72)[0]       # audio block after the picture (tbc2dscv.c), 0 = none
    load_bytes = aud_off + 8192 if aud_off else fbytes  # picture, then the 1024-word audio block
    if load_bytes > SLOT or load_bytes > stride:
        sys.exit(f'frames of {load_bytes} bytes do not fit a {SLOT}-byte slot')
    words = (fbytes + 7) // 8

    mfd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)          # O_SYNC: uncached, stores in order
    mem = mmap.mmap(mfd, MAP_LEN, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)

    def u32(off, v=None):
        if v is None:
            return struct.unpack_from('<I', mem, off)[0]
        mem[off:off + 4] = struct.pack('<I', v)

    # header: invalidate, fill, then validate with a new generation
    old = mem[HDR:HDR + 8]
    gen = (struct.unpack_from('<H', old, 6)[0] + 1) & 0xFFFF if old[:4] == b'LDH1' else 1
    gen = gen or 1
    mem[HDR:HDR + 8] = b'\0' * 8
    mem[HDR + 8:HDR + 32] = struct.pack('<IIIIQ', count, words, f1 | (crop_x << 16), crop_y, aud_off // 8)
    mem[HDR + 32:HDR + 160] = pps
    for k in range(SLOTS):
        u32(TABLE + 4 * k, EMPTY)
    mem[HDR:HDR + 8] = struct.pack('<IHH', 0x3148444C, 1, gen)
    print(f'{path}: {count} frames {w}x{ht}, {fbytes} B/frame, audio {"yes" if aud_off else "none"}; '
          f'disc generation {gen}', flush=True)

    # a background job ignores SIGINT, so SIGTERM (plain `kill`) also ends the run cleanly
    def on_term(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, on_term)
    slot_f = [EMPTY] * SLOTS
    last_seq = last_want = None
    step = 1
    loads = 0
    t_stat = time.time()
    try:
        while True:
            st = mem[STAT:STAT + 32]
            magic, seq, want, flags_, _, decoding, shown = struct.unpack_from('<IIHHIII', st, 0)
            late, errors, kclks, decoded = (struct.unpack_from('<HHHH', st, 24)[::-1])
            if magic != 0x3153444C or (struct.unpack_from('<H', st, 14)[0] != gen):
                time.sleep(0.01)                 # the core has not seen this disc yet
                continue
            if seq != last_seq:
                if last_want is not None and want != last_want:
                    step = want - last_want
                last_seq, last_want = seq, want
            d = step if step != 0 else 1
            wanted = []
            for i in range(ahead + 1):
                f = want + i * d
                if 0 <= f < count:
                    wanted.append(f)
            pinned = {want, decoding}
            for f in wanted:
                if f in slot_f:
                    continue
                victims = [k for k in range(SLOTS) if slot_f[k] == EMPTY] or \
                          [k for k in range(SLOTS) if slot_f[k] not in wanted and slot_f[k] not in pinned]
                if not victims:
                    break
                k = victims[0]
                u32(TABLE + 4 * k, EMPTY)
                slot_f[k] = EMPTY
                data = os.pread(fd, load_bytes, frames_off + f * stride)
                mem[RING + k * SLOT:RING + k * SLOT + len(data)] = data
                u32(TABLE + 4 * k, f)
                slot_f[k] = f
                loads += 1
                break                            # one frame per pass, then look at the status again
            else:
                time.sleep(0.003)
            if time.time() - t_stat >= 2:
                t_stat = time.time()
                print(f'want {want} shown {"-" if shown == EMPTY else shown} step {step}: {decoded} decoded, '
                      f'{late} late, {errors} errors, {kclks * 256 / 70937.9:.1f} ms/decode, {loads} loads',
                      flush=True)
    except KeyboardInterrupt:
        pass
    mem[HDR:HDR + 8] = b'\0' * 8
    mem.close()
    os.close(mfd)
    print('disc removed')


if __name__ == '__main__':
    main()
