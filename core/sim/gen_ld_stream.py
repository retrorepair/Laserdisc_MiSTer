"""Inputs for tb_ld_stream.sv from a DSCV file and tbc2dscv's -dump of the same frame.

usage: python gen_ld_stream.py STREAM.dscv FRAME DUMP_dsc.ppm OUTDIR
Writes hdr.hex (ld_stream header block, frame FRAME in slot 0), slot.hex (its words) and exp.hex (the frame buffer
ld_stream must write: fields woven, 32-bit pixels, R in byte 0).
"""
import struct
import sys

path, frame, ppm, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(path, 'rb') as f:
    h = f.read(512)
    (ver, hsize, src_w, src_h, crop_x, crop_y, w, ht, f0, f0n, f1, f1n) = struct.unpack_from('<12H', h, 4)
    count, fdur, flags, fbytes, stride = struct.unpack_from('<5I', h, 28)
    frames_off, vbi_off = struct.unpack_from('<2Q', h, 48)
    pps = h[128:256]
    aud_off = struct.unpack_from('<I', h, 72)[0]
    f.seek(frames_off + frame * stride)
    data = f.read(aud_off + 8192 if aud_off else fbytes)
    f.seek(vbi_off + frame * 16)
    vbi = f.read(16)
words = (fbytes + 7) // 8
data += bytes(-len(data) % 8)
vbi_word = len(data) // 8            # the VBI entry follows the picture and audio, as the Laserdisc Main loads it
data += vbi
slot_words = len(data) // 8
data += bytes(max(0, words * 8 - len(data)))
hdr = [0] * 28
hdr[0] = 0x3148444C | (1 << 32) | (1 << 48)
hdr[1] = count | (words << 32)
hdr[2] = f1 | (crop_x << 16) | (crop_y << 32)
hdr[3] = (aud_off // 8) | (vbi_word << 32)
for i in range(16):
    hdr[4 + i] = struct.unpack_from('<Q', pps, 8 * i)[0]
for k in range(8):
    hdr[20 + k] = 0xFFFFFFFFFFFFFFFF
hdr[20] = (0xFFFFFFFF << 32) | frame              # slot 0 = FRAME, slot 1 empty
with open(f'{out}/hdr.hex', 'w') as f:
    f.writelines(f'{v:016X}\n' for v in hdr)
with open(f'{out}/slot.hex', 'w') as f:
    f.writelines(f'{struct.unpack_from("<Q", data, 8 * i)[0]:016X}\n' for i in range(slot_words))
# expected frame buffer from the C decoder's picture (field-stacked rows)
with open(ppm, 'rb') as f:
    assert f.readline().strip() == b'P6'
    pw, ph = map(int, f.readline().split())
    f.readline()
    pic = f.read()
assert (pw, ph) == (w, ht)
with open(f'{out}/exp.hex', 'w') as f:
    for row in range(ht):
        src = row // 2 if row % 2 == 0 else f1 + row // 2
        line = pic[src * w * 3:(src + 1) * w * 3]
        for c in range(0, w, 2):
            r0, g0, b0 = line[3 * c:3 * c + 3]
            r1, g1, b1 = line[3 * c + 3:3 * c + 6]
            f.write(f'{(b1 << 48) | (g1 << 40) | (r1 << 32) | (b0 << 16) | (g0 << 8) | r0:016X}\n')
print(f'{w}x{ht}, {words} words, field1_row {f1}, crop {crop_x},{crop_y}, {count} frames, '
      f'audio at word {aud_off // 8}, {slot_words} slot words')
