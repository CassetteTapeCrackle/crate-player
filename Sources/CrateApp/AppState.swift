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

    var searchQuery = "" { didSet { runSearch() } }
    var searchResults: [Track] = []
    var allTracks: [Track] = []
    var isIndexing = false

    let engine = AudioEngine()
    @ObservationIgnored let store: MetadataStore
    @ObservationIgnored let nowPlayingBridge = NowPlayingBridge()

    /// The list the track view shows: search results when searching, otherwise the
    /// selected folder's own tracks.
    var listedTracks: [Track] {
        searchQuery.trimmingCharacters(in: .whitespaces).isEmpty ? visibleTracks : searchResults
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {
        let cache = URL.applicationSupportDirectory
            .appendingPathComponent("Crate/metadata-cache.json")
        store = MetadataStore(loader: AVMetadataLoader(), cacheURL: cache)

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
    func play(_ track: Track) {
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

/// Formats seconds as m:ss. Shared by the list, the player bar and the menu bar.
func timecode(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
