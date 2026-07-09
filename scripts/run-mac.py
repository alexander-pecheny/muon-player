#!/usr/bin/env python3
"""Build the macOS app and launch it.

    scripts/run-mac.py                 # build (Debug) + open
    scripts/run-mac.py --release       # build Release
    scripts/run-mac.py --clean         # clean build
    scripts/run-mac.py --no-open       # build only
    scripts/run-mac.py --logs          # run in the foreground, streaming stdout/stderr
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / "MuonPlayer.xcodeproj"
SCHEME = "MuonPlayerMac"
BUNDLE = "me.pecheny.muonplayer"


def build(configuration: str, clean: bool) -> None:
    actions = (["clean"] if clean else []) + ["build"]
    cmd = ["xcodebuild", "-project", str(PROJECT), "-scheme", SCHEME,
           "-configuration", configuration,
           "-destination", "platform=macOS,arch=arm64", *actions]
    print("$ " + " ".join(cmd))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode:
        errors = [l for l in proc.stdout.splitlines() if ": error:" in l]
        print("\n".join(errors[-25:] or proc.stdout.splitlines()[-25:]), file=sys.stderr)
        sys.exit(f"\nbuild failed ({configuration})")
    print(f"build succeeded ({configuration})")


def product(configuration: str) -> Path:
    pattern = f"Library/Developer/Xcode/DerivedData/MuonPlayer-*/Build/Products/{configuration}/{SCHEME}.app"
    apps = list(Path.home().glob(pattern))
    if not apps:
        sys.exit(f"built app not found under DerivedData ({configuration})")
    return max(apps, key=lambda p: p.stat().st_mtime)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--release", action="store_true", help="build Release instead of Debug")
    ap.add_argument("--clean", action="store_true", help="clean before building")
    ap.add_argument("--no-open", action="store_true", help="build only, don't launch")
    ap.add_argument("--logs", action="store_true",
                    help="run in the foreground and stream the app's output")
    args = ap.parse_args()

    configuration = "Release" if args.release else "Debug"
    build(configuration, args.clean)

    app = product(configuration)
    print(f"app: {app}")
    if args.no_open:
        return

    # A stale copy would keep the old binary's windows and the Dock's old icon.
    subprocess.run(["pkill", "-x", SCHEME], capture_output=True)

    if args.logs:
        print("── running in foreground (ctrl-c to stop)\n")
        try:
            subprocess.run([str(app / "Contents/MacOS" / SCHEME)])
        except KeyboardInterrupt:
            pass
    else:
        subprocess.run(["open", str(app)], check=True)
        print(f"launched {BUNDLE}")


if __name__ == "__main__":
    main()
