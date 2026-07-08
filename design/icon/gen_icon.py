#!/usr/bin/env python3
"""Muon app icon: a flat schematic speaker driver flanked by radiating waves that
also spell the word "muon" — the 5 left arcs join into 'm' (3 strokes, top
bridges) + 'u' (2 strokes, bottom bridge), the driver is the 'o', and the 2 right
arcs join into 'n' (top bridge). Tint-on-black.

Run it to (re)generate everything in one shot:

    python gen_icon.py                 # default tint
    python gen_icon.py --tint #ffccdd  # any cone/wave colour
    python gen_icon.py --bow 30        # wider wave curves

It writes icon.svg + icon.png here and installs icon.png as the app icon.
Needs `rsvg-convert` (brew install librsvg) on PATH and Pillow importable.
"""
import argparse
import math
import subprocess
from pathlib import Path

from PIL import Image

SIZE = 1024

# --- waves / letter strokes -------------------------------------------------
WAVE_H = 510       # vertical height of every arc
BOW = 42           # horizontal bulge of each arc; smaller = narrower curve
STEP = 54          # spacing between successive strokes
STROKE = 13        # line width of the wave curves
GAP = 6            # clearance between driver rim and the innermost stroke
SLANT = 0.6        # joiner lean: 1 matches the arc tangent (smooth), 0 = upright
BUMP_FACTOR = 0.72 # hump height as a fraction of STEP
ART_SCALE = 1.1    # size of the whole mark relative to the canvas

# --- driver (flat front-on loudspeaker), sized relative to the wave height ---
DRIVER_FRAC = 0.78
FRAME_COLOR = "#212327"
CAP_COLOR = "#17181b"

DEFAULT_TINT = "#00aafd"
BG = "#000000"
# ----------------------------------------------------------------------------

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ASSET = REPO / "MuonPlayer/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def build_svg(tint, bow, stroke, slant):
    """Return the icon as an SVG string. `bow` is the only curvature knob; the
    arc radius and span are derived so every arc keeps height WAVE_H."""
    cy = SIZE / 2
    half_chord = WAVE_H / 2
    R = (half_chord ** 2 + bow ** 2) / (2 * bow)
    half = math.asin(half_chord / R)
    span = math.degrees(half)
    sinh = R * math.sin(half)
    frame_r = DRIVER_FRAC * WAVE_H / 2
    offset = frame_r + GAP + bow

    bump = STEP * BUMP_FACTOR   # hump height; handles keep the peak round

    def ends(apex_x, bulge):
        x = apex_x + bow if bulge == "left" else apex_x - bow
        return (x, cy - sinh), (x, cy + sinh)   # top, bottom

    def arc(apex_x, bulge, frm, to):
        top, bot = ends(apex_x, bulge)
        x, y = top if to == "top" else bot
        sf = (1 if frm == "bottom" else 0) if bulge == "left" else (1 if frm == "top" else 0)
        return f"A {R:.2f} {R:.2f} 0 0 {sf} {x:.2f} {y:.2f}"

    def hump(pa, pb, where, bulge):
        # Handles aim along the arc's own tangent at the joint, so the arch leans
        # with the legs (G1-smooth) instead of standing upright.
        ox = math.sin(half) * slant * (1 if bulge == "left" else -1)
        oy = -math.cos(half) if where == "top" else math.cos(half)
        c1 = (pa[0] + bump * ox, pa[1] + bump * oy)
        c2 = (pb[0] + bump * ox, pb[1] + bump * oy)
        return (f"C {c1[0]:.2f} {c1[1]:.2f} {c2[0]:.2f} {c2[1]:.2f} "
                f"{pb[0]:.2f} {pb[1]:.2f}")

    def letter(d):
        return (f'<path d="{d}" fill="none" stroke="{tint}" stroke-width="{stroke}" '
                f'stroke-linecap="round" stroke-linejoin="round"/>')

    def join(a, b, bulge, where):
        """One continuous path: up stroke a, over/under the hump, down stroke b —
        so the round linejoin smooths every arc↔hump corner."""
        ta, ba = ends(a, bulge)
        tb, bb = ends(b, bulge)
        if where == "top":
            start, up, hp_a, hp_b, down = ba, ("bottom", "top"), ta, tb, ("top", "bottom")
        else:
            start, up, hp_a, hp_b, down = ta, ("top", "bottom"), ba, bb, ("bottom", "top")
        return letter(f"M {start[0]:.2f} {start[1]:.2f} {arc(a, bulge, *up)} "
                      f"{hump(hp_a, hp_b, where, bulge)} {arc(b, bulge, *down)}")

    def driver(dx, r):
        """Flat schematic driver: dark frame ring, solid tint cone, dark cap."""
        s = r / 510.0
        tx, ty = dx - s * 512, cy - s * 512
        return (f'<g transform="translate({tx:.2f} {ty:.2f}) scale({s:.4f})">'
                f'<circle cx="512" cy="512" r="510" fill="{FRAME_COLOR}"/>'
                f'<circle cx="512" cy="512" r="432" fill="{tint}"/>'
                f'<circle cx="512" cy="512" r="150" fill="{CAP_COLOR}"/></g>')

    # Stroke apexes (i=0 nearest the driver, growing outward). Left group is 4
    # strokes: 'm' and 'u' share their adjacent leg L[1] (a mu ligature).
    left = [-(offset + i * STEP) for i in range(4)]
    right = [offset + j * STEP for j in range(2)]
    dx = SIZE / 2 - ((min(left) - stroke / 2) + (max(right) + stroke / 2)) / 2
    L = [a + dx for a in left]
    Rt = [a + dx for a in right]

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
             f'viewBox="0 0 {SIZE} {SIZE}">',
             f'<rect width="{SIZE}" height="{SIZE}" fill="{BG}"/>',
             f'<g transform="translate({cy} {cy}) scale({ART_SCALE}) translate({-cy} {-cy})">']
    parts.append(join(L[3], L[2], "left", "top"))      # 'm' humps
    parts.append(join(L[2], L[1], "left", "top"))
    parts.append(join(L[1], L[0], "left", "bottom"))   # 'u' (shares L[1] with 'm')
    parts.append(join(Rt[0], Rt[1], "right", "top"))   # 'n'
    parts.append(driver(dx, frame_r))                  # 'o'
    parts.append('</g></svg>')
    return "\n".join(parts)


def main():
    ap = argparse.ArgumentParser(description="Generate and install the Muon app icon.")
    ap.add_argument("--tint", default=DEFAULT_TINT, help="cone + wave colour (hex)")
    ap.add_argument("--bow", type=float, default=BOW,
                    help="wave curvature: smaller = narrower")
    ap.add_argument("--stroke", type=float, default=STROKE, help="wave line width")
    ap.add_argument("--slant", type=float, default=SLANT,
                    help="joiner lean: 1 = smooth, 0 = upright")
    args = ap.parse_args()

    svg_path, png_path = HERE / "icon.svg", HERE / "icon.png"
    svg_path.write_text(build_svg(args.tint, args.bow, args.stroke, args.slant))

    raw = HERE / "icon.raw.png"
    subprocess.run(["rsvg-convert", "-w", str(SIZE), "-h", str(SIZE),
                    str(svg_path), "-o", str(raw)], check=True)
    Image.open(raw).convert("RGB").save(png_path)  # iOS needs an opaque icon
    raw.unlink()
    ASSET.write_bytes(png_path.read_bytes())

    print(f"tint={args.tint} bow={args.bow:g} stroke={args.stroke:g} slant={args.slant:g}")
    print(f"wrote {svg_path.name}, {png_path.name} -> {ASSET.relative_to(REPO)}")


if __name__ == "__main__":
    main()
