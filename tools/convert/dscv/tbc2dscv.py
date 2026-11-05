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

Digital audio: when the capture has an .efm sidecar with LaserDisc digital audio (CD audio), Decode-Orc's EFM decoder
sink decodes it bit-exact at 44.1 kHz, and each frame gets it as a second audio block (header byte 88): exactly 1764
samples per PAL frame, 44100 x 1001/30000 per NTSC frame. Each run of readable EFM is decoded separately and aligned
with its own first frame (video_sync), because the decoder splices the audio across EFM it cannot read; frames without
readable EFM carry digital silence. A capture whose EFM has no sync patterns at all gets no digital audio.

usage: python tbc2dscv.py INPUT.tbc OUT.dscv [--first N] [--count N] [--bpp 8] [--no-audio] [--no-digital]
                          [--orc PATH/orc-cli]
"""
import argparse
import os
import re
import shutil
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

OVERLAP = 4          # frames, see the chunk loop
# Geometry per system (the capture's system, from ld-decode's .tbc.db):
#   x0, x1   TBC samples kept, end exclusive: a multiple of 3 (DSC) and of 8 wide, covering the active line
#   y0, y1   frame-flat lines kept, end exclusive (y0 even = first field), VBI lines included
#   src      TBC line length and frame lines; fdur frame duration in us; the Decode-Orc reference decoder
GEOMETRY = {
    # PAL: samples 152-1111 (960: burst end + back porch to front porch), field lines 12-311
    'PAL':  dict(x0=152, x1=1112, y0=24, y1=624, src_w=1135, src_h=625, fdur=40000, decoder='transform3d'),
    # NTSC: samples 130-897 (768: ld-decode's active 134-893 and 4 either side), field lines 10-261
    # (VBI lines 16-18 included); 1001/30 ms frames; ntsc3d is Decode-Orc's adaptive 3D NTSC decoder
    'NTSC': dict(x0=130, x1=898, y0=20, y1=524, src_w=910, src_h=525, fdur=33367, decoder='ntsc3d'),
}


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



def network_root(drive):
    """The UNC root of a mapped network drive (V: maps to //server/share), or None for a local drive."""
    import ctypes
    buf = ctypes.create_unicode_buffer(1024)
    n = ctypes.c_ulong(len(buf))
    if ctypes.windll.mpr.WNetGetConnectionW(drive, buf, ctypes.byref(n)) == 0:
        return buf.value
    return None

EFM_T11_MIN = 0.01   # share of T11 run lengths that marks readable EFM (see efm_runs)


def efm_runs(efm_path, db_path, nframes):
    """Frame runs [(first, last)] whose EFM carries sync patterns.

    Every 588-bit EFM frame starts with the sync pattern, two T11 run lengths, so readable EFM holds about 2.2 % T11
    (measured on Community North). Where ld-decode's EFM slicer had no signal its output is noise with almost no T11
    (0.0-0.3 %, measured on the GGV1011/GGV1069 test discs and Community North's unreadable stretches). Each frame's
    T-values are its two fields' (field_record.efm_t_values, in file order); the low nibble is the T-value."""
    counts = [n or 0 for (n,) in sqlite3.connect(db_path).execute(
        'select efm_t_values from field_record order by field_id')]
    if sum(counts) != os.path.getsize(efm_path):
        print(f'{efm_path}: size does not match the efm_t_values of its fields; no digital audio', file=sys.stderr)
        return []
    nibble = bytes(b & 15 for b in range(256))
    runs, start = [], None
    with open(efm_path, 'rb') as f:
        for k in range(nframes):
            n = counts[2 * k] + counts[2 * k + 1]
            d = f.read(n).translate(nibble)
            readable = n > 0 and d.count(11) >= EFM_T11_MIN * n
            if readable and start is None:
                start = k
            elif not readable and start is not None:
                runs.append((start, k - 1))
                start = None
    if start is not None:
        runs.append((start, nframes - 1))
    return runs


def digital_track(orc, tbc, efm_path, db_path, tmp, nframes, at, orc_rel):
    """The disc's digital audio as one capture-length 44.1 kHz stereo track (digital.pcm in tmp), or None.

    Decode-Orc's EFM decoder aligns its output with the first frame it is given (video_sync), but across EFM it cannot
    read it resyncs the timeline and splices the audio (Community North: a 74 s gap, 5,584 sections), so a single
    whole-capture decode drifts from the picture after the first gap. Each run of readable EFM is therefore decoded on
    its own (frame_map) and placed at its first frame; frames whose EFM is unreadable carry digital silence."""
    runs = efm_runs(efm_path, db_path, nframes)
    if not runs:
        print('no digital audio (no EFM sync patterns in the capture)', file=sys.stderr)
        return None
    out = os.path.join(tmp, 'digital.pcm')
    with open(out, 'wb') as f:
        f.truncate(4 * at(nframes))
    stem = os.path.splitext(tbc)[0]
    for old in os.listdir(os.path.dirname(stem)):            # reports of an earlier conversion
        if old.startswith(os.path.basename(stem) + '.efm_'):
            os.remove(os.path.join(os.path.dirname(stem), old))
    placed = 0
    # orc-cli splits stage parameters on ':', so paths are relative to its working directory
    src = f'tbc_source=input_path={orc_rel(tbc)}:efm_path={orc_rel(efm_path)}'
    for r0, r1 in runs:
        seg = os.path.join(tmp, 'seg.pcm')
        for name in ('seg.pcm', 'seg.pcm.txt'):
            if os.path.exists(os.path.join(tmp, name)):
                os.remove(os.path.join(tmp, name))
        r = subprocess.run([orc, '--source', src, '--filters', f'frame_map=ranges={r0}-{r1}',
                            '--sink', 'EFMSink=output_path=seg.pcm:decode_mode=audio:video_sync=true'
                                      ':no_wav_header=true:report=true'],
                           cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, errors='replace')
        if os.path.exists(seg + '.txt'):                     # kept beside the capture: the lead-in TOC is in it
            shutil.copy(seg + '.txt', f'{stem}.efm_report_{r0}-{r1}.txt')
        want = at(r1 + 1) - at(r0)
        if r.returncode or not os.path.exists(seg) or os.path.getsize(seg) == 0:
            last = [l for l in r.stderr.splitlines() if 'error' in l.lower()][:1]
            print(f'digital audio, frames {r0}-{r1}: not decoded, silent '
                  f'({last[0].split("] ")[-1] if last else "decode failed"})', file=sys.stderr)
            continue
        # The Q-channel control bits mark each track audio or data (IEC 60908); a data track is not sound and a player
        # mutes it. Community North's EFM is a single data track: decoded as audio it is steady noise at -5 dBFS.
        types = re.findall(r'\d\d:\d\d:\d\d\W+\d\d:\d\d:\d\d\W+\d\d:\d\d:\d\d\W+(Audio4|Audio|Data)\b',
                           open(seg + '.txt', encoding='utf-8', errors='replace').read()) \
            if os.path.exists(seg + '.txt') else []
        if types and 'Audio' not in types and 'Audio4' not in types:
            print(f'digital audio, frames {r0}-{r1}: data track(s), not audio; silent', file=sys.stderr)
            continue
        if 'Data' in types:
            print(f'  WARNING: frames {r0}-{r1} mix audio and data tracks; the data is decoded as audio',
                  file=sys.stderr)
        got = os.path.getsize(seg) // 4
        resyncs = r.stderr.count('Implausible forward jump')
        print(f'digital audio, frames {r0}-{r1}: {got} samples for {want}', file=sys.stderr)
        if resyncs:
            print(f'  WARNING: the decoder resynced its timeline {resyncs} time(s) inside this run; the audio after '
                  'that point is spliced and out of step with the picture', file=sys.stderr)
        if abs(got - want) > at(1):
            print(f'  WARNING: {got - want:+d} samples against the run length', file=sys.stderr)
        n = min(got, want)
        with open(seg, 'rb') as s, open(out, 'r+b') as f:
            f.seek(4 * at(r0))
            left = 4 * n
            while left:
                buf = s.read(min(left, 1 << 22))
                f.write(buf)
                left -= len(buf)
        placed += n
    if os.path.exists(seg):
        os.remove(seg)
    print(f'digital audio: {len(runs)} run(s) of readable EFM, {placed} of {at(nframes)} samples', file=sys.stderr)
    return out if placed else None


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
    ap.add_argument('--no-digital', action='store_true', help='leave out the EFM digital audio')
    a = ap.parse_args()

    tbc = os.path.abspath(a.tbc)
    db_path = tbc + '.db'
    system = sqlite3.connect(db_path).execute('select system from capture').fetchone()[0]
    if system not in GEOMETRY:
        sys.exit(f'{db_path}: system {system} is not supported')
    g = GEOMETRY[system]
    X0, X1, Y0, Y1 = g['x0'], g['x1'], g['y0'], g['y1']
    nfields = sqlite3.connect(db_path).execute('select count(*) from field_record').fetchone()[0]
    count = a.count if a.count else nfields // 2 - a.first
    vbi = frame_fields(db_path, a.first, count)

    w, h = X1 - X0, Y1 - Y0
    # The working folder is on the system drive: its picture chunks are large, and a capture drive that is full or a
    # network share slows the conversion several times. orc-cli takes paths without a drive colon (':' separates its
    # parameters): relative to its working directory on the same drive, or a capture on a network drive by its UNC path.
    tmp = tempfile.mkdtemp(prefix='tbc2dscv_')
    orc_rel = lambda f: os.path.relpath(f, tmp)
    if os.path.splitdrive(tbc)[0].lower() != os.path.splitdrive(tmp)[0].lower():
        unc = network_root(os.path.splitdrive(tbc)[0])
        if not unc:
            tmp_other = tempfile.mkdtemp(prefix='tbc2dscv_', dir=os.path.dirname(tbc))   # a local drive: work beside it
            shutil.rmtree(tmp, ignore_errors=True)
            tmp = tmp_other
        else:
            orc_rel = lambda f: (unc + os.path.splitdrive(os.path.abspath(f))[1]).replace(chr(92), '/')
    vbi_path = os.path.join(tmp, 'vbi.bin')
    with open(vbi_path, 'wb') as f:
        f.write(vbi)
    cmd = [ENC, '-o', os.path.abspath(a.out), '-n', str(count), '-w', str(w), '-h', str(h), '-bpp', str(a.bpp),
           '-vbi', vbi_path, '-crop-x', str(X0), '-crop-y', str(Y0), '-src-w', str(g['src_w']),
           '-src-h', str(g['src_h']), '-fdur', str(g['fdur']), '-threads', str(a.threads)]
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
        efm_path = os.path.splitext(tbc)[0] + '.efm'
        if not a.no_digital and os.path.exists(efm_path) and os.path.getsize(efm_path) > 0:
            num, den = (44100, 25) if g['src_h'] == 625 else (44100 * 1001, 30000)
            at = lambda k: k * num // den                # digital samples before frame k (capture time)
            dig = digital_track(a.orc, tbc, efm_path, db_path, tmp, nfields // 2, at, orc_rel)
            if dig:
                counts2_path = os.path.join(tmp, 'counts2.bin')
                with open(counts2_path, 'wb') as f:
                    for k in range(a.first, a.first + count):
                        f.write(struct.pack('<I', at(k + 1) - at(k)))
                cmd += ['-pcm2', dig, str(4 * at(a.first)), counts2_path]
    enc = subprocess.Popen(cmd, stdin=subprocess.PIPE)

    # orc-cli splits stage parameters on ':', so it is given paths relative to
    # its working directory (no drive letters).
    rel_tbc = orc_rel(tbc)
    frame_bytes = w * h * 6
    last_frame = nfields // 2 - 1
    for c0 in range(a.first, a.first + count, a.chunk):
        c1 = min(c0 + a.chunk, a.first + count) - 1
        # The 3D decoders look at neighbouring fields; each chunk is decoded
        # with OVERLAP extra frames either side (discarded) so a chunked run
        # gives the same pictures as one whole-range run.
        d0, d1 = max(0, c0 - OVERLAP), min(last_frame, c1 + OVERLAP)
        rgb = os.path.join(tmp, 'chunk.rgb')
        orc = [a.orc, '--source', f'tbc_source=input_path={rel_tbc}',
               '--filters', f'frame_map=ranges={d0}-{d1},video_params=activeVideoStart={X0}:activeVideoEnd={X1}'
                            f':firstActiveFrameLine={Y0}:lastActiveFrameLine={Y1}',
               '--sink', 'video_sink=output_path=chunk.rgb:output_mode=raw:raw_format=rgb:decoder_type=' + g['decoder']]
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
    shutil.rmtree(tmp, ignore_errors=True)   # chunks, counts, the decoded digital audio, any decoder reports
    sys.exit(rc)


if __name__ == '__main__':
    main()
