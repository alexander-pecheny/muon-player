// Muon app icon geometry — the single source of truth, shared by lab.html (live
// tuner) and gen-icon.js (writes icon.svg/png and installs the app icon).
//
// The mark: a flat schematic speaker driver flanked by radiating waves that also
// spell "muon" — the 4 left arcs join into 'm' (3 strokes, top bridges) + 'u'
// (2 strokes, bottom bridge, sharing a leg with the 'm'), the driver is the 'o',
// and the 2 right arcs join into 'n' (top bridge).

export const SIZE = 1024;

// [key, label, min, max, step, default, decimals] — drives both the lab sliders
// and the CLI flags, so a new knob only has to be added here.
export const RANGES = [
  ["stroke",     "Stroke width",    4,   60, 1,    20,   0],
  ["bow",        "Bulge",           8,  140, 1,    42,   0],
  ["waveH",      "Arc height",    200,  820, 5,   200,   0],
  ["step",       "Stroke spacing",  30, 150, 1,    66,   0],
  ["cone",       "Wave flare",      0,  1.5, 0.01, 1.26, 2],
  ["bump",       "Hump height",   0.2,  1.5, 0.01, 0.72, 2],
  ["slant",      "Joiner slant", -0.5,  2.5, 0.05, 1.35, 2],
  ["driverFrac", "Driver size",   0.3,  1.3, 0.01, 0.78, 2],
  ["gap",        "Driver gap",    -40,  140, 1,     6,   0],
  ["artScale",   "Overall size",  0.3,  1.6, 0.01, 1.25, 2],
];

export const COLORS = [
  ["tint",  "Tint",        "#e0e34e"],
  ["bg",    "Background",  "#000000"],
  ["frame", "Driver ring", "#000000"],
  ["cap",   "Dust cap",    "#000000"],
];

export const DEFAULTS = Object.fromEntries([
  ...RANGES.map(([k, , , , , def]) => [k, def]),
  ...COLORS.map(([k, , def]) => [k, def]),
  ["transparent", false],
]);

/** Arc radius and half-span of the innermost stroke, for the lab's readout. */
export function derived(p) {
  const hc = p.waveH / 2;
  const r = (hc * hc + p.bow * p.bow) / (2 * p.bow);
  return { radius: r, span: Math.asin(Math.min(1, hc / r)) * 180 / Math.PI };
}

/**
 * `bow` is the curvature knob; each arc's radius and span are derived from it
 * and from the arc's height. `cone` grows every arc in proportion to its
 * distance from the driver centre, so the waves flare like `<)` — at cone=1
 * they lie on rays through that centre, and at cone=0 they stay parallel.
 */
export function buildSVG(params, { fixedSize = true } = {}) {
  const p = { ...DEFAULTS, ...params };
  const cy = SIZE / 2;
  const f = (n) => n.toFixed(2);
  const frameR = p.driverFrac * p.waveH / 2;
  const offset = frameR + p.gap + p.bow;
  const bumpPx = p.step * p.bump;

  /** Geometry of one arc, uniformly scaled by its distance from centre. */
  const strokeAt = (apexX, bulge) => {
    const k = 1 + p.cone * (Math.abs(apexX) - offset) / offset;
    const bow = p.bow * k, hc = p.waveH * k / 2;
    const r = (hc * hc + bow * bow) / (2 * bow);
    const half = Math.asin(Math.min(1, hc / r));
    return { x: apexX, bulge, bow, r, half, sinh: r * Math.sin(half) };
  };

  const end = (s, where) => {
    const x = s.bulge === "left" ? s.x + s.bow : s.x - s.bow;
    return [x, where === "top" ? cy - s.sinh : cy + s.sinh];
  };

  const arc = (s, frm, to) => {
    const [x, y] = end(s, to);
    const sf = s.bulge === "left" ? (frm === "bottom" ? 1 : 0) : (frm === "top" ? 1 : 0);
    return `A ${f(s.r)} ${f(s.r)} 0 0 ${sf} ${f(x)} ${f(y)}`;
  };

  // Handles aim along the arc's own tangent at the joint, so the arch leans with
  // the legs (G1-smooth) instead of standing upright.
  const handle = (s, where) => {
    const [px, py] = end(s, where);
    const ox = Math.sin(s.half) * p.slant * (s.bulge === "left" ? 1 : -1);
    const oy = where === "top" ? -Math.cos(s.half) : Math.cos(s.half);
    return [px + bumpPx * ox, py + bumpPx * oy];
  };

  const hump = (a, b, where) => {
    const c1 = handle(a, where), c2 = handle(b, where), pb = end(b, where);
    return `C ${f(c1[0])} ${f(c1[1])} ${f(c2[0])} ${f(c2[1])} ${f(pb[0])} ${f(pb[1])}`;
  };

  const letter = (d) =>
    `<path d="${d}" fill="none" stroke="${p.tint}" stroke-width="${p.stroke}" ` +
    `stroke-linecap="round" stroke-linejoin="round"/>`;

  // One continuous path: up stroke a, over/under the hump, down stroke b — so the
  // round linejoin smooths every arc↔hump corner.
  const join = (a, b, where) => {
    const up = where === "top" ? ["bottom", "top"] : ["top", "bottom"];
    const down = where === "top" ? ["top", "bottom"] : ["bottom", "top"];
    const start = end(a, up[0]);
    return letter(`M ${f(start[0])} ${f(start[1])} ${arc(a, ...up)} ` +
                  `${hump(a, b, where)} ${arc(b, ...down)}`);
  };

  const driver = (dx, r) => {
    const s = r / 510, tx = dx - s * 512, ty = cy - s * 512;
    return `<g transform="translate(${f(tx)} ${f(ty)}) scale(${s.toFixed(4)})">` +
      `<circle cx="512" cy="512" r="510" fill="${p.frame}"/>` +
      `<circle cx="512" cy="512" r="432" fill="${p.tint}"/>` +
      `<circle cx="512" cy="512" r="150" fill="${p.cap}"/></g>`;
  };

  const left = [0, 1, 2, 3].map((i) => -(offset + i * p.step));
  const right = [0, 1].map((j) => offset + j * p.step);
  const dx = SIZE / 2 -
    ((Math.min(...left) - p.stroke / 2) + (Math.max(...right) + p.stroke / 2)) / 2;
  const L = left.map((a) => strokeAt(a, "left"));
  const Rt = right.map((a) => strokeAt(a, "right"));
  for (const s of [...L, ...Rt]) s.x += dx;

  const art = join(L[3], L[2], "top") +      // 'm' humps
    join(L[2], L[1], "top") +
    join(L[1], L[0], "bottom") +             // 'u' (shares L[1] with 'm')
    join(Rt[0], Rt[1], "top") +              // 'n'
    driver(dx, frameR);                      // 'o'

  const rect = p.transparent ? "" : `<rect width="${SIZE}" height="${SIZE}" fill="${p.bg}"/>`;
  const size = fixedSize ? `width="${SIZE}" height="${SIZE}"` : `width="100%" height="100%"`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" ${size}>${rect}` +
    `<g transform="translate(${cy} ${cy}) scale(${p.artScale}) translate(${-cy} ${-cy})">` +
    `${art}</g></svg>`;
}
