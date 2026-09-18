# Crate: a folder-first music player for macOS

**Status:** approved design, not yet implemented
**Date:** 2026-09-18

## Problem

Apple Music and its alternatives impose a library model: albums, artists, playlists,
smart folders. Matt's music is already organised, on disk, as nested folders, and
every player insists on reorganising it. He wants an app that plays a folder in the
order the folder is in, and does nothing else.

## Goals

Point the app at a root directory. It shows the folder tree. Select a folder, its
tracks play in order. Shuffle them, loop them, control them from the media keys,
see what is playing from the menu bar. Nothing else.

## Non-goals

No playlists. No library database as a user-facing concept. No ratings, play counts,
smart folders, tag editing, or file management. No streaming, no cloud, no network
access of any kind. No sorting controls beyond the single defined order.

## The collection this is built for

Measured from `~/DJ TRACKS TRIÉES` on 2026-09-18:

- 1,698 audio files: 1,398 mp3, 196 aiff, 60 flac, 44 wav.
- Exactly two levels deep. Category folder, then optional subfolder, then files.
- No loose files at the root.
- 115 tracks sit directly in category folders, 1,599 inside subfolders.
- ID3 tags are mostly complete (title, artist, album, track) with embedded artwork.
  Some YouTube rips carry junk, for example `artist=tonton4o`.
- A few album folders carry a `cover.jpg` alongside the audio.

Scale matters for design decisions: 1,698 files is small. A full metadata scan is a
few seconds, not minutes, and the whole index fits in memory without strain.

## Stack

**Swift 6 + SwiftUI + AVFoundation.** No third-party dependencies.

Chosen for resource cost, which was an explicit requirement. An Electron shell would
cost roughly 150MB idle and bundle a browser engine. Tauri would still ship a webview
and would fight the OS for media key integration. Native Swift idles at the cost of a
menu bar item and a decode thread.

### Building without Xcode

**Xcode is not installed on this machine and is not required.** Verified on
2026-09-18 by compiling, not by assumption:

- `xcode-select -p` resolves to `/Library/Developer/CommandLineTools`.
- The CLT SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` contains
  SwiftUI, AppKit, AVFoundation and MediaPlayer.
- A SwiftUI app using `MenuBarExtra`, AVFoundation and MediaPlayer compiled cleanly
  with `swiftc` to a 60KB arm64 binary.
- That binary packaged into an `.app` with a hand-written `Info.plist` and ad-hoc
  signed with `codesign --force --deep --sign -` verified correctly.

`/usr/bin/xcodebuild` exists but is only a stub and errors without Xcode. We never
invoke it.

### Repository layout

```
music-player/
  Package.swift                 SwiftPM: CrateCore library + test target
  Sources/CrateCore/            pure logic, no UI, unit tested
  Sources/CrateApp/             SwiftUI views and entry point
  Tests/CrateCoreTests/         swift-testing
  Resources/DepartureMono-Regular.otf
  build.sh                      swiftc -> Crate.app -> ad-hoc codesign
```

`swift test` runs the logic suite. `build.sh` assembles the bundle, which is the job
Xcode would otherwise do.

## Architecture

Logic lives in `CrateCore` with no SwiftUI import, so it is testable without a running
app. The UI layer holds no rules.

### CrateCore

- **`LibraryScanner`** walks the root directory and returns a `FolderNode` tree.
  Directories only, so it is fast enough to need no progress UI. Skips dotfiles and
  non-audio files.
- **`TrackList`** resolves one folder's audio files into ordered `Track` values.
- **`MetadataStore`** reads tags and artwork via `AVAsset`, backed by an on-disk cache
  keyed by path, mtime and size. Owns the full-library index that search needs.
- **`FuzzyMatcher`** subsequence matching with scoring. Pure function, heavily tested.
- **`PlayQueue`** owns order, shuffle and the loop state machine. The most
  behaviour-dense unit and the one with the most tests.
- **`AudioEngine`** wraps `AVAudioPlayer`: play, pause, seek, volume, and a
  track-finished callback. The only unit that touches audio hardware.

### CrateApp

- **`AppState`** observable root that wires Core to views.
- **`SidebarView`**, **`TrackListView`**, **`PlayerBar`**, **`SearchField`**
- **`MenuBarView`** the `MenuBarExtra` mini player.
- **`NowPlayingBridge`** `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`.
- **`SettingsView`** root folder picker.

## Behaviour

### Folder selection and play scope

Selecting a folder plays **only the audio files directly inside it**. Subfolders are
not included recursively. Selecting `Hardcore` plays the tracks loose in `Hardcore`,
not the contents of `Frenchcore`.

**Consequence, accepted:** a category folder containing only subfolders has nothing to
play. In that case the track list shows an empty state naming the subfolders rather
than appearing broken or playing silence. Each folder in the sidebar shows its direct
track count, so this is visible before clicking.

### Track order

`localizedStandardCompare` on the filename. This is exactly Finder's natural sort, so
`track 2` precedes `track 10`, and it works on untagged files. Order never changes
based on tags, and there are no user-facing sort controls.

### Loop and shuffle

The loop button cycles three states, matching Deezer's model:

1. **Off.** Playback stops at the end of the folder.
2. **Repeat folder.** The folder restarts from the top.
3. **Repeat track.** The current track repeats.

Shuffle is a separate toggle that reorders the current folder's queue. It composes
with either loop mode. Shuffle uses a shuffled index order, not random selection, so
every track plays once before any repeats.

Playback never rolls from one folder into the next. Folders are the unit.

### Interaction

- **Single click** on a track selects it. **Double click** plays it.
- Playing a track makes its containing folder the queue, starting from that track.
  This is the same rule search results follow.
- **Return** plays the selection. **Space** toggles play and pause globally.
- **Left and right arrows** move through the queue, matching F7 and F9.
- Clicking a folder in the sidebar selects it and shows its tracks. It does not start
  playback on its own, so browsing never interrupts what is already playing.

### Metadata and artwork

Display precedence for each field:

- **Title:** ID3 title, else filename without extension.
- **Artist:** ID3 artist, else blank.
- **Album:** ID3 album, else blank.
- **Artwork:** embedded art, else `cover.jpg` in the containing folder, else a drawn
  placeholder.

Filenames are not parsed to extract `Artist - Title`. Junk tags are displayed as they
are. This is deliberate: guessing produces confident wrong answers, and the tags are
good enough in the large majority of cases.

### Search

Fuzzy subsequence matching over the whole library, so `stfmnd` matches
`Stef Mendesidis`. Scoring favours matches at word boundaries and penalises gaps.
Matches against title, artist and album.

Results display the track with its folder path. Selecting a result plays it in the
context of its folder, meaning the rest of that folder becomes the queue.

**Consequence, accepted:** searching everything requires indexing everything. The
design therefore performs one full metadata scan at first launch, cached to disk, then
incremental updates keyed by mtime. This replaces the lazy per-folder loading that
would otherwise be preferable, and is the reason `MetadataStore` owns a full index.

### Media keys

`MPRemoteCommandCenter` handles F7, F8 and F9 with no Accessibility permission prompt,
and `MPNowPlayingInfoCenter` supplies the Control Center Now Playing tile with artwork.

**Known limitation, not fixable without a global event tap:** macOS routes media keys
to whichever app played most recently. Playing audio in Safari hands the keys to
Safari until Crate plays again. A `CGEventTap` would override this but requires
Accessibility permission, which contradicts the goal of an app that never asks for
anything.

### Menu bar

`MenuBarExtra` in `.window` style showing artwork, title, artist, transport, volume.
Closing the main window leaves the app running in the menu bar.

### Settings and persistence

Settings contains exactly one control: the root folder picker. Stored in
`UserDefaults` alongside volume, loop mode, shuffle state and last selected folder,
which are state rather than settings and get no UI of their own.

## Visual design

Approved from the look book: monochrome interface, single brick accent, Departure Mono
throughout.

### Rules

- Square corners everywhere. `cornerRadius: 0`. Window traffic lights are OS chrome.
- Controls are a 1px stroke on transparent. No fills, shadows or gradients.
- The interface is neutral grey. The accent marks state only: playing track, progress
  fill, armed loop, selected folder. It never decorates.

### Typography

**Departure Mono** Regular, version 001.500, Helena Zhang, SIL OFL 1.1. Bundled in
the app via `ATSApplicationFontsPath` in `Info.plist`. Source:
`https://departuremono.com/assets/DepartureMono-Regular.otf`, 84KB OpenType/CFF,
downloaded and verified on 2026-09-18.

Two features of the face the design uses deliberately:

- It carries **tabular figure sets** (`.tf`), so the duration and track-number columns
  align without the layout doing extra work.
- It carries the full **box-drawing and block-element range**, `U+2500` to `U+259F`.
  The progress and volume bars should be drawn with block characters such as
  `U+2588` and `U+2591` rather than as filled rectangles, which keeps them on the
  same pixel grid as the type instead of cutting across it.

It ships **Regular only**. There is no bold. Hierarchy comes from size, case and
colour, and `font-synthesis` equivalents must stay off so macOS never synthesises a
faux bold, which would break the pixel grid. Departure Mono is a bitmap face designed
on a fixed grid and should be rendered without antialiasing where the platform allows.

Sizes: 12px list rows, 11px secondary, 10px uppercase micro labels with letter
spacing, 13px now-playing title.

### Palette

Dark, the primary mode:

| Token | Hex | Contrast on ground |
|---|---|---|
| ground | `#0D0D0C` | |
| chrome | `#131312` | |
| sidebar | `#101010` | |
| ink | `#E7E7E4` | 15.69:1 |
| dim | `#8A8884` | 5.50:1 |
| faint | `#807E7A` | 4.80:1 |
| rule | `#232322` | |
| rule-strong | `#333331` | |
| selection | `#1E1714` | |
| accent | `#C0826A` | 6.15:1 |

Light:

| Token | Hex | Contrast on ground |
|---|---|---|
| ground | `#F2F2F1` | |
| chrome | `#E9E9E7` | |
| sidebar | `#EDEDEB` | |
| ink | `#1A1A19` | 15.55:1 |
| dim | `#6B6A67` | 4.83:1 |
| faint | `#6E6D69` | 4.62:1 |
| rule | `#DCDCDA` | |
| rule-strong | `#C2C2BF` | |
| selection | `#F0E4DE` | |
| accent | `#9C563C` | 4.92:1 |

Every text tier meets WCAG AA. The light accent is darker than the dark-mode accent
because brick at `#C0826A` only reaches 3.7:1 on a light ground.

### Layout

Three regions: collapsible folder tree on the left at 214px, track list in the centre,
persistent player bar along the bottom.

Track list columns: index, title, artist, album, duration. The index column shows a
three-bar equaliser glyph in the accent colour for the playing row, replacing the
number. The playing row also takes a faint tinted background, because without a bold
weight available colour alone was carrying too much.

The sidebar header shows the root folder name and a gear that opens Settings. Each
folder row shows its direct track count.

## Gatekeeper and file access

The problem being solved: Matt is tired of macOS asking permission to open his own
files.

- **Not sandboxed.** Sandboxing would require security-scoped bookmarks and produce
  exactly the prompts being avoided.
- **Ad-hoc signed**, built locally. Verified: a locally built bundle receives no
  `com.apple.quarantine` attribute, only the benign `com.apple.provenance`. Gatekeeper
  only challenges apps that arrive carrying quarantine from a download, so there is no
  unverified-developer dialog and no per-file verification.
- `~/DJ TRACKS TRIÉES` sits in the home root, which is not TCC-protected, unlike
  Desktop, Documents and Downloads. macOS will not prompt for it at all.
- AVAudioPlayer reads mp3, wav, aiff, flac, m4a, alac and aac through CoreAudio, which
  covers every file in the collection.

**Caveat worth stating:** this holds because the app is built on the machine it runs
on. Distributing it to another Mac would reintroduce quarantine and require either
notarisation or a manual `xattr -d` by the recipient. Out of scope.

## Testing

`CrateCore` is covered by unit tests, with priority in this order:

1. **`PlayQueue`** every loop and shuffle state transition, folder boundaries,
   next and previous at the ends of a queue, shuffle covering each track once.
2. **`FuzzyMatcher`** known matches such as `stfmnd` to `Stef Mendesidis`, ranking
   order, non-matches, empty query, case and accent handling.
3. **`TrackList`** natural sort, including numeric ordering and accented characters
   such as `Après La Pluie`.
4. **`LibraryScanner`** tree shape, dotfile and non-audio exclusion, empty folders.
5. **`MetadataStore`** cache hit and miss, invalidation on mtime change, fallback
   precedence for artwork.

`AudioEngine` and the SwiftUI layer are verified by running the app, not by unit test.

Every bug found after implementation gets a regression test.

## Open items

- **App name.** "Crate" is provisional. It is only a bundle name and display string.
- **Empty category folders.** The empty state is designed but the actual count of
  affected folders was not measured. It will be visible immediately on first run.

## Decisions deliberately made against the obvious alternative

- Flat folder play rather than recursive, because Matt chose it knowing the tradeoff.
- Full metadata index rather than lazy loading, forced by library-wide search.
- No filename parsing for missing tags, because a confident wrong artist is worse
  than a blank one.
- No global event tap for media keys, because the Accessibility prompt would violate
  the whole point of the app.
