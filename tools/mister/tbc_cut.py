"""Cut an even run of fields, starting on a first field, out of an ld-decode .tbc (PC side).

Usage: tbc_cut.py <in.tbc> <start_frame_hint> <num_frames> <out.tbc>

The start is moved forward to the next field whose metadata says isFirstField, so the chunk
always begins with a 312-line first field as tbc_reader.v expects.
"""
import json
import sys

W, H = 1135, 313
FIELD_BYTES = W * H * 2


def main():
    src, start, frames, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    meta = json.load(open(src + '.json'))['fields']
    f = 2 * start
    while not meta[f]['isFirstField']:
        f += 1
    n = 2 * frames
    with open(src, 'rb') as i, open(out, 'wb') as o:
        i.seek(f * FIELD_BYTES)
        o.write(i.read(n * FIELD_BYTES))
    print('fields %d..%d (%d fields, %d bytes) -> %s' % (f, f + n - 1, n, n * FIELD_BYTES, out))


if __name__ == '__main__':
    main()
