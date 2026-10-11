# skinrain.py <out_frames_dir> : skins from every family falling in three depth layers behind the opener text
import sys, os, glob, random, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

OUT = sys.argv[1]
SHOTS = os.path.expanduser("~/Documents/shots")
W, H, FPS, SECS = 1920, 1080, 60, 3.5
N = round(FPS * SECS)
LAYERS = [  # (count, box height, screen-heights fallen over the clip, brightness, blur)
    (52, 95, 0.45, 0.40, 2.4),
    (30, 150, 0.75, 0.62, 0.9),
    (14, 230, 1.15, 0.85, 0.0),
]
PICK = {"classic": 16, "original": 12, "original-metal": 7, "modern": 22, "wmp": 22, "audion": 20}
rnd = random.Random(5)

def cutout(path):
    im = Image.open(path).convert("RGBA")
    if im.getpixel((0, 0))[3] == 255:          # white-framed sweep shot: flood the frame away from the corners
        for c in [(0, 0), (im.width - 1, 0), (0, im.height - 1), (im.width - 1, im.height - 1)]:
            ImageDraw.floodfill(im, c, (0, 0, 0, 0), thresh=14)
    box = im.getchannel("A").getbbox()
    return im.crop(box) if box else None

srcs = []
for fam, n in PICK.items():
    files = (glob.glob(f"{SHOTS}/audion-promo*/[0-9]*_*.png") if fam == "audion"
             else glob.glob(f"{SHOTS}/{fam}_*.png"))
    if fam == "original":
        files = [f for f in files if not os.path.basename(f).startswith("original-metal_")]
    rnd.shuffle(files)
    srcs += files[:n]
rnd.shuffle(srcs)
cut = [c for c in (cutout(f) for f in srcs) if c is not None and c.width > 20]

def prep(im, h, bright, blur):
    s = min(h / im.height, 1.7 * h / im.width)    # fit a h x 1.7h box, so a wide skin is not a banner
    im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
    a = im.getchannel("A")
    im = ImageEnhance.Brightness(ImageEnhance.Color(im.convert("RGB")).enhance(0.8)).enhance(bright).convert("RGBA")
    im.putalpha(a)
    return im.filter(ImageFilter.GaussianBlur(blur)) if blur else im

drops, k = [], 0
for count, h, fall, bright, blur in LAYERS:
    for j in range(count):
        im = prep(cut[k % len(cut)], h, bright, blur); k += 1
        drops.append(dict(im=im, x=(j + rnd.uniform(0.1, 0.9)) / count * W,
                          y0=rnd.uniform(-0.15, 1.0) * H - im.height, fall=fall * H,
                          sway=rnd.uniform(4, 10), swph=rnd.random() * 2 * math.pi))

yy, xx = np.mgrid[0:H, 0:W]
r = np.hypot((xx - W / 2) / W, (yy - H / 2) / H)
v = (np.clip(1 - r * 1.2, 0, 1) * 24 + 8)[..., None]
bg = Image.fromarray(np.concatenate([v, v, v * 1.15], axis=2).clip(0, 255).astype(np.uint8)).convert("RGBA")
# dark scrim behind the centred text block
e = np.exp(-(((xx - W / 2) / 760) ** 2 + ((yy - H / 2) / 230) ** 2))
scrim = Image.fromarray(np.dstack([np.zeros((H, W, 3)), e * 225]).astype(np.uint8), "RGBA")

os.makedirs(OUT, exist_ok=True)
for n in range(N):
    t = n / N
    frame = bg.copy()
    for d in drops:
        im = d["im"].rotate(d["sway"] * math.sin(2 * math.pi * t * 0.6 + d["swph"]), resample=Image.BICUBIC, expand=True)
        frame.alpha_composite(im, (round(d["x"] - im.width / 2), round(d["y0"] + d["fall"] * t))) if -im.height < d["y0"] + d["fall"] * t < H and -im.width < d["x"] - im.width / 2 < W else None
    frame.alpha_composite(scrim)
    frame.convert("RGB").save(f"{OUT}/{n:04d}.png")
print(N, "frames,", len(drops), "drops from", len(cut), "skins")
