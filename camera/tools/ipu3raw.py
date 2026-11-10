#!/usr/bin/python3
"""ipu3raw.py FILE WIDTH HEIGHT BPL ORDER OUT.png [frame]
Decode IPU3 packed RAW10 (25 pixels in 32 bytes) and write a half-size RGB preview
(2x2 Bayer cell -> 1 pixel, grey-world white balance, gamma 2.2)."""
import sys
import numpy as np
from PIL import Image

path, w, h, bpl, order, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
frame = int(sys.argv[7]) if len(sys.argv) > 7 else 0
data = np.fromfile(path, dtype=np.uint8)
fsize = bpl * h
buf = data[frame * fsize:(frame + 1) * fsize].reshape(h, bpl)
blocks = buf.reshape(h, bpl // 32, 32)
bits = np.unpackbits(blocks, axis=2, bitorder="little")[:, :, :250].reshape(h, -1, 10)
vals = (bits * (1 << np.arange(10))).sum(axis=2).astype(np.float32).reshape(h, -1)[:, :w]
pos = {c: [] for c in "RGB"}
for i, c in enumerate(order):
    pos[c].append((i // 2, i % 2))
def plane(y, x):
    return vals[y::2, x::2]
r = plane(*pos["R"][0]); b = plane(*pos["B"][0])
g = (plane(*pos["G"][0]) + plane(*pos["G"][1])) / 2
black = 64.0
rgb = np.stack([r, g, b], axis=2) - black
rgb = np.clip(rgb, 0, None)
print("raw min/mean/max: %.0f/%.1f/%.0f" % (vals.min(), vals.mean(), vals.max()))
means = rgb.reshape(-1, 3).mean(axis=0)
print("channel means R/G/B: %.1f %.1f %.1f" % tuple(means))
if "--nowb" not in sys.argv:
    rgb = rgb * (means[1] / np.maximum(means, 1e-3))
rgb = rgb / max(np.percentile(rgb, 99.5), 1)
rgb = np.clip(rgb, 0, 1) ** (1 / 2.2)
Image.fromarray((rgb * 255).astype(np.uint8)).save(out)
print("wrote", out, rgb.shape)
