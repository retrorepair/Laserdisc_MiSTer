"""dscv_info.py - print a DSCV stream's header and VBI codes (layout: LaserActive's dscv.h).

usage: python dscv_info.py FILE.dscv [--vbi FIRST COUNT]
Runs on the MiSTer too (python3, standard library only).
"""
import struct
import sys


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    with open(path, 'rb') as f:
        h = f.read(512)
        if h[:4] != b'DSCV':
            sys.exit(f'{path}: not a DSCV stream')
        (ver, hsize, src_w, src_h, crop_x, crop_y, w, ht, f0, f0n, f1, f1n) = struct.unpack_from('<12H', h, 4)
        (count, fdur, flags, fbytes, stride) = struct.unpack_from('<5I', h, 28)
        frames_off, vbi_off = struct.unpack_from('<2Q', h, 48)
        vbi_entry, slices = struct.unpack_from('<2I', h, 64)
        pps = h[128:256]
        bpp16 = ((pps[4] & 3) << 8) | pps[5]
        print(f'version {ver}, header {hsize} B; source {src_w}x{src_h}, kept {w}x{ht} from x={crop_x} y={crop_y}')
        print(f'fields: rows {f0}+{f0n}, {f1}+{f1n}; {slices} slices; DSC {bpp16 / 16:g} bpp')
        print(f'{count} frames of {fdur} us; {fbytes} B/frame, stride {stride}, frames at {frames_off}; '
              f'{stride * 1e6 / fdur / 1e6:.2f} MB/s')
        print(f'VBI table at {vbi_off}, {vbi_entry} B/entry')
        aud_off, rate = struct.unpack_from('<2I', h, 72)
        if aud_off:
            ch, bits = struct.unpack_from('<2H', h, 80)
            print(f'audio: block at frame offset {aud_off}, {rate} Hz, {ch} ch, {bits} bit, '
                  f'up to {struct.unpack_from("<I", h, 84)[0]} samples per frame')
        else:
            print('audio: none')
        if len(sys.argv) >= 5 and sys.argv[2] == '--vbi' and vbi_off:
            first, n = int(sys.argv[3]), int(sys.argv[4])
            f.seek(vbi_off + first * vbi_entry)
            for k in range(first, min(first + n, count)):
                codes = struct.unpack('<4I', f.read(16))
                print(f'  frame {k}: ' + ' '.join(f'{c:06X}' for c in codes))


if __name__ == '__main__':
    main()
