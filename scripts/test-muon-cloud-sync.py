#!/usr/bin/env python3
"""Exercise muon-cloud-sync against a synthetic library and a local 'remote'.

rclone treats a bare filesystem path as a remote, so the whole flow — including
uploads and in-place replacement — runs without touching any cloud account.

Run: python3 scripts/test-muon-cloud-sync.py
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = str(Path(__file__).resolve().parent / "muon-cloud-sync.swift")


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def mkflac(path: Path, seconds: float, rate: int, bits: int, freq: int = 440):
    """Synthesise a FLAC with the given format, plus a couple of tags."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fmt = {16: "s16", 24: "s32"}[bits]          # ffmpeg writes 24-bit FLAC from s32
    r = sh("ffmpeg", "-v", "error", "-y", "-f", "lavfi",
           "-i", f"sine=frequency={freq}:duration={seconds}:sample_rate={rate}",
           "-sample_fmt", fmt, "-metadata", "title=T", "-metadata", "artist=A",
           str(path))
    if r.returncode:
        sys.exit(f"ffmpeg failed making {path}: {r.stderr[-400:]}")


def bits_rate(path: Path):
    b = sh("metaflac", "--show-bps", str(path)).stdout.strip()
    r = sh("metaflac", "--show-sample-rate", str(path)).stdout.strip()
    return int(b), int(r)


def main():
    tmp = Path(tempfile.mkdtemp(prefix="cloudsync-test-"))
    local, remote = tmp / "local", tmp / "remote"
    (local).mkdir()
    (remote).mkdir()
    index = tmp / "index.json"

    # 1. hi-res, already on the remote at a DIFFERENT, deeper path -> resample + replace there
    mkflac(local / "Band/Album/01 hires.flac", 1.0, 96000, 24, 440)
    deep = remote / "some/deep/place/01 hires.flac"
    deep.parent.mkdir(parents=True)
    shutil.copy2(local / "Band/Album/01 hires.flac", deep)

    # 2. hi-res, not on the remote -> resample + upload to mirrored path
    mkflac(local / "Band/Album/02 hires-new.flac", 1.0, 48000, 24, 500)

    # 3. 16-bit, byte-identical copy already on the remote elsewhere -> skip
    mkflac(local / "Band/Album/03 same.flac", 1.0, 44100, 16, 600)
    (remote / "elsewhere").mkdir()
    shutil.copy2(local / "Band/Album/03 same.flac", remote / "elsewhere/03 same.flac")

    # 4. 16-bit, absent -> upload
    mkflac(local / "Band/Album/04 absent.flac", 1.0, 44100, 16, 700)

    # 5. 16-bit, remote has SAME NAME but different audio -> must still upload, not skip
    mkflac(local / "Band/Album/05 clash.flac", 1.0, 44100, 16, 800)
    mkflac(remote / "otherband/05 clash.flac", 2.0, 44100, 16, 900)

    before_hires = bits_rate(local / "Band/Album/01 hires.flac")

    r = sh("swift", SCRIPT, "--root", str(local), "--remote", str(remote),
           "--index", str(index), "--refresh-index", "--apply", "--jobs", "4")
    print(r.stdout)
    if r.returncode != 0:
        print(r.stderr[-800:], file=sys.stderr)

    ok = True

    def chk(name, cond):
        nonlocal ok
        ok &= bool(cond)
        print(("  PASS  " if cond else "  FAIL  ") + name)

    chk("source was 24bit/96000", before_hires == (24, 96000))
    chk("hi-res file is now 16bit/48000 locally", bits_rate(local / "Band/Album/01 hires.flac") == (16, 48000))
    chk("24bit/48k file is now 16bit/48000 locally", bits_rate(local / "Band/Album/02 hires-new.flac") == (16, 48000))
    chk("16-bit files were left alone", bits_rate(local / "Band/Album/04 absent.flac") == (16, 44100))

    chk("resampled copy REPLACED the deep remote object", deep.exists() and bits_rate(deep) == (16, 48000))
    chk("no duplicate created at the mirrored path for #1",
        not (remote / "Band/Album/01 hires.flac").exists())

    chk("new hi-res uploaded to mirrored path", (remote / "Band/Album/02 hires-new.flac").exists())
    chk("identical file not re-uploaded (no mirrored copy)",
        not (remote / "Band/Album/03 same.flac").exists())
    chk("absent file uploaded", (remote / "Band/Album/04 absent.flac").exists())
    chk("name clash with different audio still uploaded",
        (remote / "Band/Album/05 clash.flac").exists())
    chk("clashing remote file untouched",
        bits_rate(remote / "otherband/05 clash.flac") == (16, 44100))

    shutil.rmtree(tmp, ignore_errors=True)
    print("\nRESULT=" + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
