# MuonPlayer

A local music player over a folder of files. Everything it knows comes from the
tags in those files and where they sit on disk, so the language below is mostly
about telling those two apart.

## Language

**Album**:
A release, identified by its album-artist, title and year. One album may exist on
disk more than once.
_Avoid_: Record

**Rip**:
One folder's worth of an album — a single encoding of it. An album held as both a
FLAC and an OPUS copy is one album and two rips. Every screen and every play order
keeps a rip's tracks together and in their own order.
_Avoid_: Copy, folder group, encode

**Root**:
A folder the user has given the app to index. iOS has exactly one; macOS has as
many as the user adds.
_Avoid_: Library folder, source

**Context**:
The list of tracks a play command was issued against — what "next" means for as
long as it lasts. Picking a track from a rip gives that rip as the context.
_Avoid_: Playlist

**Timeline**:
The full automatic play order for the current playback mode, which may reach far
beyond the context — a whole artist's discography under Repeat Artist. It is
rebuilt around whatever is playing whenever playback leaves the mode's scope.
_Avoid_: Queue (that is the separate, user-built list of tracks to play next)

**Seam**:
The join between two consecutive tracks of an album that were meant to run
together. A seam is broken when silence, a step in the waveform, or a dip in the
sound appears at the join.
_Avoid_: Gap, transition
