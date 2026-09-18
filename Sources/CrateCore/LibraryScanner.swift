import Foundation

public enum LibraryScanner {
    /// Walks `root` and returns its immediate subdirectories as a tree, each carrying
    /// the count of audio files directly inside it. Directories only, so this stays
    /// fast enough to need no progress indicator.
    public static func scan(
        root: URL,
        fileManager: FileManager = .default
    ) throws -> [FolderNode] {
        try directories(in: root, fileManager: fileManager).map { dir in
            FolderNode(
                url: dir,
                name: dir.lastPathComponent,
                directTrackCount: (try? AudioFiles.tracks(in: dir, fileManager: fileManager).count) ?? 0,
                children: (try? scan(root: dir, fileManager: fileManager)) ?? []
            )
        }
    }

    private static func directories(in url: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
    }
}
