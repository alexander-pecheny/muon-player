#!/usr/bin/env -S deno run --allow-read --allow-write --allow-run --allow-net
// Generate and install the Muon app icon, or serve the live tuner. Geometry
// lives in icon.js, shared with lab.html.
//
//   deno task icon                    # default look; writes icon.svg + icon.png
//   deno task icon --tint '#ffccdd'   # any knob from RANGES/COLORS, by name
//   deno task icon --cone 0           # parallel waves instead of a flare
//   deno task lab                     # serve lab.html (ES modules need http://)
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
      Deno.exit(2);
    }
    if (key === "transparent") { p.transparent = true; continue; }
    const value = argv[++i];
    p[key] = numeric.has(key) ? Number(value) : value;
    if (numeric.has(key) && Number.isNaN(p[key])) {
      console.error(`--${key} wants a number, got ${value}`);
      Deno.exit(2);
    }
  }
  return p;
}

async function run(cmd, args) {
  const { success, stderr } = await new Deno.Command(cmd, { args }).output();
  if (!success) {
    console.error(`${cmd} failed:\n${new TextDecoder().decode(stderr)}`);
    Deno.exit(1);
  }
}

async function serveLab() {
  const port = 8000;
  const types = { ".html": "text/html", ".js": "text/javascript", ".svg": "image/svg+xml" };
  Deno.serve({ port }, async (req) => {
    let path = new URL(req.url).pathname;
    if (path === "/") path = "/lab.html";
    try {
      const body = await Deno.readFile(HERE + path.slice(1));
      const ext = path.slice(path.lastIndexOf("."));
      return new Response(body, {
        headers: { "content-type": types[ext] ?? "application/octet-stream" },
      });
    } catch {
      return new Response("not found", { status: 404 });
    }
  });
  console.log(`icon lab: http://localhost:${port}/lab.html`);
  await new Promise(() => {});
}

if (Deno.args[0] === "--lab") {
  await serveLab();
} else {
  const p = parseArgs(Deno.args);
  const svg = `${HERE}icon.svg`, png = `${HERE}icon.png`, raw = `${HERE}icon.raw.png`;
  await Deno.writeTextFile(svg, buildSVG(p));
  await run("rsvg-convert", ["-w", `${SIZE}`, "-h", `${SIZE}`, svg, "-o", raw]);
  // iOS rejects an icon with an alpha channel, even a fully opaque one.
  await run("magick", [raw, "-background", p.bg, "-alpha", "remove", "-alpha", "off", png]);
  await Deno.remove(raw);
  await Deno.copyFile(png, ASSET);

  const shown = [...RANGES, ...COLORS].map(([k]) => `${k}=${p[k]}`).join(" ");
  console.log(shown);
  console.log("wrote icon.svg, icon.png -> MuonPlayer/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png");
}
