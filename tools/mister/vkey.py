#!/usr/bin/env python3
"""Virtual keyboard + screenshot sequencer for testing the core on the MiSTer (runs ON the MiSTer).

Creates a uinput keyboard (Main picks it up like a real USB keyboard and passes keys to the core),
then runs a script of steps:  key NAME | hold NAME SECONDS | wait SECONDS | shot LABEL
Screenshots go to /media/fat/screenshots/<core>/ and are copied to <outdir>/shot_<LABEL>.png.

Usage: vkey.py <outdir> "key enter" "wait 2" "shot spinup" ...
"""
import fcntl
import glob
import os
import shutil
import struct
import sys
import time

KEYS = {'enter': 28, 'space': 57, 'p': 25, 's': 31, 'e': 18, 'left': 105, 'right': 106,
        'comma': 51, 'dot': 52, 'y': 21}
EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502


def emit(fd, typ, code, val):
    t = time.time()
    os.write(fd, struct.pack('llHHi', int(t), int((t % 1) * 1e6), typ, code, val))


def tap(fd, code, hold=0.08):
    emit(fd, EV_KEY, code, 1); emit(fd, EV_SYN, 0, 0)
    time.sleep(hold)
    emit(fd, EV_KEY, code, 0); emit(fd, EV_SYN, 0, 0)


def shot(outdir, label):
    open('/dev/MiSTer_cmd', 'w').write('screenshot\n')
    time.sleep(2.5)
    files = sorted(glob.glob('/media/fat/screenshots/*/*.png'), key=os.path.getmtime)
    shutil.copy(files[-1], os.path.join(outdir, 'shot_%s.png' % label))
    print('shot', label, '<-', files[-1], flush=True)


def main():
    outdir = sys.argv[1]
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for c in KEYS.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, c)
    name = b'laserdisc-test-kbd'.ljust(80, b'\0')
    dev = name + struct.pack('HHHH', 3, 0x1234, 0x5678, 1) + struct.pack('I', 0) + b'\0' * (4 * 64 * 4)
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(3)                                   # let Main discover the device
    try:
        for step in sys.argv[2:]:
            a = step.split()
            if a[0] == 'key':
                tap(fd, KEYS[a[1]])
            elif a[0] == 'hold':
                tap(fd, KEYS[a[1]], float(a[2]))
            elif a[0] == 'wait':
                time.sleep(float(a[1]))
            elif a[0] == 'shot':
                shot(outdir, a[1])
            print('step', step, flush=True)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)


if __name__ == '__main__':
    main()
