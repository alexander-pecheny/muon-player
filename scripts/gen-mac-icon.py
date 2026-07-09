#!/usr/bin/env python3
"""Add macOS icon slices to the shared AppIcon.appiconset, from the same 1024 art.

macOS still wants the classic ten-slice set (16/32/128/256/512 at 1x and 2x); the
iOS 'universal single size' entry is left untouched alongside them.
"""
import json
import subprocess
from pathlib import Path

SET = Path(__file__).resolve().parent.parent / "MuonPlayer/Assets.xcassets/AppIcon.appiconset"
SRC = SET / "AppIcon-1024.png"

# (point size, scale) -> pixel size
SLICES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
          (256, 1), (256, 2), (512, 1), (512, 2)]


def main():
    images = json.loads((SET / "Contents.json").read_text())["images"]
    images = [i for i in images if i.get("idiom") != "mac"]  # rebuild mac slices

    made = {}
    for size, scale in SLICES:
        px = size * scale
        name = f"AppIcon-mac-{px}.png"
        if px not in made:
            subprocess.run(["sips", "-z", str(px), str(px), str(SRC), "--out", str(SET / name)],
                           check=True, capture_output=True)
            made[px] = name
        images.append({
            "filename": made[px],
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{size}x{size}",
        })

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (SET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"wrote {len(made)} pngs and {len(images)} image entries")
    for p in sorted(SET.iterdir()):
        print("  ", p.name)


if __name__ == "__main__":
    main()
