#!/usr/bin/env bun
// Generate and install the Muon app icon, or serve the live tuner. Geometry
// lives in icon.js, shared with lab.html.
//
//   bun run icon                      # default look; writes icon.svg + icon.png
//   bun run icon --tint '#ffccdd'     # any knob from RANGES/COLORS, by name
//   bun run icon --cone 0             # parallel waves instead of a flare
//   bun run lab                       # serve lab.html (ES modules need http://)
//
// Needs `rsvg-convert` (brew install librsvg) and `magick` (brew install
// imagemagick) on PATH.
import { buildSVG, COLORS, DEFAULTS, RANGES, SIZE } from "./icon.js";

const HERE = new URL(".", import.meta.url).pathname;
const ASSET = `${HERE}../../MuonPlayer/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`;

function parseArgs(argv) {
  const numeric = new Set(RANGES.map(([k]) => k));
  const known = new Set([...numeric, ...COLORS.map(([k]) => k), "transparent"]);
  const p = { ...DEFAULTS };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].replace(/^--/, "");
    if (!argv[i].startsWith("--") || !known.has(key)) {
      console.error(`unknown flag: ${argv[i]}\nknown: ${[...known].join(", ")}`);
      process.exit(2);
    }
    if (key === "transparent") { p.transparent = true; continue; }
    const value = argv[++i];
    p[key] = numeric.has(key) ? Number(value) : value;
    if (numeric.has(key) && Number.isNaN(p[key])) {
      console.error(`--${key} wants a number, got ${value}`);
      process.exit(2);
    }
  }
  return p;
}

async function run(cmd, args) {
  const { success, stderr } = Bun.spawnSync([cmd, ...args]);
  if (!success) {
    console.error(`${cmd} failed:\n${stderr}`);
    process.exit(1);
  }
}

function serveLab() {
  const port = 8000;
  Bun.serve({
    port,
    async fetch(req) {
      let path = new URL(req.url).pathname;
      if (path === "/") path = "/lab.html";
      const file = Bun.file(HERE + path.slice(1));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  console.log(`icon lab: http://localhost:${port}/lab.html`);
}

const argv = Bun.argv.slice(2);
if (argv[0] === "--lab") {
  serveLab();
} else {
  const p = parseArgs(argv);
  const svg = `${HERE}icon.svg`, png = `${HERE}icon.png`, raw = `${HERE}icon.raw.png`;
  await Bun.write(svg, buildSVG(p));
  await run("rsvg-convert", ["-w", `${SIZE}`, "-h", `${SIZE}`, svg, "-o", raw]);
  // iOS rejects an icon with an alpha channel, even a fully opaque one.
  await run("magick", [raw, "-background", p.bg, "-alpha", "remove", "-alpha", "off", png]);
  await Bun.file(raw).delete();
  await Bun.write(ASSET, Bun.file(png));

  const shown = [...RANGES, ...COLORS].map(([k]) => `${k}=${p[k]}`).join(" ");
  console.log(shown);
  console.log("wrote icon.svg, icon.png -> MuonPlayer/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png");
}
