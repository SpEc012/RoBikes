# Make colour variants of the bike texture by moving the orange plastics/rims to another hue.
# White, black and grey parts are left alone. Usage: python3 recolour_bike.py <bike_colour_map.png> <out_dir>
import sys, os
import numpy as np
from PIL import Image

# name: (hue degrees, saturation scale, value scale). Hues match BikeRenderer's PALETTE per bike.
VARIANTS = {
    'orange': None,                 # the original
    'red': (2, 1.0, 0.95),
    'blue': (215, 1.0, 0.95),
    'green': (135, 0.95, 0.85),
    'yellow': (48, 1.0, 1.08),
    'purple': (278, 0.9, 0.9),
    'black': (25, 0.0, 0.22),       # orange -> near-black plastics
}

def rgb_to_hsv(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1); d = mx - mn
    h = np.zeros_like(mx)
    m = d > 1e-6
    rr = m & (mx == r); gg = m & (mx == g) & ~rr; bb = m & ~rr & ~gg
    h[rr] = ((g - b)[rr] / d[rr]) % 6
    h[gg] = (b - r)[gg] / d[gg] + 2
    h[bb] = (r - g)[bb] / d[bb] + 4
    return np.stack([h * 60, np.where(mx > 0, d / np.maximum(mx, 1e-6), 0), mx], -1)

def hsv_to_rgb(h, s, v):
    c = v * s; hp = (h % 360) / 60; x = c * (1 - np.abs(hp % 2 - 1)); z = np.zeros_like(c)
    i = np.floor(hp).astype(int) % 6
    lut = [(c, x, z), (x, c, z), (z, c, x), (z, x, c), (x, z, c), (c, z, x)]
    out = np.zeros(h.shape + (3,))
    for k, (r, g, b) in enumerate(lut):
        sel = i == k
        out[sel] = np.stack([r[sel], g[sel], b[sel]], -1)
    return out + (v - c)[..., None]

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
img = Image.open(src).convert('RGBA'); a = np.asarray(img).astype(np.float64) / 255
hsv = rgb_to_hsv(a[..., :3]); H, S, V = hsv[..., 0], hsv[..., 1], hsv[..., 2]
# orange band: hue 8..45 deg, saturated, not too dark; feathered so edges blend
dh = np.minimum(np.abs(H - 26), 360 - np.abs(H - 26))
w = np.clip((22 - dh) / 6, 0, 1) * np.clip((S - 0.30) / 0.15, 0, 1) * np.clip((V - 0.18) / 0.1, 0, 1)
print('orange coverage %.1f%%' % (100 * (w > 0.5).mean()))
for name, spec in VARIANTS.items():
    if spec is None:
        res = a[..., :3]
    else:
        hue, ss, vs = spec
        new = hsv_to_rgb(np.full_like(H, hue), np.clip(S * ss, 0, 1), np.clip(V * vs, 0, 1))
        res = a[..., :3] * (1 - w[..., None]) + new * w[..., None]
    o = np.concatenate([res, a[..., 3:]], -1)
    Image.fromarray((np.clip(o, 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(out, f'bike_450_colour_{name}.png'))
