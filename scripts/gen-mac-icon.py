#!/usr/bin/env python3
"""Add macOS icon slices to the shared AppIcon.appiconset, from the same 1024 art.

macOS wants the classic ten-slice set (16/32/128/256/512 at 1x and 2x). Each
slice needs its OWN file: two entries pointing at one filename (16x16@2x and
32x32@1x are both 32px) make the asset compiler collapse them, and the emitted
AppIcon.icns silently loses sizes — including the 512/1024 that the Dock and
Finder want, which leaves the app showing the generic application icon.
"""
import json
import subprocess
from pathlib import Path

SET = Path(__file__).resolve().parent.parent / "MuonPlayer/Assets.xcassets/AppIcon.appiconset"
SRC = SET / "AppIcon-1024.png"

SIZES = [16, 32, 128, 256, 512]


def main():
    for old in SET.glob("AppIcon-mac-*.png"):
        old.unlink()

    images = [i for i in json.loads((SET / "Contents.json").read_text())["images"]
              if i.get("idiom") != "mac"]

    for size in SIZES:
        for scale in (1, 2):
            px = size * scale
            name = f"AppIcon-mac-{size}x{size}@{scale}x.png"
            subprocess.run(["sips", "-z", str(px), str(px), str(SRC), "--out", str(SET / name)],
                           check=True, capture_output=True)
            images.append({
                "filename": name,
                "idiom": "mac",
                "scale": f"{scale}x",
                "size": f"{size}x{size}",
            })

    (SET / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"wrote {len(SIZES) * 2} mac slices")


if __name__ == "__main__":
    main()
