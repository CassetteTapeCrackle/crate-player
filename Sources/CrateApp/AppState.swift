import AppKit
import Foundation
import Observation
import CrateCore

@Observable
@MainActor
final class AppState {
    var rootURL: URL?
    var tree: [FolderNode] = []
    var selectedFolder: FolderNode?
    var visibleTracks: [Track] = []
    var metas: [URL: TrackMetadata] = [:]
    var nowPlaying: Track?
    var artwork: NSImage?

    var playQueue = PlayQueue(tracks: [])
    var loopMode: LoopMode = .off
    var isShuffled = false

    /// Cells the user has picked out, keyed by URL so they survive a list rebuild.
    var selectedCells: Set<CellRef> = []
    @ObservationIgnored private var anchor: CellRef?

    /// The cell currently under a text field, and what has been typed into it.
    var editingCell: CellRef?
    var editDraft = ""
    var writeProblem: String?

    var searchQuery = "" { didSet { runSearch() } }
    var searchResults: [Track] = []
    var allTracks: [Track] = []
    var isIndexing = false

    let engine = AudioEngine()
    @ObservationIgnored let store: MetadataStore
    @ObservationIgnored let nowPlayingBridge = NowPlayingBridge()
    @ObservationIgnored private var spaceMonitor: Any?
    @ObservationIgnored private var clickMonitor: Any?

    /// The list the track view shows: search results when searching, otherwise the
    /// selected folder's own tracks.
    var listedTracks: [Track] {
        searchQuery.trimmingCharacters(in: .whitespaces).isEmpty ? visibleTracks : searchResults
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {
        // Bumped when the reader changed: entries are keyed on modification time, so
        // without a new name the old AVFoundation-derived values would keep being
        // served for files nobody has touched since.
        let support = URL.applicationSupportDirectory.appendingPathComponent("Crate")
        try? FileManager.default.removeItem(
            at: support.appendingPathComponent("metadata-cache.json"))
        store = MetadataStore(loader: TagMetadataLoader(),
                              cacheURL: support.appendingPathComponent("metadata-cache-2.json"))

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "volume") != nil {
            engine.volume = Float(defaults.double(forKey: "volume"))
        }
        if let raw = defaults.string(forKey: "loopMode"), let mode = LoopMode(rawValue: raw) {
            loopMode = mode
        }
        isShuffled = defaults.bool(forKey: "isShuffled")

        wireEngine()
        wireMediaKeys()
        wireSpaceBar()
        wireEditCommit()

        if let saved = defaults.url(forKey: "rootURL") {
            setRoot(saved)
        }
    }

    func display(for track: Track) -> TrackDisplay {
        MetadataStore.display(track: track, metadata: metas[track.url] ?? TrackMetadata())
    }

    func duration(for track: Track) -> Double? {
        metas[track.url]?.durationSeconds
    }

    // MARK: Selection

    /// One editable field on one track. Selection works at this grain rather than by
    /// row, so cmd-clicking three artists and typing once changes three artists and
    /// leaves every title and album alone.
    struct CellRef: Hashable, Sendable {
        let url: URL
        let field: TagField
    }

    var selectedTracks: [Track] {
        let urls = Set(selectedCells.map(\.url))
        return listedTracks.filter { urls.contains($0.url) }
    }

    func isSelected(_ track: Track, _ field: TagField) -> Bool {
        selectedCells.contains(CellRef(url: track.url, field: field))
    }

    /// A plain click plays, immediately. Modifiers select, the way Finder does. Two
    /// clicks edit the field.
    ///
    /// Nothing is deferred waiting to see whether a second click is coming. No app
    /// does that, and the track has already started by the time the editor opens,
    /// which is just the app playing music.
    func clickCell(_ track: Track, _ field: TagField,
                   count: Int, modifiers: NSEvent.ModifierFlags) {
        if count >= 2 { return beginEdit(track, field) }
        let cell = CellRef(url: track.url, field: field)
        if modifiers.contains(.command) { return select(cell, extend: false, toggle: true) }
        if modifiers.contains(.shift) { return select(cell, extend: true, toggle: false) }
        play(track)
    }

    /// Clicks that landed on a row but missed every piece of its text.
    func clickRow(_ track: Track, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.isDisjoint(with: [.command, .shift]) else { return }
        play(track)
    }

    private func select(_ cell: CellRef, extend: Bool, toggle: Bool) {
        // A selection lives in one column, which is what makes "type once, set all"
        // mean something. Reaching into another column starts again.
        if let existing = selectedCells.first, existing.field != cell.field {
            selectedCells = []
            anchor = nil
        }
        if toggle {
            if selectedCells.contains(cell) {
                selectedCells.remove(cell)
            } else {
                selectedCells.insert(cell)
                anchor = cell
            }
            return
        }
        if extend, let anchor,
           let from = listedTracks.firstIndex(where: { $0.url == anchor.url }),
           let to = listedTracks.firstIndex(where: { $0.url == cell.url }) {
            let span = min(from, to)...max(from, to)
            selectedCells = Set(listedTracks[span].map { CellRef(url: $0.url, field: cell.field) })
            return
        }
        selectedCells = [cell]
        anchor = cell
    }

    /// Clicking past the last row drops the selection, the way clicking empty space
    /// does in any list. Without it there is no way to deselect at all, because a
    /// plain click plays instead of selecting.
    func deselectAll() {
        guard editingCell == nil else { return }
        selectedCells = []
        anchor = nil
    }

    private func clearSelection() {
        selectedCells = []
        anchor = nil
        editingCell = nil
        writeProblem = nil
    }

    // MARK: Editing

    /// What is actually in the tag, which is not what the list shows. Most files here
    /// have no title frame and display their filename instead, and opening an editor
    /// on that filename would turn every edit into an accidental commitment to it.
    func rawFields(for track: Track) -> TagFields {
        let meta = metas[track.url] ?? TrackMetadata()
        return TagFields(title: meta.title, artist: meta.artist, album: meta.album)
    }

    func beginEdit(_ track: Track, _ field: TagField) {
        guard TagWriter.canWrite(track.url) else {
            writeProblem = TagWriteError.unsupportedFormat(track.url.pathExtension).description
            return
        }
        let cell = CellRef(url: track.url, field: field)
        if !selectedCells.contains(cell) { select(cell, extend: false, toggle: false) }
        writeProblem = nil
        editDraft = field.value(in: rawFields(for: track)) ?? ""
        editingCell = cell
    }

    func cancelEdit() { editingCell = nil }

    /// Writes to every selected cell, which is the whole point of being able to select
    /// more than one.
    func commitEdit() {
        guard let cell = editingCell else { return }
        let typed = editDraft
        editingCell = nil

        let urls = selectedCells.isEmpty ? [cell.url] : Set(selectedCells.map(\.url))
        let targets = listedTracks.filter { urls.contains($0.url) }
        guard !targets.isEmpty else { return }

        // Nothing typed, nothing to write.
        if targets.count == 1,
           typed == (cell.field.value(in: rawFields(for: targets[0])) ?? "") { return }

        // The selection has done its job; leaving it lit reads as a leftover rectangle
        // on whichever cell was edited last.
        selectedCells = []
        anchor = nil

        let edit = TagEdit(cell.field, typed.isEmpty ? .cleared : .set(typed))
        Task { await write(edit, to: targets) }
    }

    /// Any click that is not inside a text field closes an open editor.
    ///
    /// This is one event monitor rather than SwiftUI focus because a click on a plain
    /// view never moves first responder, so the field would keep the caret and the
    /// edit would stay open. The app already reads NSEvent this way for the space bar.
    private func wireEditCommit() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, self.editingCell != nil,
                      let content = NSApp.keyWindow?.contentView else { return }
                let hit = content.hitTest(location)
                guard !(hit is NSTextView), !(hit is NSTextField) else { return }
                self.commitEdit()
            }
            return event
        }
    }

    /// Writes, then re-reads what landed on disk rather than assuming the write did
    /// what was asked. A batch that partly fails names the files it could not write.
    private func write(_ edit: TagEdit, to tracks: [Track]) async {
        let failures = await Task.detached { () -> [TagWriteFailure] in
            var failed: [TagWriteFailure] = []
            for track in tracks {
                do {
                    try TagWriter.write(edit, to: track.url)
                } catch let error as TagWriteError {
                    failed.append(TagWriteFailure(url: track.url, error: error))
                } catch {
                    failed.append(TagWriteFailure(
                        url: track.url, error: .io(error.localizedDescription)))
                }
            }
            return failed
        }.value

        let failedURLs = Set(failures.map(\.url))
        for track in tracks where !failedURLs.contains(track.url) {
            // The cache is keyed on modification time and size, so the swap already
            // invalidated the entry and this re-reads from disk.
            metas[track.url] = await store.metadata(for: track)
        }
        try? await store.save()
        if let playing = nowPlaying, !failedURLs.contains(playing.url) { publishNowPlaying() }

        guard let first = failures.first else { return writeProblem = nil }
        writeProblem = tracks.count == 1
            ? first.error.description
            : "WROTE \(tracks.count - failures.count) OF \(tracks.count). FAILED: "
                + failures.map { $0.url.lastPathComponent }.joined(separator: ", ")
    }

    // MARK: Library

    func setRoot(_ url: URL) {
        rootURL = url
        UserDefaults.standard.set(url, forKey: "rootURL")
        tree = (try? LibraryScanner.scan(root: url)) ?? []
        selectedFolder = nil
        visibleTracks = []
        restoreLastFolder()
        Task { await buildIndex() }
    }

    func select(_ folder: FolderNode) {
        selectedFolder = folder
        UserDefaults.standard.set(folder.url, forKey: "lastFolderURL")
        visibleTracks = (try? AudioFiles.tracks(in: folder.url)) ?? []
        clearSelection()
        Task { await loadMetadata(for: visibleTracks) }
    }

    /// Reopens whatever folder was showing when the app last quit.
    private func restoreLastFolder() {
        guard let saved = UserDefaults.standard.url(forKey: "lastFolderURL"),
              let node = findNode(at: saved, in: tree) else { return }
        select(node)
    }

    private func findNode(at url: URL, in nodes: [FolderNode]) -> FolderNode? {
        for n in nodes {
            if n.url == url { return n }
            if let hit = findNode(at: url, in: n.children) { return hit }
        }
        return nil
    }

    /// Searching the whole library requires the whole library indexed, so this runs
    /// once after the tree is scanned and is cached on disk thereafter.
    func buildIndex() async {
        isIndexing = true
        defer { isIndexing = false }

        var found: [Track] = []
        func walk(_ nodes: [FolderNode]) {
            for n in nodes {
                found.append(contentsOf: (try? AudioFiles.tracks(in: n.url)) ?? [])
                walk(n.children)
            }
        }
        walk(tree)
        allTracks = found

        await loadMetadata(for: found)
    }

    private func loadMetadata(for tracks: [Track]) async {
        for track in tracks where metas[track.url] == nil {
            metas[track.url] = await store.metadata(for: track)
        }
        try? await store.save()
    }

    private func runSearch() {
        clearSelection()
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = []; return }

        var scored: [(Track, Int)] = []
        for track in allTracks {
            let d = display(for: track)
            let haystack = [d.title, d.artist, d.album].joined(separator: " ")
            if let s = FuzzyMatcher.score(query: q, candidate: haystack) {
                scored.append((track, s))
            }
        }
        searchResults = scored.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)
    }

    // MARK: Playback

    private func wireEngine() {
        engine.onFinish = { [weak self] in
            guard let self else { return }
            if let nextTrack = self.playQueue.advance() {
                self.start(nextTrack)
            } else {
                self.nowPlaying = nil
                self.publishNowPlaying()
            }
        }
    }

    /// Space toggles playback while Crate is frontmost, unless the caret is sitting in
    /// a text field. The test is the window's first responder rather than SwiftUI focus
    /// state, so it stays right however focus was acquired, and it leaves typing in the
    /// search box alone.
    private func wireSpaceBar() {
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Read what we need off the event before hopping. NSEvent is not Sendable,
            // so it must not be captured across the isolation boundary.
            let isPlainSpace = event.keyCode == 49
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard isPlainSpace else { return event }

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, !(NSApp.keyWindow?.firstResponder is NSTextView) else {
                    return false
                }
                self.togglePlayPause()
                return true
            }
            return handled ? nil : event   // swallowing it avoids the beep
        }
    }

    private func wireMediaKeys() {
        nowPlayingBridge.connect(
            play: { [weak self] in self?.togglePlayPause() },
            pause: { [weak self] in self?.engine.togglePause(); self?.publishNowPlaying() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() }
        )
    }

    /// Playing anything makes its folder the queue, which is the rule search results
    /// follow too.
    ///
    /// Clicking the track that is already loaded never sends it back to the start. It
    /// resumes if paused and otherwise does nothing, so double-clicking a field to fix
    /// a tag on the track you are listening to does not interrupt it.
    func play(_ track: Track) {
        if nowPlaying == track {
            if !engine.isPlaying { engine.togglePause() }
            publishNowPlaying()
            return
        }
        let folderTracks = (try? AudioFiles.tracks(in: track.folderURL)) ?? [track]
        let startIndex = folderTracks.firstIndex(of: track) ?? 0
        playQueue = PlayQueue(tracks: folderTracks, startAt: startIndex)
        playQueue.loopMode = loopMode
        if isShuffled { playQueue.setShuffled(true, seed: nil) }
        start(track)
    }

    private func start(_ track: Track) {
        nowPlaying = track
        engine.play(track.url)
        Task {
            let meta = await store.metadata(for: track)
            metas[track.url] = meta
            artwork = await loadArtwork(
                MetadataStore.artworkSource(for: track, metadata: meta))
            publishNowPlaying()
        }
        publishNowPlaying()
    }

    func togglePlayPause() {
        if nowPlaying == nil {
            if let first = listedTracks.first { play(first) }
        } else {
            engine.togglePause()
        }
        publishNowPlaying()
    }

    func next() {
        if let t = playQueue.next() { start(t) }
    }

    func previous() {
        if let t = playQueue.previous() { start(t) }
    }

    func cycleLoop() {
        loopMode = loopMode.next
        playQueue.loopMode = loopMode
        UserDefaults.standard.set(loopMode.rawValue, forKey: "loopMode")
    }

    func toggleShuffle() {
        isShuffled.toggle()
        playQueue.setShuffled(isShuffled, seed: nil)
        UserDefaults.standard.set(isShuffled, forKey: "isShuffled")
    }

    func setVolume(_ v: Double) {
        engine.volume = Float(max(0, min(1, v)))
        UserDefaults.standard.set(v, forKey: "volume")
    }

    func publishNowPlaying() {
        nowPlayingBridge.update(
            display: nowPlaying.map { display(for: $0) },
            artwork: artwork,
            duration: engine.duration,
            elapsed: engine.currentTime,
            isPlaying: engine.isPlaying
        )
    }
}

/// One file a batch edit could not write, carried back out of the detached task.
struct TagWriteFailure: Sendable {
    let url: URL
    let error: TagWriteError
}

/// Formats seconds as m:ss. Shared by the list, the player bar and the menu bar.
func timecode(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
