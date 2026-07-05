#!/usr/bin/env python3
"""Muon app icon: a big schematic speaker driver flanked by radiating waves that
also spell the word "muon" — the 5 left arcs are joined into 'm' (3 strokes,
top bridges) + 'u' (2 strokes, bottom bridge), the driver is the 'o', and the 2
right arcs are joined into 'n' (top bridge). Black-on-white SVG."""
import math

SIZE = 1024

# --- waves / letter strokes -------------------------------------------------
R = 474            # radius of every wave arc (all identical)
HALF_SPAN = 30     # degrees each arc spans either side of its axis
STEP = 66          # spacing between successive strokes
STROKE = 30
GAP = 6            # clearance between driver rim and the innermost stroke

# --- driver (front-on loudspeaker), sized relative to the wave height --------
DRIVER_FRAC = 0.78
FRAME_SW, CONE_RATIO, CONE_SW, CAP_RATIO = 30, 0.72, 20, 0.46

BG, FG = "#ffffff", "#000000"
# ----------------------------------------------------------------------------

cy = SIZE / 2
half = math.radians(HALF_SPAN)
wave_h = 2 * R * math.sin(half)
depth = R * (1 - math.cos(half))
sinh = R * math.sin(half)
FRAME_R = DRIVER_FRAC * wave_h / 2
OFFSET = FRAME_R + GAP + depth

def stroke_path(d):
    return f'<path d="{d}" fill="none" stroke="{FG}" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"/>'

def wave(apex_x, bulge):
    if bulge == "left":
        cx, a1, a2 = apex_x + R, 180 - HALF_SPAN, 180 + HALF_SPAN
    else:
        cx, a1, a2 = apex_x - R, -HALF_SPAN, HALF_SPAN
    x1, y1 = cx + R * math.cos(math.radians(a1)), cy + R * math.sin(math.radians(a1))
    x2, y2 = cx + R * math.cos(math.radians(a2)), cy + R * math.sin(math.radians(a2))
    return stroke_path(f"M {x1:.2f} {y1:.2f} A {R:.2f} {R:.2f} 0 0 1 {x2:.2f} {y2:.2f}")

def chord_x(apex_x, bulge):
    return apex_x + depth if bulge == "left" else apex_x - depth

def bridge(apex_a, apex_b, bulge, where):
    """A curved connector joining two adjacent strokes at 'top' or 'bottom',
    turning the strokes into letter humps."""
    xa, xb = chord_x(apex_a, bulge), chord_x(apex_b, bulge)
    y = cy - sinh if where == "top" else cy + sinh
    bump = abs(xb - xa) * 0.95
    cyc = y - bump if where == "top" else y + bump
    mx = (xa + xb) / 2
    return stroke_path(f"M {xa:.2f} {y:.2f} Q {mx:.2f} {cyc:.2f} {xb:.2f} {y:.2f}")

def ring(cx, r, sw):
    return f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{r:.2f}" fill="none" stroke="{FG}" stroke-width="{sw}"/>'

# Stroke apexes (i=0 nearest the driver, growing outward). Left = m(3)+u(2).
left = [-(OFFSET + i * STEP) for i in range(5)]
right = [OFFSET + j * STEP for j in range(2)]

left_edge = min(left) - STROKE / 2
right_edge = max(right) + STROKE / 2
dx = SIZE / 2 - (left_edge + right_edge) / 2
L = [a + dx for a in left]
Rt = [a + dx for a in right]

parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">',
         f'<rect width="{SIZE}" height="{SIZE}" fill="{BG}"/>']

# strokes
for ax in L:
    parts.append(wave(ax, "left"))
for ax in Rt:
    parts.append(wave(ax, "right"))

# 'm' = the three outer left strokes (indices 4,3,2), joined at the top
parts.append(bridge(L[4], L[3], "left", "top"))
parts.append(bridge(L[3], L[2], "left", "top"))
# 'u' = the two inner left strokes (1,0), joined at the bottom
parts.append(bridge(L[1], L[0], "left", "bottom"))
# 'n' = the two right strokes, joined at the top
parts.append(bridge(Rt[0], Rt[1], "right", "top"))

# driver 'o'
parts.append(ring(dx, FRAME_R, FRAME_SW))
parts.append(ring(dx, FRAME_R * CONE_RATIO, CONE_SW))
parts.append(f'<circle cx="{dx:.2f}" cy="{cy:.2f}" r="{FRAME_R * CAP_RATIO:.2f}" fill="{FG}"/>')
parts.append('</svg>')

with open("icon.svg", "w") as f:
    f.write("\n".join(parts))
print(f"FRAME_R={FRAME_R:.0f} dx={dx:.1f} left={['%.0f'%a for a in left]} right={['%.0f'%a for a in right]}")
