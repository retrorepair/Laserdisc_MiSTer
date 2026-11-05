"""add_cvbs.py - add the composite (CVBS) region to a DSCV stream, for Laserdisc_MiSTer's composite output.

usage: python add_cvbs.py INPUT.tbc STREAM.dscv [--first F] [--no-doc]

The composite output replays the TBC samples, never RGB re-encoded (CLAUDE.md). The CLD-1750's TBC is a CCD
variable delay line locked to its 17.734475 MHz (4fsc) crystal (SM VDTB "VIDEO SECTION", PDF 29 and 54), so
ld-decode's 4fsc TBC is the same signal in digital form.

Each frame stores both fields at 313 lines x 1136 bytes, the second field's 313th line being padding as in the
TBC, then the frame's audio block copied from its DSC frame. The region is independent of the DSC region, so the
Laserdisc Main streams one or the other. Samples are 8-bit DAC codes: code = s * 255 / white (54016 = 100 IRE),
clipped to 0-255. The sync tip (about 0) is code 0 and blanking (14442) is code 68. That is the MiSTer VGA DAC's
0-0.7 V range, and the I/O board's 6-bit DAC uses the top six bits.

Dropout compensation (on by default, --no-doc turns it off): the player's IC401 PA5013 has a dropout sensor
(DOS) and pulse stretch switching to the 1H-delayed video of IC402 (SM PDF 29; adjustment: "level of the 1H-delay
video at pin 33 the same as the main-line video at pin 35", PDF 54). So each dropout span in ld-decode's
.tbc.db is replaced by the same span of the line before it in the same field. The SM gives no pulse-stretch
time, so the spans are used as ld-decode detected them.

Header (DSCV bytes 256-299, reserved in dscv.h):
  256 "CVB1", 260 u32 version 1, 264 u64 frames_offset, 272 u32 stride, 276 u32 frame_bytes (711136),
  280 u16 line_bytes 1136, 282 u16 lines_per_field 313, 284 u16 samples_per_line 1135, 286 u16 0,
  288 u32 audio_off in the frame, 292 u32 white level (54016 = code 255), 296 u32 first source frame,
  300 u32 audio2_off in the frame: the digital audio block (0 = none), right after the analogue one
"""
import argparse
import os
import sqlite3
import struct
import sys
from collections import defaultdict

import numpy as np



def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tbc')
    ap.add_argument('dscv')
    ap.add_argument('--first', type=int, default=0, help='source frame of the stream\'s frame 0')
    ap.add_argument('--no-doc', action='store_true', help='leave dropouts as recorded')
    a = ap.parse_args()

    db = sqlite3.connect(a.tbc + '.db')
    # the capture's line length, field lines and levels (PAL 1135 x 313, white 54016, blanking 14442;
    # NTSC 910 x 263, white 51200, blanking 15360); lines are padded to a multiple of 8 bytes
    system, W, H, WHITE, BLANK = db.execute('select system, field_width, field_height, white_16b_ire, '
                                            'blanking_16b_ire from capture').fetchone()
    W, H, WHITE, BLANK = int(W), int(H), int(WHITE), int(BLANK)
    LB = (W + 7) & ~7
    FRAME_BYTES = 2 * H * LB
    FPS = 25.0 if system == 'PAL' else 30000 / 1001
    tbc = np.memmap(a.tbc, dtype='<u2', mode='r').reshape(-1, H, W)
    f = open(a.dscv, 'r+b')
    h = bytearray(f.read(512))
    if h[:4] != b'DSCV':
        sys.exit('not a DSCV stream')
    count, fdur, flags, fbytes, stride = struct.unpack_from('<5I', h, 28)
    frames_off = struct.unpack_from('<Q', h, 48)[0]
    aud_off = struct.unpack_from('<I', h, 72)[0]
    if not aud_off:
        sys.exit('the DSC region has no audio blocks to copy')
    blk = 8 + 4 * struct.unpack_from('<I', h, 84)[0]
    aud2_off = struct.unpack_from('<I', h, 88)[0]           # the DSC frame's digital audio block (tbc2dscv.c)
    nblk = 2 if aud2_off else 1                              # both blocks are copied, back to back
    c_aud = FRAME_BYTES
    c_aud2 = FRAME_BYTES + blk if aud2_off else 0
    c_stride = (FRAME_BYTES + nblk * blk + 511) & ~511
    dsc_end = frames_off + count * stride
    c_off = (dsc_end + 4095) & ~4095
    f.truncate(c_off)                     # replaces any earlier composite region

    drops = defaultdict(list)
    if not a.no_doc:
        f0, f1 = 2 * a.first, 2 * (a.first + count)
        for fid, ln, sx, ex in db.execute('select field_id, field_line, startx, endx from drop_outs '
                                          'where field_id >= ? and field_id < ?', (f0, f1)):
            drops[fid].append((ln - 1, sx, ex))   # field_line is 1-based

    lut = np.clip(np.round(np.arange(65536) * 255.0 / WHITE), 0, 255).astype(np.uint8)
    out = np.zeros((2, H, LB), np.uint8)
    out[:, :, W:] = lut[BLANK]            # the pad samples of each line: blanking
    n_doc = 0
    for k in range(count):
        for j in range(2):
            fid = 2 * (a.first + k) + j
            fld = np.array(tbc[fid])
            for ln, sx, ex in drops.get(fid, ()):
                if 0 < ln < H and sx < ex:
                    fld[ln, sx:ex] = fld[ln - 1, sx:ex]   # 1H dropout compensation (IC401/IC402)
                    n_doc += 1
            out[j, :, :W] = lut[fld]
        f.seek(frames_off + k * stride + aud_off)
        audio = f.read(nblk * blk)
        f.seek(c_off + k * c_stride)
        f.write(out.tobytes())
        f.write(audio)
        f.write(bytes(c_stride - FRAME_BYTES - nblk * blk))
        if k % 250 == 0:
            print(f'\r  {k} / {count} frames', end='', file=sys.stderr, flush=True)
    struct.pack_into('<4sIQIIHHHHIII', h, 256, b'CVB1', 1, c_off, c_stride, FRAME_BYTES, LB, H, W, 0,
                     c_aud, WHITE, a.first)
    struct.pack_into('<I', h, 300, c_aud2)
    f.seek(0)
    f.write(h)
    f.close()
    print(f'\ncomposite region at {c_off}: {count} frames, stride {c_stride} = {c_stride * FPS / 1e6:.2f} MB/s; '
          f'{n_doc} dropout spans compensated', file=sys.stderr)


if __name__ == '__main__':
    main()
