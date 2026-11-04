"""Inputs for tb_cvbs.sv: header block (composite stream) and one frame's composite slot from a DSCV with a
composite region (tools/convert/dscv/add_cvbs.py).  usage: python gen_cvbs.py STREAM.dscv FRAME OUTDIR"""
import struct
import sys

path, frame, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path, 'rb') as f:
    h = f.read(512)
    count = struct.unpack_from('<I', h, 28)[0]
    vbi_off = struct.unpack_from('<Q', h, 56)[0]
    mag, ver, coff, cstr, cfb, lb, lpf, spl, _, caud, white, first = struct.unpack_from('<4sIQIIHHHHIII', h, 256)
    assert mag == b'CVB1'
    f.seek(coff + frame * cstr)
    data = f.read(caud + 8192)
    f.seek(vbi_off + frame * 16)
    data += f.read(16)
vbi_word = (caud + 8192) // 8
hdr = [0] * 28
hdr[0] = 0x3148444C | (1 << 32) | (1 << 48)
hdr[1] = count | (((cfb + 7) // 8) << 32)
hdr[2] = 1 << 48                                  # the composite stream
hdr[3] = (caud // 8) | (vbi_word << 32)
for k in range(8):
    hdr[20 + k] = 0xFFFFFFFFFFFFFFFF
hdr[20] = (0xFFFFFFFF << 32) | frame
with open(f'{out}/cv_hdr.hex', 'w') as f:
    f.writelines(f'{v:016X}\n' for v in hdr)
with open(f'{out}/cv_slot.hex', 'w') as f:
    f.writelines(f'{struct.unpack_from("<Q", data, 8 * i)[0]:016X}\n' for i in range(len(data) // 8))
print(len(data) // 8, 'slot words; audio at word', caud // 8, 'VBI at', vbi_word)
