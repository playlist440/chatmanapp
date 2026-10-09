"""Chatman's app icon.

Drawn at 4x and scaled down, which is what keeps the curves clean: PIL has no
anti-aliasing of its own, so the supersampling is the anti-aliasing.
"""
from PIL import Image, ImageDraw, ImageFilter
import math, sys

S = 1024
F = 4                      # supersampling factor
W = S * F

# --- palette --------------------------------------------------------------
# A dark ground rather than the white one it had: an icon has to hold its own
# shape on a light home screen, and white against white is a sticker.
SKY_TOP    = (34, 46, 80)
SKY_BOTTOM = (14, 20, 38)

BLUE   = (74, 144, 255)    # the iMessage side of the joke
GREEN  = (52, 199, 89)     # and the other side
YELLOW = (255, 200, 45)    # Chatman himself
YELLOW_SHADE = (232, 176, 28)
INK    = (46, 32, 18)

def px(v):
    return v * F

def shade(colour, factor):
    return tuple(min(255, round(c * factor)) for c in colour)

def bezier(points, steps=140):
    """Samples a Bézier of any order."""
    out = []
    n = len(points) - 1
    for i in range(steps + 1):
        t = i / steps
        x = y = 0.0
        for k, (bx, by) in enumerate(points):
            c = math.comb(n, k) * (t ** k) * ((1 - t) ** (n - k))
            x += bx * c
            y += by * c
        out.append((x, y))
    return out

def background():
    """A vertical gradient, warmer at the top so it doesn't read as flat black."""
    image = Image.new("RGB", (1, S), SKY_TOP)
    draw = ImageDraw.Draw(image)
    for y in range(S):
        t = y / (S - 1)
        # Eased, so the light gathers near the top instead of sliding evenly.
        t = t ** 1.25
        draw.point(
            (0, y),
            tuple(round(a + (b - a) * t) for a, b in zip(SKY_TOP, SKY_BOTTOM)),
        )
    return image.resize((S, S), Image.BICUBIC).convert("RGBA")

def bubble(draw, cx, cy, r, colour, tail=None):
    """A round speech bubble, optionally with a tail.

    Round rather than rectangular: at icon size a circle keeps its shape where a
    rounded rectangle turns into a blob, and three of them read as a crowd.
    """
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=colour)

    if tail:
        # A tail grown from the body, so the join never shows a seam.
        angle, length, width = tail
        a = math.radians(angle)
        tip = (cx + math.cos(a) * (r + length), cy + math.sin(a) * (r + length))
        left = (cx + math.cos(a - width) * r * 0.98, cy + math.sin(a - width) * r * 0.98)
        right = (cx + math.cos(a + width) * r * 0.98, cy + math.sin(a + width) * r * 0.98)
        draw.polygon([left, tip, right], fill=colour)

def moustache(draw, cx, cy, half_width, height, colour):
    """A handlebar, with the ends running further down — the real Chatman's shape."""
    w, h = half_width, height

    top = bezier([
        (cx, cy + 0.30 * h),               # the notch under the nose
        (cx + 0.30 * w, cy - 0.22 * h),
        (cx + 0.66 * w, cy + 0.02 * h),
        (cx + w, cy + 0.66 * h),           # tip, pointing down and out
    ])
    back = bezier([
        (cx + w, cy + 0.66 * h),
        (cx + 0.78 * w, cy + 0.62 * h),
        (cx + 0.62 * w, cy + 0.98 * h),
        (cx + 0.30 * w, cy + 0.94 * h),
        (cx, cy + 0.62 * h),               # centre, hanging below the notch
    ])

    right = top + back
    left = [(2 * cx - x, y) for x, y in reversed(right)]
    draw.polygon(right + left, fill=colour)

def draw_icon(with_face=True):
    canvas = background().resize((W, W), Image.BICUBIC)

    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        [W * 0.10, W * 0.06, W * 0.90, W * 0.86],
        fill=(90, 120, 200, 58),
    )
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(W * 0.09)))
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    cx = W / 2
    # Sits above centre: the tail and the moustache carry weight downwards, so a
    # mark that measures centred looks like it has slipped.
    cy = W * 0.487

    front_r = px(228)
    back_r = px(190)

    # The two behind, dimmed a shade so the front one is plainly in front. Equal
    # saturation on all three flattens the stack into a pattern.
    bubble(draw, cx - px(190), cy - px(12), back_r, shade(BLUE, 0.86))
    bubble(draw, cx + px(190), cy - px(12), back_r, shade(GREEN, 0.86))

    # A soft shadow under the front bubble. Without it the three sit in the same
    # plane and the stack reads as a pattern rather than as one in front of two.
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        [cx - front_r * 1.04, cy - front_r * 0.92,
         cx + front_r * 1.04, cy + front_r * 1.16],
        fill=(6, 10, 22, 118),
    )
    layer.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(22))))

    # Chatman in front. A short tail, the way Messages draws it — a long one
    # turns into a spike at small sizes, a fat one into a drip.
    bubble(draw, cx, cy + px(14), front_r, YELLOW,
           tail=(112, px(68), 0.36))

    if with_face:
        # Higher in the bubble than it measures right: a face reads as centred
        # when the eyes sit above the middle, not on it.
        eye_r = px(27)
        eye_y = cy - px(44)
        for dx in (-px(86), px(86)):
            draw.ellipse(
                [cx + dx - eye_r, eye_y - eye_r, cx + dx + eye_r, eye_y + eye_r],
                fill=INK,
            )
        moustache(draw, cx, cy + px(48), px(152), px(120), INK)

    # Two antennae on springs, the detail everyone remembers him by.
    ball_r = px(33)
    ball_y = cy - front_r - px(42)
    for dx in (-px(88), px(88)):
        draw.line(
            [(cx + dx * 0.62, cy - front_r + px(46)), (cx + dx, ball_y)],
            fill=YELLOW_SHADE, width=int(px(19)),
        )
        draw.ellipse(
            [cx + dx - ball_r, ball_y - ball_r, cx + dx + ball_r, ball_y + ball_r],
            fill=YELLOW,
        )

    canvas.alpha_composite(layer)
    return canvas.resize((S, S), Image.LANCZOS).convert("RGB")

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/icoon/chatman.png"
    draw_icon().save(out)
    print("geschreven:", out)
