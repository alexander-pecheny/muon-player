#!/usr/bin/env python3
"""Build the macOS app and launch it.

    scripts/run-mac.py                 # build (Debug) + open
    scripts/run-mac.py --release       # build Release
    scripts/run-mac.py --clean         # clean build
    scripts/run-mac.py --no-open       # build only
    scripts/run-mac.py --logs          # run in the foreground, streaming stdout/stderr
    scripts/run-mac.py --refresh-icon-cache   # after changing the app icon
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / "MuonPlayer.xcodeproj"
SCHEME = "MuonPlayerMac"
BUNDLE = "me.pecheny.muonplayer"
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks"
              "/LaunchServices.framework/Versions/A/Support/lsregister")


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
    """The app this checkout just built.

    Every checkout of the repo — a git worktree, a second clone — gets its own
    DerivedData directory, and they all match `MuonPlayer-*`. Picking the newest
    app across them launches whichever copy was built last, which can quietly be
    another branch's binary. Each directory records the project it belongs to, so
    match on that instead.
    """
    root = Path.home() / "Library/Developer/Xcode/DerivedData"
    apps = []
    for dd in root.glob("MuonPlayer-*"):
        info = dd / "info.plist"
        try:
            owner = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :WorkspacePath",
                                    str(info)], capture_output=True, text=True).stdout.strip()
        except OSError:
            continue
        if Path(owner) != PROJECT:
            continue
        app = dd / "Build/Products" / configuration / f"{SCHEME}.app"
        if app.exists():
            apps.append(app)
    if not apps:
        sys.exit(f"built app not found under DerivedData for {PROJECT} ({configuration})")
    return max(apps, key=lambda p: p.stat().st_mtime)


def refresh_icon_cache(app: Path) -> None:
    """Make the Dock show a changed app icon.

    Launch Services caches an icon against the bundle's mtime, which a rebuild
    that only swapped the asset catalog does not move — so `touch` before
    re-registering, or the re-registration is a no-op.
    """
    subprocess.run(["touch", str(app)], check=True)
    subprocess.run([LSREGISTER, "-f", str(app)], check=True)
    subprocess.run(["killall", "Dock"], capture_output=True)
    print("icon cache refreshed (Dock restarted)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--release", action="store_true", help="build Release instead of Debug")
    ap.add_argument("--clean", action="store_true", help="clean before building")
    ap.add_argument("--no-open", action="store_true", help="build only, don't launch")
    ap.add_argument("--logs", action="store_true",
                    help="run in the foreground and stream the app's output")
    ap.add_argument("--refresh-icon-cache", action="store_true",
                    help="re-register the bundle and restart the Dock, so a changed icon shows")
    args = ap.parse_args()

    configuration = "Release" if args.release else "Debug"
    build(configuration, args.clean)

    app = product(configuration)
    print(f"app: {app}")
    if args.refresh_icon_cache:
        refresh_icon_cache(app)
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
