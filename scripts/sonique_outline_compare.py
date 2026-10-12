#!/usr/bin/env python3
"""Compare each skin's /rgn/<mode>/frame with the window outline real Sonique drew (the oracle).

usage: python3 -I scripts/sonique_outline_compare.py [<captures dir>] [<corpus dir>]

Reads oracle captures named <skin>__<nav|mid|small>_0.png (scripts/sonique_oracle_capture.sh, 2x,
window-only, binary alpha) and the matching <skin>.sgf. Rasterises the frame with right/bottom read
as exclusive and as inclusive, aligns it to the capture's opaque bounding box at 1x, and prints the
mismatched pixels for each reading, then a summary. What the numbers settled is in
skills/sonique-skin-guide/reference/format.md and harness.md.
"""
import hashlib, os, struct, sys

import numpy as np
from PIL import Image

ORACLE = os.path.expanduser('~/Library/Application Support/NullPlayer/SoniqueOracle')
CAPTURES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ORACLE, 'captures/sample-2026-10-11')
CORPUS = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Library/Application Support/NullPlayer/SoniqueSkins')
PREFIX = {'nav': '/rgn/nav/frame', 'mid': '/rgn/mid/frame', 'small': '/rgn/small/frame'}


def entries(data):
    """The .sgf entry table, names lowercased, first of a name kept (as SoniqueSkinLoader does)."""
    out = {}
    for i in range(struct.unpack_from('<I', data, 0x68)[0]):
        at = 0x70 + i * 0x64
        name = data[at:at + 0x54].split(b'\0')[0].decode('latin1').lower()
        offset, size = struct.unpack_from('<II', data, at + 0x54)
        out.setdefault(name, data[offset:offset + size])
    return out


def raster(payload, inclusive):
    count = struct.unpack_from('<H', payload)[0]
    rects = [struct.unpack_from('<4H', payload, 10 + 8 * i) for i in range(count)]
    mask = np.zeros((max(r[3] for r in rects) + 2, max(r[2] for r in rects) + 2), bool)
    for left, top, right, bottom in rects:
        mask[top:bottom + inclusive, left:right + inclusive] = True
    return mask


def crop(mask):
    ys, xs = np.nonzero(mask)
    return mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def mismatch(outline, frame):
    """XOR at 1x after aligning top-left corners of both bounding boxes, on a canvas covering both."""
    a, b = crop(outline), crop(frame)
    h, w = max(a.shape[0], b.shape[0]), max(a.shape[1], b.shape[1])
    pa, pb = np.zeros((h, w), bool), np.zeros((h, w), bool)
    pa[:a.shape[0], :a.shape[1]] = a
    pb[:b.shape[0], :b.shape[1]] = b
    return int((pa ^ pb).sum())


rows = []
for name in sorted(os.listdir(CAPTURES)):
    skin, _, rest = name.partition('__')
    mode = rest.split('_')[0]
    if mode not in PREFIX or not rest.endswith('_0.png'):
        continue
    outline = (np.asarray(Image.open(os.path.join(CAPTURES, name)).convert('RGBA'))[..., 3] > 0)[::2, ::2]
    frame = entries(open(os.path.join(CORPUS, skin + '.sgf'), 'rb').read()).get(PREFIX[mode])
    shape = hashlib.md5(crop(outline).tobytes()).hexdigest()[:8]
    if frame is None:
        print(f'OUTLINE {skin} {mode} no-frame oracle={shape}')
        continue
    excl, incl = mismatch(outline, raster(frame, 0)), mismatch(outline, raster(frame, 1))
    rows.append((mode, excl, incl))
    print(f'OUTLINE {skin} {mode} exclusive={excl} inclusive={incl} oracle={shape}')

for mode in PREFIX:
    got = [r for r in rows if r[0] == mode]
    if got:
        print(f'SUMMARY {mode}: {len(got)} frames, exclusive closer {sum(e < i for _, e, i in got)}, '
              f'exclusive exact {sum(e == 0 for _, e, _ in got)}, inclusive exact {sum(i == 0 for _, _, i in got)}')
