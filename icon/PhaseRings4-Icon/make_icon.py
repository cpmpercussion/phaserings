"""PhaseRings icon, jazzed-up variant.

Same idea as the shipping icon (concentric rings, each wobbling at a
different frequency) with bolder strokes, a light-green ombre, and texture:
ripple interference in the background, a soft centre glow, glowing ring
strokes with a drop shadow, and fine grain.
"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1] if len(sys.argv) > 1 else "icon_v2.png"
S = 1024
SS = 3                      # supersample factor
N = S * SS
C = N / 2

rng = np.random.default_rng(7)
y, x = np.mgrid[0:N, 0:N].astype(np.float32)
dx, dy = (x - C) / N, (y - C) / N
r = np.hypot(dx, dy)
theta = np.arctan2(dy, dx)

# --- background: light mint -> green-teal ombre (top-left to bottom-right)
top = np.array([196, 255, 214], np.float32)     # pale mint
mid = np.array([104, 230, 176], np.float32)     # light green
bot = np.array([22, 168, 148], np.float32)      # green-teal
t = np.clip((0.75 * (y / N) + 0.25 * (x / N)), 0, 1)[..., None]
bg = np.where(t < 0.5, top + (mid - top) * (t / 0.5), mid + (bot - mid) * ((t - 0.5) / 0.5))

# centre glow
glow = np.exp(-(r / 0.30) ** 2)[..., None]
bg = bg + glow * np.array([40, 30, 20], np.float32)

# ripple texture: two offset wave sources interfering, very faint
def ripple(cx, cy, k):
    return np.cos(np.hypot(x / N - cx, y / N - cy) * k)
rip = (ripple(0.5, 0.5, 2 * np.pi * 34) * 0.5 + ripple(0.28, 0.22, 2 * np.pi * 21) * 0.3
       + ripple(0.80, 0.70, 2 * np.pi * 27) * 0.2)
bg = bg + (rip * 12.0)[..., None]

# vignette
edge = np.clip((r / 0.70) ** 2.4, 0, 1)[..., None]
deep = np.array([6, 92, 70], np.float32)
bg = bg * (1 - 0.70 * edge) + deep * (0.70 * edge)

# --- rings: (base radius, wobble amplitude, lobes, phase), radius as fraction of size
RINGS = [
    (0.455, 0.000, 0, 0.0),
    (0.375, 0.035, 22, 0.0),
    (0.295, 0.000, 0, 0.0),
    (0.215, 0.018, 9, 0.4),
    (0.150, 0.022, 19, 0.0),
    (0.068, 0.012, 15, 0.0),
]
STROKE = 15 * SS            # bold stroke at 1024
INNER_STROKE = 11 * SS      # tiny inner ring gets a lighter stroke so it reads


def ring_points(base, amp, lobes, phase, n=4000):
    a = np.linspace(0, 2 * np.pi, n, endpoint=False)
    rr = base + amp * np.sin(lobes * a + phase)
    return [(C + rr_ * N * np.cos(a_), C + rr_ * N * np.sin(a_)) for a_, rr_ in zip(a, rr)]


def draw_rings(width_scale=1.0, offset=(0, 0)):
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    for i, (base, amp, lobes, ph) in enumerate(RINGS):
        w = INNER_STROKE if i == len(RINGS) - 1 else STROKE
        w = int(w * width_scale)
        h = w / 2
        # stamp round brushes along the path: clean, even edges at any width
        for px, py in ring_points(base, amp, lobes, ph, n=16000):
            px += offset[0]; py += offset[1]
            d.ellipse([px - h, py - h, px + h, py + h], fill=255)
    return np.asarray(m, np.float32) / 255.0

line = draw_rings()
halo = np.asarray(Image.fromarray((draw_rings(2.6) * 255).astype(np.uint8))
                  .filter(ImageFilter.GaussianBlur(14 * SS)), np.float32) / 255.0
shadow = np.asarray(Image.fromarray((draw_rings(1.2, (0, 7 * SS)) * 255).astype(np.uint8))
                    .filter(ImageFilter.GaussianBlur(6 * SS)), np.float32) / 255.0

img = bg.copy()
# soft light halo around the rings (gives them a luminous edge on the gradient)
img = img + halo[..., None] * np.array([70, 70, 50], np.float32) * 0.55
# drop shadow
img = img * (1 - 0.30 * shadow[..., None])

# ring stroke colour: deep teal-green, slightly lighter toward the top of each stroke
ink_dark = np.array([8, 52, 52], np.float32)
ink_light = np.array([20, 92, 84], np.float32)
ink_t = np.clip(y / N, 0, 1)[..., None]
ink = ink_light + (ink_dark - ink_light) * ink_t
img = img * (1 - line[..., None]) + ink * line[..., None]

img = np.clip(img, 0, 255).astype(np.uint8)
out = Image.fromarray(img, "RGB").resize((S, S), Image.Resampling.LANCZOS)

# fine grain applied at final resolution
a = np.asarray(out, np.float32)
grain = rng.normal(0, 6.0, (S, S, 1)).astype(np.float32)
a = np.clip(a + grain, 0, 255).astype(np.uint8)
Image.fromarray(a, "RGB").save(OUT)
print("wrote", OUT)
