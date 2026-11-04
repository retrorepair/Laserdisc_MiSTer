"""tbc2dscv.py - ld-decode TBC -> DSCV stream for Laserdisc_MiSTer.

Pipeline: Decode-Orc (Transform PAL 3D, the reference decoder) decodes the TBC
to RGB48 in chunks; tbc2dscv.exe (MiSTer-LaserActive's DSC encoder) codes each
frame at a constant bit rate into the DSCV layout. The VBI table comes from
ld-decode's own biphase decode in the .tbc.db.

Geometry (PAL, measured against the TBC by correlation, see
docs/streaming_design.md): Decode-Orc frame-flat line L is first-field line L/2
for even L and second-field line (L-1)/2 for odd L; output column c is TBC
sample activeVideoStart + c. The defaults keep TBC samples 152..1111 (960 wide:
burst end + back porch to front porch) and frame lines 24..623 (field lines
12..311, so the VBI lines 16-18 and the whole picture are kept).

Audio: the ld-decode .pcm beside the TBC (16-bit stereo, 44.1 kHz) goes into each frame's stride after its
picture (header bytes 72-87, see tbc2dscv.c). Each frame gets the samples of its two fields, as counted by
ld-decode (field_record.audio_samples).

usage: python tbc2dscv.py INPUT.tbc OUT.dscv [--first N] [--count N] [--bpp 8] [--no-audio] [--orc PATH/orc-cli]
"""
import argparse
import os
import sqlite3
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
# Decode-Orc's command-line tool: --orc, else $ORC_CLI, else the project's ref/tools copy
ORC = os.environ.get('ORC_CLI') or os.path.join(ROOT, 'ref', 'tools', 'decode-orc', 'Decode-Orc', 'bin', 'orc-cli.exe')
ENC = os.path.join(HERE, 'tbc2dscv.exe')

X0, X1 = 152, 1112   # TBC samples kept, end exclusive (960, a multiple of 3 and of 8)
OVERLAP = 4          # frames, see the chunk loop
Y0, Y1 = 24, 624     # frame-flat lines kept, end exclusive (600; Y0 even = first field)


def frame_fields(db_path, first, count):
    """Field ids of each frame and the 16-byte VBI entries: first-field lines
    16 and 17, second-field lines 329 and 330 (vbi0/vbi1 of each field)."""
    db = sqlite3.connect(db_path)
    first_flag = dict(db.execute('select field_id, is_first_field from field_record'))
    vbi = {f: (a, b) for f, a, b, _ in db.execute('select field_id, vbi0, vbi1, vbi2 from vbi')}
    table = bytearray()
    for k in range(first, first + count):
        f1, f2 = 2 * k, 2 * k + 1
        # Decode-Orc pairs fields 2k, 2k+1 into frame k on this capture; refuse
        # anything else rather than guess (a capture with a dropped field needs
        # the pairing taken from Decode-Orc itself).
        if first_flag.get(f1) != 1 or first_flag.get(f2) != 0:
            sys.exit(f'frame {k}: fields {f1}/{f2} are not a first/second pair in {db_path}')
        a1, b1 = vbi.get(f1, (0, 0))
        a2, b2 = vbi.get(f2, (0, 0))
        table += struct.pack('<4I', a1, b1, a2, b2)
    return table


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tbc')
    ap.add_argument('out')
    ap.add_argument('--first', type=int, default=0, help='first frame (0-based)')
    ap.add_argument('--count', type=int, help='frames (default: to the end)')
    ap.add_argument('--bpp', type=float, default=8.0)
    ap.add_argument('--orc', default=ORC, help="Decode-Orc's orc-cli (default: $ORC_CLI or ref/tools/decode-orc)")
    ap.add_argument('--chunk', type=int, default=200, help='frames per Decode-Orc run')
    ap.add_argument('--threads', type=int, default=os.cpu_count() or 8)
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--dump', nargs=2, metavar=('K', 'PREFIX'))
    ap.add_argument('--no-audio', action='store_true')
    a = ap.parse_args()

    tbc = os.path.abspath(a.tbc)
    db_path = tbc + '.db'
    nfields = sqlite3.connect(db_path).execute('select count(*) from field_record').fetchone()[0]
    count = a.count if a.count else nfields // 2 - a.first
    vbi = frame_fields(db_path, a.first, count)

    w, h = X1 - X0, Y1 - Y0
    tmp = tempfile.mkdtemp(prefix='tbc2dscv_')
    vbi_path = os.path.join(tmp, 'vbi.bin')
    with open(vbi_path, 'wb') as f:
        f.write(vbi)
    cmd = [ENC, '-o', os.path.abspath(a.out), '-n', str(count), '-w', str(w), '-h', str(h), '-bpp', str(a.bpp),
           '-vbi', vbi_path, '-crop-x', str(X0), '-crop-y', str(Y0), '-src-w', '1135', '-src-h', '625',
           '-fdur', '40000', '-threads', str(a.threads)]
    if a.verify:
        cmd.append('-verify')
    if a.dump:
        cmd += ['-dump', a.dump[0], os.path.abspath(a.dump[1])]
    pcm_path = os.path.splitext(tbc)[0] + '.pcm'
    counts_path = os.path.join(tmp, 'counts.bin')
    if not a.no_audio:
        if not os.path.exists(pcm_path):
            sys.exit(f'{pcm_path} not found (use --no-audio for a picture-only stream)')
        samples = [n for (n,) in sqlite3.connect(db_path).execute(
            'select audio_samples from field_record order by field_id')]
        if sum(samples) * 4 != os.path.getsize(pcm_path):
            sys.exit(f'{pcm_path}: size does not match the audio_samples of its fields')
        with open(counts_path, 'wb') as f:
            for k in range(a.first, a.first + count):
                f.write(struct.pack('<I', samples[2 * k] + samples[2 * k + 1]))
        cmd += ['-pcm', pcm_path, str(4 * sum(samples[:2 * a.first])), counts_path]
    enc = subprocess.Popen(cmd, stdin=subprocess.PIPE)

    # orc-cli splits stage parameters on ':', so it is given paths relative to
    # its working directory (no drive letters).
    rel_tbc = os.path.relpath(tbc, tmp)
    frame_bytes = w * h * 6
    last_frame = nfields // 2 - 1
    for c0 in range(a.first, a.first + count, a.chunk):
        c1 = min(c0 + a.chunk, a.first + count) - 1
        # Transform PAL 3D looks at neighbouring fields; each chunk is decoded
        # with OVERLAP extra frames either side (discarded) so a chunked run
        # gives the same pictures as one whole-range run.
        d0, d1 = max(0, c0 - OVERLAP), min(last_frame, c1 + OVERLAP)
        rgb = os.path.join(tmp, 'chunk.rgb')
        orc = [a.orc, '--source', f'tbc_source=input_path={rel_tbc}',
               '--filters', f'frame_map=ranges={d0}-{d1},video_params=activeVideoStart={X0}:activeVideoEnd={X1}'
                            f':firstActiveFrameLine={Y0}:lastActiveFrameLine={Y1}',
               '--sink', 'video_sink=output_path=chunk.rgb:output_mode=raw:raw_format=rgb:decoder_type=transform3d']
        r = subprocess.run(orc, cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if r.returncode or not os.path.exists(rgb) or os.path.getsize(rgb) != (d1 - d0 + 1) * frame_bytes:
            enc.kill()
            sys.exit(f'Decode-Orc failed on frames {d0}-{d1}:\n{r.stderr[-2000:]}')
        with open(rgb, 'rb') as f:
            f.seek((c0 - d0) * frame_bytes)
            left = (c1 - c0 + 1) * frame_bytes
            while left:
                buf = f.read(min(left, frame_bytes * 16))
                enc.stdin.write(buf)
                left -= len(buf)
        os.remove(rgb)
    enc.stdin.close()
    rc = enc.wait()
    os.remove(vbi_path)
    if os.path.exists(counts_path):
        os.remove(counts_path)
    os.rmdir(tmp)
    sys.exit(rc)


if __name__ == '__main__':
    main()
