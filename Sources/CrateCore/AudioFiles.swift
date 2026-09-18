import Foundation

public enum AudioFiles {
    /// Everything AVAudioPlayer decodes through CoreAudio. The collection this was
    /// built for contains mp3, aiff, flac and wav; the rest cost nothing to accept.
    public static let supportedExtensions: Set<String> = [
        "mp3", "wav", "aiff", "aif", "flac", "m4a", "aac", "alac", "caf", "aifc",
    ]

    public static func isAudio(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Audio files sitting immediately inside `folder`, in Finder order.
    /// Subdirectories are never descended into: play scope is flat by design.
    public static func tracks(
        in folder: URL,
        fileManager: FileManager = .default
    ) throws -> [Track] {
        let entries = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return entries
            .filter(isAudio)
            .map(Track.init(url:))
            .sorted { naturalLess($0.url.lastPathComponent, $1.url.lastPathComponent) }
    }
}
