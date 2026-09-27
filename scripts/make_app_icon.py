#!/usr/bin/env python3
"""Renders the original PrettyShot app icon (Paper Bloom aperture + petal) into the asset catalog.

Usage: python3 scripts/make_app_icon.py   (requires Pillow)
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "PrettyShot", "Resources", "Assets.xcassets", "AppIcon.appiconset")
S = 1024
SS = 2  # supersampling


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def hexrgb(h):
    return ((h >> 16) & 255, (h >> 8) & 255, h & 255)


def paper_mist(size):
    """Paper Mist gradient (145deg: #F7F2EA → #E8DFD4 → #D9CFC4)."""
    stops = [(0.0, hexrgb(0xF7F2EA)), (0.48, hexrgb(0xE8DFD4)), (1.0, hexrgb(0xD9CFC4))]
    img = Image.new("RGB", (size, size))
    px = img.load()
    import math
    th = math.radians(145)
    dx, dy = math.sin(th), -math.cos(th)
    length = abs(size * dx) + abs(size * dy)
    for y in range(size):
        for x in range(size):
            t = ((x - size / 2) * dx + (y - size / 2) * dy) / length + 0.5
            t = min(max(t, 0), 1)
            for i in range(len(stops) - 1):
                if stops[i][0] <= t <= stops[i + 1][0]:
                    local = (t - stops[i][0]) / (stops[i + 1][0] - stops[i][0])
                    px[x, y] = lerp(stops[i][1], stops[i + 1][1], local)
                    break
    return img


def render():
    n = S * SS
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))

    # macOS icon grid: 824pt body inset 100pt, continuous-ish corner radius.
    inset, radius = 100 * SS, 185 * SS
    body = (inset, inset, n - inset, n - inset)

    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (body[0], body[1] + 18 * SS, body[2], body[3] + 18 * SS), radius, fill=(44, 42, 40, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(24 * SS))
    canvas.alpha_composite(shadow)

    grad = paper_mist(256).resize((n, n), Image.BICUBIC).convert("RGBA")
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle(body, radius, fill=255)
    canvas.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(canvas)
    rose = (232, 160, 168, 255)
    deep = (212, 137, 147, 255)
    c = n / 2
    # Soft bloom halo
    halo = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse((c - 300 * SS, c - 300 * SS, c + 300 * SS, c + 300 * SS), fill=(232, 160, 168, 70))
    halo = halo.filter(ImageFilter.GaussianBlur(60 * SS))
    canvas.alpha_composite(Image.composite(halo, Image.new("RGBA", (n, n), (0, 0, 0, 0)), mask))
    d = ImageDraw.Draw(canvas)

    # Aperture ring + core (from the 32-unit mark: ring r=7.5, core r=3)
    u = 26 * SS  # 1 mark unit
    r_ring, w_ring, r_core = 7.5 * u, 2.2 * u, 3 * u
    d.ellipse((c - r_ring, c - r_ring, c + r_ring, c + r_ring), outline=rose, width=int(w_ring))
    d.ellipse((c - r_core, c - r_core, c + r_core, c + r_core), fill=rose)

    # Petal: quadratic-ish arc at the upper right (mark coords 22.5,7.5 → 25.1,9.3 → 23.5,11.8)
    def m(x, y):
        return (c + (x - 16) * u, c + (y - 16) * u)

    def bez(p0, p1, p2, p3, steps=60):
        pts = []
        for i in range(steps + 1):
            t = i / steps
            a = (1 - t) ** 3
            b = 3 * (1 - t) ** 2 * t
            cc = 3 * (1 - t) * t ** 2
            dd = t ** 3
            pts.append((a * p0[0] + b * p1[0] + cc * p2[0] + dd * p3[0],
                        a * p0[1] + b * p1[1] + cc * p2[1] + dd * p3[1]))
        return pts

    petal = bez(m(22.5, 7.5), m(23.7, 7.3), m(24.9, 8.1), m(25.1, 9.3)) + \
        bez(m(25.1, 9.3), m(25.3, 10.5), m(24.5, 11.5), m(23.5, 11.8))
    d.line(petal, fill=deep, width=int(1.5 * u), joint="curve")
    for p in (petal[0], petal[-1]):
        rr = 0.75 * u
        d.ellipse((p[0] - rr, p[1] - rr, p[0] + rr, p[1] + rr), fill=deep)

    return canvas.resize((S, S), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    master = render()
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}", "filename": name})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    print("wrote", len(images), "icons to", OUT)


if __name__ == "__main__":
    main()
