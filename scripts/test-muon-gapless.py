#!/usr/bin/env python3
"""Synthetic correctness suite for muon-gapless.

Builds a library of albums whose seams are known by construction — a continuous
tone cut in two, the same cut with a phase jump welded into it, a pair separated
by real silence, a pair whose lossy encode strands the encoder delay at the seam —
then checks the script calls each one what it is.

    python3 scripts/test-muon-gapless.py
"""

import json
import math
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile

RATE = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))



def wav(path, samples):
    data = b"".join(struct.pack("<h", max(-32768, min(32767, int(s * 32767)))) for s in samples)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16))
        f.write(b"data" + struct.pack("<I", len(data)) + data)


def encode(src, dst, *args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, *args, dst], check=True)


def tone(n, freq=440.0, phase=0.0, amp=0.5):
    return [amp * math.sin(2 * math.pi * freq * i / RATE + phase) for i in range(n)]


def silence(n):
    return [0.0] * n


def build(tmp):
    """Return (directory, [(name, samples)]) for each album, and how it must be judged."""
    albums = {}

    # A continuous tone cut in two: the textbook seamless transition.
    cont = tone(RATE * 2)
    albums["flow"] = [("01.wav", cont[:RATE]), ("02.wav", cont[RATE:])]

    # Same, but track 2 picks the tone up at its peak instead of where track 1 left
    # off: a step at the splice that no part of the music itself makes. That is a
    # click. (Restarting at phase π would *not* be one — that lands on a zero
    # crossing, and a kink with no step in it is inaudible.)
    albums["click"] = [("01.wav", cont[:RATE]), ("02.wav", tone(RATE, phase=math.pi / 2))]

    # An ordinary boundary: fade to nothing, a beat of silence, then the next
    # track. Must not be reported at all.
    albums["silent"] = [
        ("01.wav", tone(RATE) + silence(RATE // 2)),
        ("02.wav", silence(RATE // 2) + tone(RATE)),
    ]

    # Two hard cuts with 30 ms of digital silence wedged between them — what a
    # decoder does with a lossy file whose priming delay it cannot see.
    albums["gap"] = [
        ("01.wav", cont[:RATE] + silence(int(RATE * 0.015))),
        ("02.wav", silence(int(RATE * 0.015)) + cont[RATE:]),
    ]

    for name, tracks in albums.items():
        d = os.path.join(tmp, name)
        os.makedirs(d)
        for fname, samples in tracks:
            wav(os.path.join(d, fname), samples)
        albums[name] = [os.path.join(d, f) for f, _ in tracks]
    return albums


def make_db(tmp, albums, codec="pcm_s16le"):
    db = os.path.join(tmp, "library.sqlite")
    con = sqlite3.connect(db)
    con.execute("""CREATE TABLE tracks (
        id INTEGER PRIMARY KEY, path TEXT UNIQUE, title TEXT, artist TEXT, album TEXT,
        album_artist TEXT, track_no INTEGER, disc_no INTEGER, duration REAL, year INTEGER,
        has_artwork INTEGER DEFAULT 0, date_added REAL DEFAULT 0, mtime REAL,
        composer TEXT, bitrate INTEGER, codec TEXT,
        ov_title TEXT, ov_artist TEXT, ov_album TEXT, ov_album_artist TEXT,
        ov_composer TEXT, ov_track_no INTEGER)""")
    for album, paths in albums.items():
        for i, p in enumerate(paths, start=1):
            con.execute(
                "INSERT INTO tracks (path, title, artist, album, album_artist, track_no,"
                " disc_no, duration, codec) VALUES (?,?,?,?,?,?,1,1.0,?)",
                (p, f"t{i}", "Tester", album, "Tester", i, codec))
    con.commit()
    con.close()
    return db


def run(binary, db):
    out = subprocess.run([binary, "--db", db, "--json"], capture_output=True, text=True, check=True)
    found = {}
    for row in json.loads(out.stdout):
        found[row["album"]] = row["kind"]
    return found


def build_binary():
    """The scanner is an Xcode target now — it links the app's FFmpeg to decode
    in-process, so there is nothing swiftc alone can compile."""
    subprocess.run(
        ["xcodebuild", "-project", os.path.join(ROOT, "MuonPlayer.xcodeproj"),
         "-scheme", "MuonGapless", "-configuration", "Release",
         "-destination", "platform=macOS,arch=arm64", "build"],
        check=True, capture_output=True, text=True, cwd=ROOT)
    out = subprocess.run(
        ["xcodebuild", "-project", os.path.join(ROOT, "MuonPlayer.xcodeproj"),
         "-scheme", "MuonGapless", "-configuration", "Release",
         "-showBuildSettings", "-json"],
        check=True, capture_output=True, text=True, cwd=ROOT)
    settings = json.loads(out.stdout)[0]["buildSettings"]
    return os.path.join(settings["BUILT_PRODUCTS_DIR"], settings["EXECUTABLE_NAME"])


def main():
    binary = build_binary()

    tmp = tempfile.mkdtemp()
    failures = []
    try:
        albums = build(tmp)
        got = run(binary, make_db(tmp, albums))

        expected = {"flow": "flow", "click": "click", "gap": "gap"}
        for album, kind in expected.items():
            if got.get(album) != kind:
                failures.append(f"{album}: expected {kind}, got {got.get(album, 'nothing')}")
        if "silent" in got:
            failures.append(f"silent: a boundary with real silence was reported as {got['silent']}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    for f in failures:
        print("FAIL " + f)
    print("FAILED" if failures else "ok — 4 seams classified correctly")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
