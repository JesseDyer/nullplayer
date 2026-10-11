# rain.py <out_frames_dir> <shots_dir>... — faces falling in three depth layers, seamless 6 s loop.
import sys, os, random, math
import numpy as np
from PIL import Image, ImageFilter, ImageEnhance

OUT, DIRS = sys.argv[1], sys.argv[2:]
W, H, FPS, SECS = 1920, 1080, 50, 6
N = FPS * SECS
CLIP_FPS, CLIP_LEN = 4, 8
LAYERS = [  # (count, face height, falls per loop, darken, blur, sway deg)
    (56, 90, 1, 0.55, 2.0, 8),
    (30, 140, 1, 0.80, 0.6, 10),
    (14, 220, 2, 1.00, 0.0, 12),
]
rnd = random.Random(11)
LOGO = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), '../../Sources/NullPlayer/Resources/AppIcon.png')
clips = [f"{d}/frames/{s}" for d in DIRS for s in sorted(os.listdir(f"{d}/frames")) if not s.startswith('.')]
rnd.shuffle(clips)

def load(path, h, darken, blur):
    out = []
    for i in range(1, CLIP_LEN + 1):
        im = Image.open(f"{path}/f{i}.png").convert("RGBA")
        im = im.resize((max(1, round(im.width * h / im.height)), h), Image.LANCZOS)
        if darken < 1:
            a = im.getchannel("A")
            im = ImageEnhance.Brightness(ImageEnhance.Color(im.convert("RGB")).enhance(0.7)).enhance(darken).convert("RGBA")
            im.putalpha(a)
        if blur:
            im = im.filter(ImageFilter.GaussianBlur(blur))
        out.append(im)
    return out

drops, k = [], 0
for li, (count, h, falls, darken, blur, sway) in enumerate(LAYERS):
    for j in range(count):
        frames = load(clips[k % len(clips)], h, darken, blur); k += 1
        x = (j + rnd.uniform(0.1, 0.9)) / count * W     # stratified columns
        drops.append(dict(layer=li, frames=frames, x=x, falls=falls, phase=rnd.random(),
                          sway=sway, swph=rnd.random() * 2 * math.pi))

yy = np.linspace(0, 1, H)[:, None, None]
grad = (np.array([150, 160, 178]) * (1 - yy) + np.array([196, 202, 212]) * yy).repeat(W, axis=1)
bg = Image.fromarray(grad.astype(np.uint8)).convert("RGBA")

# NullPlayer logo + wordmark with a soft glow, drawn under the front layer only
from PIL import ImageDraw, ImageFont
font = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 210); font.set_variation_by_name('Heavy')
icon = Image.open(LOGO).convert("RGBA").resize((340, 340), Image.LANCZOS)
tw = ImageDraw.Draw(bg).textbbox((0, 0), "NullPlayer", font=font)
gap = 20; total = icon.width + gap + (tw[2] - tw[0])
bx = (W - total) // 2
tx = bx + icon.width + gap - tw[0]
glow = Image.new("RGBA", (W, H))
ImageDraw.Draw(glow).text((tx, H // 2), "NullPlayer", font=font, fill=(255, 255, 255, 230), anchor="lm", stroke_width=30, stroke_fill=(255, 255, 255, 230))
glow.paste(Image.new("RGBA", icon.size, (255, 255, 255, 230)), (bx, (H - icon.height) // 2), icon)
brand = glow.filter(ImageFilter.GaussianBlur(40))
brand.alpha_composite(icon, (bx, (H - icon.height) // 2))
ImageDraw.Draw(brand).text((tx, H // 2), "NullPlayer", font=font, fill=(36, 40, 50, 255), anchor="lm")

first_front = next(d for d in drops if d["layer"] == 2)
os.makedirs(OUT, exist_ok=True)
for n in range(N):
    t = n / N                                            # 0..1 over the loop
    frame = bg.copy()
    ci = int(n / FPS * CLIP_FPS) % CLIP_LEN
    for d in drops:
        if d is first_front:
            frame.alpha_composite(brand)
        im = d["frames"][ci]
        ang = d["sway"] * math.sin(2 * math.pi * t + d["swph"])
        im = im.rotate(ang, resample=Image.BICUBIC, expand=True)
        span = H + im.height + 40
        y = ((d["phase"] + d["falls"] * t) % 1) * span - im.height - 20
        frame.paste(im, (round(d["x"] - im.width / 2), round(y)), im)
    frame.convert("RGB").save(f"{OUT}/{n:04d}.png")
print(N, "frames,", len(drops), "drops from", len(clips), "faces")
