"""Renders docs/banner.png (1280x640, also used as the GitHub social preview).

Run from the repo root on Windows: python tools/make_banner.py
"""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import numpy as np

W, H, K = 1280, 640, 2  # draw at 2x, downsample for anti-aliasing
w, h = W * K, H * K
FONTS = 'C:/Windows/Fonts/'


def font(name, size):
    return ImageFont.truetype(FONTS + name, size * K)


def S(*v):
    return [int(x * K) for x in v]


def layer():
    return Image.new('RGBA', (w, h), (0, 0, 0, 0))


# Aurora background, matching the app.
yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
bg = np.zeros((h, w, 3), np.float32) + np.array([16, 16, 30], np.float32)
for cx, cy, r, col in [(0.12, 0.2, 0.55, (99, 91, 247)), (0.88, 0.12, 0.5, (34, 200, 238)),
                       (0.72, 0.98, 0.55, (168, 85, 247)), (0.02, 0.98, 0.4, (56, 120, 255))]:
    d = np.sqrt((xx - cx * w) ** 2 + (yy - cy * h) ** 2) / (r * w)
    a = np.clip(1 - d, 0, 1) ** 2 * 0.75
    bg = bg * (1 - a[..., None]) + np.array(col, np.float32) * a[..., None]
img = Image.fromarray(bg.clip(0, 255).astype(np.uint8)).convert('RGBA')


def draw(fn):
    global img
    l = layer()
    fn(ImageDraw.Draw(l))
    img = Image.alpha_composite(img, l)


def glass(box, r):
    """Frosted panel: shadow, blurred backdrop, white tint, bright rim."""
    global img
    x0, y0, x1, y1 = S(*box)
    sh = layer()
    ImageDraw.Draw(sh).rounded_rectangle([x0, y0 + 16 * K, x1, y1 + 16 * K], radius=r * K, fill=(0, 0, 0, 110))
    img = Image.alpha_composite(img, sh.filter(ImageFilter.GaussianBlur(24 * K)))
    region = img.crop((x0, y0, x1, y1)).filter(ImageFilter.GaussianBlur(18 * K))
    region = Image.alpha_composite(region, Image.new('RGBA', region.size, (255, 255, 255, 46)))
    m = Image.new('L', region.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, region.size[0] - 1, region.size[1] - 1], radius=r * K, fill=255)
    img.paste(region, (x0, y0), m)
    draw(lambda d: d.rounded_rectangle([x0, y0, x1, y1], radius=r * K, outline=(255, 255, 255, 130), width=2 * K))


glass((790, 120, 1210, 390), 24)


def laptop(d):
    d.rounded_rectangle(S(806, 136, 1194, 374), radius=12 * K, fill=(28, 30, 56, 255))
    for (x, y, ww, hh, c) in [(826, 156, 160, 100, (99, 91, 247, 230)), (1000, 156, 174, 56, (34, 200, 238, 230)),
                              (1000, 226, 174, 128, (245, 246, 255, 230)), (826, 270, 160, 84, (168, 85, 247, 230))]:
        d.rounded_rectangle(S(x, y, x + ww, y + hh), radius=8 * K, fill=c)
    d.rounded_rectangle(S(750, 400, 1250, 420), radius=10 * K, fill=(235, 236, 255, 235))


draw(laptop)
glass((660, 230, 850, 580), 40)


def phone(d):
    d.rounded_rectangle(S(674, 244, 836, 566), radius=28 * K, fill=(91, 91, 247, 255))
    d.rounded_rectangle(S(692, 330, 818, 418), radius=10 * K, fill=(255, 255, 255, 215))
    d.rounded_rectangle(S(722, 432, 788, 442), radius=5 * K, fill=(255, 255, 255, 170))
    d.ellipse(S(749, 255, 761, 267), fill=(10, 10, 16, 255))
    d.line(S(870, 470, 960, 470), fill=(255, 255, 255, 235), width=5 * K)
    d.polygon([tuple(S(960, 460)), tuple(S(978, 470)), tuple(S(960, 480))], fill=(255, 255, 255, 235))
    d.line(S(978, 505, 888, 505), fill=(255, 255, 255, 170), width=5 * K)
    d.polygon([tuple(S(888, 495)), tuple(S(870, 505)), tuple(S(888, 515))], fill=(255, 255, 255, 170))


draw(phone)
logo = Image.open('assets/logo.png').convert('RGBA').resize((104 * K, 104 * K), Image.LANCZOS)
img.alpha_composite(logo, (80 * K, 140 * K))


def text(d):
    d.text(S(78, 262), 'PixMirror', font=font('segoeuib.ttf', 84), fill=(255, 255, 255, 255))
    d.text(S(82, 372), 'Your phone and PC,', font=font('segoeui.ttf', 30), fill=(228, 229, 255, 255))
    d.text(S(82, 410), 'one seamless screen.', font=font('segoeui.ttf', 30), fill=(228, 229, 255, 255))
    x = 82
    for label in ['Android + Windows', 'Liquid Glass + M3', 'Open source']:
        f = font('seguisb.ttf', 18)
        tw = d.textlength(label, font=f) / K
        d.rounded_rectangle(S(x, 474, x + tw + 30, 512), radius=19 * K, fill=(255, 255, 255, 38),
                            outline=(255, 255, 255, 120), width=K)
        d.text(S(x + 15, 481), label, font=f, fill=(255, 255, 255, 255))
        x += tw + 42


draw(text)
img.resize((W, H), Image.LANCZOS).convert('RGB').save('docs/banner.png', optimize=True)
print('wrote docs/banner.png')
