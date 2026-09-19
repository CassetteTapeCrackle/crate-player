# Track metadata editing

**Status:** implemented on `feature/tag-editing`
**Date:** 2026-09-19
**Issue:** [#1](https://github.com/CassetteTapeCrackle/crate-player/issues/1)

## Problem

Crate reads tags and never changes them. The collection has plenty worth fixing:
titles that are really filenames, artists like `tonton4o` left behind by YouTube rips,
albums missing entirely. Every fix means leaving the app.

This reverses one line in the original design, which listed tag editing under
non-goals. That call was right at the time: the goal was a player that did not impose
a library model, and editing looked like the first step onto that slope. It is not.
Writing a correct title into a file is the opposite of a library database. The tags
stay in the files, where every other tool can read them.

## Goals

Fix title, artist and album in place, on one track or across several, writing into the
audio files themselves.

**Correctness is defined against the format specifications, not against this library.**
Where a decision could be settled by reading a spec or by counting files in
`DJ TRACKS TRIÉES`, the spec wins. The library is a source of hard test cases, never a
reason to omit a code path.

## Non-goals

Artwork, genre, year, track number, BPM and comment. Filename renaming. Any automatic
tagging or network lookup.

**m4a, AAC and ALAC are deferred, not refused.** MPEG-4 metadata lives in
`moov/udta/meta/ilst` atoms, shares no code with ID3, and brings its own chunk offset
fixup problem. It has [its own issue](https://github.com/CassetteTapeCrackle/crate-player/issues/2).

## Why this needs a tag writer

No Apple API writes tags to any format here. AVFoundation reads ID3, iTunes and Vorbis
metadata, but the only writer macOS exposes is `AVAssetExportSession`, which emits
QuickTime-family containers only. The library is 1,398 mp3, 196 aiff, 60 flac and 44
wav. Not one is writable through it.

## The hard requirement

A scan of 400 library files turned up `Serato Markers`, `Serato BeatGrid`,
`Serato Overview`, `Serato Offsets`, `Serato Autotags` and `Serato Analysis`, alongside
823 `TXXX`, 268 `APIC`, 18 `TKEY`, 18 `TBPM` and 7 `RVA2` frames.

Cue points and beatgrids live in ID3 `GEOB` frames beside the title frame. **Every
frame the writer does not understand must survive byte for byte.** This single
constraint shapes the whole design.

## Rejected approaches

**`ffmpeg`.** Installed, handles all four formats, would have been a day's work, and
destroys Serato data: even with `-c copy` it rebuilds the tag through its own muxer,
which does not round-trip unknown `GEOB` frames. It would also make a Homebrew binary
a runtime dependency of a bundle built to have none.

**TagLib.** The right library in principle. The copy here is x86_64 only on an arm64
Mac, and would be a dylib outside the bundle, breaking the self-contained local build
that keeps Gatekeeper quiet.

## Architecture

```
Sources/CrateCore/Tagging/
  ByteReading.swift     offset-based reads over Data, safe on slices
  TagWriting.swift      TagField, TagEdit, FieldEdit, TagFields, TagWriteError
  ID3v2.swift           frame-list codec for ID3v2.2 / 2.3 / 2.4
  ID3Containers.swift   the ID3 blob in mp3, AIFF and WAVE
  VorbisComment.swift   FLAC metadata block chain
  TagReader.swift       read path over the same parsers
  TagWriter.swift       extension dispatch, atomic replacement
```

One ID3v2 frame codec serves three container layouts:

| Container | Where the tag lives | Byte order |
|---|---|---|
| mp3 | bare at offset 0, plus optional ID3v1 at the tail | n/a |
| aiff | `ID3 ` chunk inside a `FORM` | big-endian |
| wav | `id3 ` chunk inside a `RIFF`/`WAVE` | little-endian |

FLAC is the only outlier and the simpler format: `VORBIS_COMMENT` is length-prefixed
`KEY=value` UTF-8.

### All three ID3v2 versions

| | v2.2 | v2.3 | v2.4 |
|---|---|---|---|
| Frame ID | 3 chars | 4 chars | 4 chars |
| Size field | 3 bytes, plain | 4 bytes, plain | 4 bytes, syncsafe |
| Flags | none | 2 bytes | 2 bytes |
| Header total | 6 bytes | 10 bytes | 10 bytes |

A census found this library holds 935 v2.3 and 463 v2.4 tags and no v2.2 at all. v2.2
is supported anyway. A version-blind parser meeting one would not merely miss a field,
it would misread every frame length in the tag. v2.2 is also written back as v2.2,
because its unknown 3-character identifiers have no 4-character equivalent to upgrade
onto, so upgrading would mean dropping them.

v2.4 tags whose frame sizes are plain big-endian rather than syncsafe are read too.
iTunes and older Lame wrote them that way and every other player copes.

### WAV carries three metadata conventions

`LIST`/`INFO` is Microsoft's 1991 convention, `id3 ` is what every tagger since about
2005 reads, `bext` is broadcast data. The rule: **`id3 ` is the source of truth,
written always.** An existing `LIST`/`INFO` is updated to match so Finder stops showing
a stale name; it is never created. `bext` is preserved like any unknown chunk.

That generalises into one principle: **legacy tag forms are mirrored when present and
never introduced.** It covers ID3v1, `LIST`/`INFO`, AIFF `NAME`/`AUTH`, and an ID3 tag
prepended to a FLAC.

### The read path

The writer walks every frame anyway to preserve unknown ones, so a tested parser
exists either way. It therefore becomes authoritative:

> For any format Crate can write, Crate's own parser decides the three fields it
> writes. AVFoundation still supplies duration and artwork presence.

What Crate writes is what Crate displays, whatever a container favours. `TagMetadataLoader`
is a decorator over the existing `MetadataLoading` protocol, so nothing already working
changes shape. A successful parse wins even when a field is absent, which is exactly
the case a stale legacy chunk would otherwise leak through.

### Preservation rules

Frames are parsed for identifier, size and flags only; payloads stay as raw bytes.

1. **Preserve the tag version.**
2. **De-unsynchronise on read, write without it, clear the flag.** Tag-level in v2.3,
   per-frame in v2.4. Copying raw payloads out of an unsynchronised tag without undoing
   it first is the classic way to corrupt one.
3. **Refuse to write anything that could not be fully parsed.** On irreplaceable files
   a refusal beats a guess.
4. **Mirror legacy tag forms when present, never introduce them.**

### Write path

Parse, splice, write to a temp file in the same directory, then `replaceItemAt` for an
atomic swap that carries creation date and Finder metadata across. Always a full
rewrite, never in-place patching: reusing padding would save milliseconds on a 50MB
aiff and would open a window where a crash leaves a half-written tag.

`MetadataStore` keys its cache on path plus modification time plus size, so the swap
invalidates the entry by construction.

Writing is blocking I/O and runs in a detached task, never on the main actor. The 1.0.1
crash is the precedent: a closure written inline in a `@MainActor` type inherits its
isolation, and a framework calling it on another queue traps under `-swift-version 6`.

## Interface

### Clicks

**One click plays. Two clicks on a field edit it.** That is how everything works and
there was nothing to invent.

Nothing is deferred waiting to see whether a second click is coming. An earlier attempt
held playback for 200ms to keep a double click from starting a track, and it felt
broken; measurement put the actual play cost at about 11ms warm, so the delay was the
entire perceived lag. No application defers its single-click action, and a track having
started by the time the editor opens is just the app playing music.

Click handling is `ClickCatcher`, a small `NSView` reporting click count and modifiers,
because SwiftUI's tap gestures report neither and layering `count: 2` over `count: 1`
makes the single tap wait for the system double-click interval.

### Selection

Cmd-click picks out individual cells, shift-click takes the run between them, as in
Finder. Clicking past the last row drops the selection.

The unit is a **cell, not a row**. Cmd-clicking the artist on three tracks and typing
once changes those three artists and leaves every title and album alone. A selection
lives in one column, and reaching into another starts a new one, which is what makes
"type once, set all" unambiguous.

The click target and the selection highlight are both sized to the glyphs rather than
the column, so double-clicking an artist means that artist and not the space beside it.

### Editing in place

A double-clicked cell becomes an outlined text field, starting from what is in the tag.
Not from the display fallback: most files here have no title frame and show their
filename, and offering that would turn every edit into an accidental commitment to it.

Enter commits, Escape cancels, clicking away commits. Committing writes to every
selected cell. An unchanged value writes nothing.

**Clicking away is handled by one `leftMouseDown` monitor, not by SwiftUI focus.** A
click on a plain view never moves first responder, so a focus-driven editor keeps the
caret and never closes. The app already reads `NSEvent` this way for the space bar.

### Errors

`TagWriteError` covers `.unsupportedFormat`, `.notWritable`, `.malformed` and `.io`. A
failure appears on a line under the list. A batch writes what it can and names what it
could not, because quietly dropping two of fourteen is the worst outcome available.

## Verification

- 81 unit tests, fixtures built from the format specifications rather than copied from
  the library, so the suite covers shapes this collection does not contain.
- `Tools/check-tag-preservation.sh` in CI: byte-level, all four containers, searching
  raw files rather than going through the parser, so a parser and writer wrong in
  matching ways cannot pass it.
- `Tools/verify-against-library.sh` over 218 real tracks: no unknown frame, no Vorbis
  comment, no audio payload and no duration changed. The audio comparison fails closed.
- End to end in the running app on copies of Serato-tagged tracks: inline edits, batch
  via cmd-click, commit by Enter and by clicking away. Serato blobs intact and `ffmpeg`
  confirms audio bit-identical every time.

## Decisions deliberately made against the obvious alternative

**Our own parser as the authority, rather than trusting AVFoundation.** Costs nothing,
because the parser must exist for the writer anyway, and ends any possibility of reader
and writer disagreeing.

**A full rewrite on every edit, rather than patching the tag in place.** Slower on
large files, immune to leaving a half-written tag.

**Refusing files we cannot fully parse, rather than best-effort.** A tagger that
declines 3% of a collection is usable. One that corrupts 3% is not.

**Supporting ID3v2.2 for a library containing none of it.** Roughly 60 lines and a
third of the test matrix, against a parser whose behaviour on a file it was never shown
would be undefined.

**No delay before playback.** Considered and built, then removed. It is the one thing
no other application does.
