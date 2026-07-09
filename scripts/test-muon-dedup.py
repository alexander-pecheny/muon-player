#!/usr/bin/env python3
"""Exercise muon-dedup against a synthetic library + database.

Run: python3 scripts/test-muon-dedup.py
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = str(Path(__file__).resolve().parent / "muon-dedup.swift")
root = Path(tempfile.mkdtemp(prefix="dedup-test-")) / "deep" / "Library"
root.mkdir(parents=True)

db_path = root / "test.sqlite"
con = sqlite3.connect(db_path)
con.executescript("""
CREATE TABLE tracks (
  id INTEGER PRIMARY KEY, path TEXT UNIQUE, title TEXT, artist TEXT, album TEXT,
  album_artist TEXT, composer TEXT, track_no INT, disc_no INT, duration REAL,
  bitrate INT, codec TEXT, year INT, has_artwork INT, date_added REAL, mtime REAL,
  ov_title TEXT, ov_artist TEXT, ov_album TEXT, ov_album_artist TEXT,
  ov_composer TEXT, ov_track_no INT, ov_year INT);
""")


def add(folder, name, dur, codec, bitrate, album, artist, size=1000):
    d = root / folder
    d.mkdir(parents=True, exist_ok=True)
    p = d / name
    p.write_bytes(b"\0" * size)
    con.execute("INSERT INTO tracks(path,title,artist,album,album_artist,duration,bitrate,codec) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (str(p), name, artist, album, artist, dur, bitrate, codec))


D = [160.931791, 186.214308, 224.818186]

# 1. Same album, lossy listed FIRST alphabetically — keeper must still be the FLAC.
for i, d in enumerate(D):
    add("AAA lossy copy", f"{i}.m4a", d, "aac", 150_000, "Evolve", "Band")
    add("ZZZ lossless copy", f"{i}.flac", d, "flac", 990_000, "Evolve", "Band")

# 2. Different recording (a remaster, +40ms) — must NOT be touched.
for i, d in enumerate(D):
    add("Remaster [FLAC]", f"{i}.flac", d + 0.040, "flac", 990_000, "Remastered", "Band")
    add("Original [FLAC]", f"{i}.flac", d, "flac", 950_000, "Remastered", "Band")

# 3. Untitled album in two folders — must NOT be folded together.
add("Misc A", "x.mp3", 100.0, "mp3", 320_000, "", "")
add("Misc B", "y.mp3", 100.0, "mp3", 320_000, "", "")

# 4. Multi-disc: each disc holds different recordings, so the unit is the album
#    folder above them. Both rips must be compared as whole albums.
DISC = {"Disc 1": D, "Disc 2": [d + 17.5 for d in D]}
for disc, durs in DISC.items():
    for i, d in enumerate(durs):
        add(f"Big [MP3]/{disc}", f"{i}.mp3", d, "mp3", 320_000, "Big", "Band")
        add(f"Big [FLAC]/{disc}", f"{i}.flac", d, "flac", 900_000, "Big", "Band")

# 5. Different track counts — not the same album.
add("Short EP", "a.flac", D[0], "flac", 900_000, "EP", "Band")
add("Full EP", "a.flac", D[0], "flac", 900_000, "EP", "Band")
add("Full EP", "b.flac", D[1], "flac", 900_000, "EP", "Band")

con.commit()
con.close()

out = subprocess.run(["swift", SCRIPT, "--db", str(db_path), "--verbose"],
                     capture_output=True, text=True)
print(out.stdout)
if out.returncode != 0:
    print(out.stderr, file=sys.stderr)
    sys.exit(out.returncode)

text = out.stdout
drops = [l.split("drop  ", 1)[1].strip() for l in text.splitlines() if "drop  " in l]
keeps = [l.split("keep  ", 1)[1].strip() for l in text.splitlines() if "keep  " in l]

def check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return cond

ok = True
ok &= check("drops the AAC copy, not the FLAC", any("AAA lossy copy" in d for d in drops))
ok &= check("keeps the FLAC copy", any("ZZZ lossless copy" in k for k in keeps))
ok &= check("never drops the lossless copy of Evolve", not any("ZZZ lossless copy" in d for d in drops))
ok &= check("leaves the +40ms remaster alone", not any("master" in d.lower() or "Original" in d for d in drops))
ok &= check("does not fold untitled albums", not any("Misc" in d for d in drops))
ok &= check("multi-disc unit is the album folder, not a disc",
            any(d.endswith("Big [MP3]") for d in drops) and not any("Disc" in d for d in drops))
ok &= check("keeps the FLAC multi-disc copy", any(k.endswith("Big [FLAC]") for k in keeps))
ok &= check("ignores albums with different track counts", not any("EP" in d for d in drops))
ok &= check("nothing was actually deleted (dry run)", (root / "AAA lossy copy").exists())

print("\nRESULT=" + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
