# parallax.py <shots_dir> <out_frames_dir>
# Three depth rows of live face clips scrolling left at depth-scaled speeds; seamless loop.
import sys, os, random
import numpy as np
from PIL import Image, ImageFilter, ImageEnhance

SHOTS, OUT = sys.argv[1], sys.argv[2]
W, H, FPS, SECS = 960, 540, 15, 24
N = FPS * SECS
CLIP_FPS, CLIP_LEN = 4, 8            # captured 0.25 s apart, 8 frames
ROWS = [  # (face height, y centre, gap, darken, blur)
    (88, 92, 26, 0.55, 1.2),
    (138, 250, 34, 0.80, 0.4),
    (200, 418, 44, 1.00, 0.0),
]

slugs = sorted(d for d in os.listdir(f"{SHOTS}/frames") if not d.startswith('.'))
random.Random(7).shuffle(slugs)
groups = [slugs[0::3], slugs[1::3], slugs[2::3]]

def load(slug, h, darken, blur):
    out = []
    for i in range(1, CLIP_LEN + 1):
        im = Image.open(f"{SHOTS}/frames/{slug}/f{i}.png").convert("RGBA")
        w = round(im.width * h / im.height)
        im = im.resize((w, h), Image.LANCZOS)
        if darken < 1:
            a = im.getchannel("A")
            im = ImageEnhance.Brightness(ImageEnhance.Color(im.convert("RGB")).enhance(0.7)).enhance(darken).convert("RGBA")
            im.putalpha(a)
        if blur:
            im = im.filter(ImageFilter.GaussianBlur(blur))
        out.append(im)
    return out

rows = []
for (h, yc, gap, darken, blur), group in zip(ROWS, groups):
    clips = [load(s, h, darken, blur) for s in group]
    xs, x = [], 0
    for c in clips:
        xs.append(x); x += c[0].width + gap
    rows.append((clips, xs, x, yc))  # x = strip width; one full traversal per loop

# soft vertical gradient background with a vignette
yy, xx = np.mgrid[0:H, 0:W]
r = np.hypot((xx - W / 2) / W, (yy - H / 2) / H)
v = (np.clip(1 - r * 1.1, 0, 1) * 60 + 120)[..., None]
bg = Image.fromarray(np.concatenate([v * 0.96, v * 0.98, v * 1.04], axis=2).clip(0, 255).astype(np.uint8)).convert("RGBA")

os.makedirs(OUT, exist_ok=True)
for n in range(N):
    frame = bg.copy()
    ci = int(n / FPS * CLIP_FPS) % CLIP_LEN
    for clips, xs, strip, yc in rows:
        off = strip * n / N
        for c, x0 in zip(clips, xs):
            im = c[ci]
            for rep in (0, strip):            # draw the wrap-around copy too
                x = round(x0 + rep - off)
                if x < W and x + im.width > 0:
                    frame.paste(im, (x, yc - im.height // 2), im)
    frame.convert("RGB").save(f"{OUT}/{n:04d}.png")
print(N, "frames", [len(g) for g in groups])
