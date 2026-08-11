"""Renders the LOAD app icon and splash lockup as PNGs, from the same
barbell-glyph geometry the in-app splash animation settles into
(lib/screens/splash_screen.dart's _BarbellPainter, at bend=1/plateT=1/
drawProgress=1). Supersampled 4x and downsampled for anti-aliasing, since
Pillow's own drawing isn't anti-aliased.
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONTS = ROOT / "assets" / "fonts"
OUT = ROOT / "assets" / "logo"
OUT.mkdir(parents=True, exist_ok=True)

ACCENT = (185, 70, 66, 255)  # #B94642
DARK = (45, 33, 30, 255)  # #2D211E textPrimary
CREAM = (252, 243, 238, 255)  # #FCF3EE background
SECONDARY = (124, 110, 105, 255)  # #7C6E69 textSecondary
WHITE = (255, 255, 255, 255)

SS = 4  # supersample factor


def quad_bezier_points(p0, p1, p2, n=80):
    pts = []
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t**2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t**2 * p2[1]
        pts.append((x, y))
    return pts


def paste_rotated_rrect(canvas, origin, w, h, radius, angle_deg, pivot, color):
    """Draws a rounded rect at `origin` (top-left, in canvas coords), rotated
    by angle_deg around `pivot` (in canvas coords), and composites it onto
    canvas."""
    pad = int(max(w, h) * 1.6)
    tmp = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    d.rounded_rectangle([pad, pad, pad + w, pad + h], radius=radius, fill=color)
    # Rotate around the shape's own center, then place so that the shape's
    # center ends up at (origin + w/2, origin + h/2), then further rotate the
    # whole composited offset around `pivot` to match the SVG's group rotate.
    shape_cx = origin[0] + w / 2
    shape_cy = origin[1] + h / 2
    rad = math.radians(angle_deg)
    dx, dy = shape_cx - pivot[0], shape_cy - pivot[1]
    rx = dx * math.cos(rad) - dy * math.sin(rad)
    ry = dx * math.sin(rad) + dy * math.cos(rad)
    new_cx, new_cy = pivot[0] + rx, pivot[1] + ry

    rotated = tmp.rotate(-angle_deg, resample=Image.BICUBIC, expand=False)
    paste_x = int(new_cx - rotated.width / 2)
    paste_y = int(new_cy - rotated.height / 2)
    canvas.alpha_composite(rotated, (paste_x, paste_y))


def ribbon_polygon(pts, width):
    """A filled polygon following `pts` at constant `width`, avoiding the
    seam artifacts ImageDraw.line's segment-by-segment stroking leaves on a
    curve — each point's normal is offset by half-width on both sides, and
    the two offset rails are joined into one polygon."""
    half = width / 2
    n = len(pts)
    left, right = [], []
    for i in range(n):
        px, py = pts[i]
        if i == 0:
            dx, dy = pts[1][0] - px, pts[1][1] - py
        elif i == n - 1:
            dx, dy = px - pts[i - 1][0], py - pts[i - 1][1]
        else:
            dx, dy = pts[i + 1][0] - pts[i - 1][0], pts[i + 1][1] - pts[i - 1][1]
        length = math.hypot(dx, dy) or 1
        nx, ny = -dy / length, dx / length
        left.append((px + nx * half, py + ny * half))
        right.append((px - nx * half, py - ny * half))
    return left + right[::-1]


def draw_barbell(canvas, cx, cy, scale, bar_color, plate_color):
    """Barbell glyph centered at (cx, cy), matching the settled Flutter
    splash geometry (viewBox 220x100, bar y=50, control y=37, plates at
    x=20-52 / x=168-200, +-4.5deg tilt)."""
    p0 = (cx + (45 - 110) * scale, cy + (50 - 50) * scale)
    p1 = (cx + (110 - 110) * scale, cy + (37 - 50) * scale)
    p2 = (cx + (175 - 110) * scale, cy + (50 - 50) * scale)
    pts = quad_bezier_points(p0, p1, p2, n=160)
    d = ImageDraw.Draw(canvas)
    width = 13 * scale
    d.polygon(ribbon_polygon(pts, width), fill=bar_color)
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=bar_color)

    pivot_l = (cx + (45 - 110) * scale, cy + (50 - 50) * scale)
    pivot_r = (cx + (175 - 110) * scale, cy + (50 - 50) * scale)

    def plate(x, y, w, h, rx, pivot, angle):
        ox = cx + (x - 110) * scale
        oy = cy + (y - 50) * scale
        paste_rotated_rrect(
            canvas,
            (ox, oy),
            int(w * scale),
            int(h * scale),
            int(rx * scale),
            angle,
            pivot,
            plate_color,
        )

    plate(38, 20, 14, 60, 7, pivot_l, -4.5)
    plate(20, 31, 12, 38, 6, pivot_l, -4.5)
    plate(168, 20, 14, 60, 7, pivot_r, 4.5)
    plate(188, 31, 12, 38, 6, pivot_r, 4.5)


def render_icon():
    size = 1024 * SS
    canvas = Image.new("RGBA", (size, size), ACCENT)
    draw_barbell(canvas, size / 2, size / 2, scale=size / 220 * 0.62, bar_color=WHITE, plate_color=WHITE)
    canvas = canvas.resize((1024, 1024), Image.LANCZOS)
    canvas.save(OUT / "app_icon.png")

    # Foreground-only layer for Android adaptive icons: transparent bg, glyph
    # kept inside the safe zone (roughly the middle 66% of the canvas).
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_barbell(fg, size / 2, size / 2, scale=size / 220 * 0.44, bar_color=WHITE, plate_color=WHITE)
    fg = fg.resize((1024, 1024), Image.LANCZOS)
    fg.save(OUT / "app_icon_foreground.png")


def render_splash():
    w, h = 1200 * SS, 900 * SS
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    barbell_cy = int(h * 0.36)
    draw_barbell(canvas, w / 2, barbell_cy, scale=w / 220 * 0.62, bar_color=ACCENT, plate_color=DARK)

    word_font = ImageFont.truetype(str(FONTS / "Nunito-ExtraBold.ttf"), int(150 * SS))
    tag_font = ImageFont.truetype(str(FONTS / "Nunito-Bold.ttf"), int(38 * SS))
    d = ImageDraw.Draw(canvas)

    word = "LOAD"
    bbox = d.textbbox((0, 0), word, font=word_font)
    word_w = bbox[2] - bbox[0]
    word_h = bbox[3] - bbox[1]
    word_y = int(h * 0.58)
    dot_r = int(19 * SS)
    total_w = word_w + dot_r * 2 + int(14 * SS)
    word_x = (w - total_w) / 2 - bbox[0]
    d.text((word_x, word_y - bbox[1]), word, font=word_font, fill=DARK)

    dot_cx = word_x + bbox[2] + int(14 * SS) + dot_r
    dot_cy = word_y + word_h - dot_r * 0.6
    d.ellipse(
        [dot_cx - dot_r, dot_cy - dot_r, dot_cx + dot_r, dot_cy + dot_r],
        fill=ACCENT,
    )

    tag1 = "Personal training, computed"
    tag2 = "from your actual history."
    tag_y = word_y + word_h + int(46 * SS)
    for i, line in enumerate((tag1, tag2)):
        tb = d.textbbox((0, 0), line, font=tag_font)
        tw = tb[2] - tb[0]
        d.text(((w - tw) / 2, tag_y + i * int(54 * SS)), line, font=tag_font, fill=SECONDARY)

    canvas = canvas.resize((1200, 900), Image.LANCZOS)
    canvas.save(OUT / "splash_lockup.png")

    # Cream-background flattened variant, for native-splash configs that
    # don't composite transparency reliably.
    flat = Image.new("RGBA", canvas.size, CREAM)
    flat.alpha_composite(canvas)
    flat.convert("RGB").save(OUT / "splash_lockup_flat.png")


if __name__ == "__main__":
    render_icon()
    render_splash()
    print("done")
