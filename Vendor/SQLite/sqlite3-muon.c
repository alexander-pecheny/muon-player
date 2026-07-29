// The amalgamation gates FTS5 behind SQLITE_ENABLE_FTS5, and the library's search
// (and the triggers on `tracks`) need it. Setting the define here rather than in
// Package.swift's cSettings keeps it attached to the source: a build that misses
// it does not fail, it silently creates the triggers without the table they write
// to, and then every INSERT into `tracks` fails with "no such table: tracks_fts".
#define SQLITE_ENABLE_FTS5 1
#define SQLITE_THREADSAFE 1
#include "sqlite3.c"
