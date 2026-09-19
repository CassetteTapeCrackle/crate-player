import Foundation

/// Reads the three fields Crate writes, using the same parsers the writer uses.
///
/// The writer has to walk every frame anyway in order to preserve the ones it does
/// not understand, so a tested parser exists either way. Using it for reads as well
/// is what guarantees that what Crate saves is what Crate shows, whichever metadata
/// convention a given container happens to favour and whatever AVFoundation decides
/// to surface from it.
public enum TagReader {
    /// Nil means "no opinion": an unsupported format, or a tag this cannot parse.
    /// Reading must never break the display, so nothing throws out of here.
    public static func read(_ url: URL) -> TagFields? {
        guard let backend = TagBackend.forExtension(url.pathExtension),
              let file = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        switch backend {
        case .flac:
            return try? FLACTagging.readFields(file)
        case .id3(let container):
            // `try?` flattens here, so a nil blob and a refused parse both land in the
            // same place, which is the right answer for a reader either way.
            guard let blob = try? ID3Containers.extractTag(from: file, kind: container),
                  let tag = try? ID3v2.parse(blob) else { return nil }
            return tag.fields
        }
    }
}

/// Layers Crate's own tag parsing over AVFoundation.
///
/// AVFoundation keeps the jobs it is good at, duration and artwork presence, and
/// stays the only reader for formats Crate cannot write. For everything else our
/// parser is authoritative on title, artist and album, including when it finds them
/// absent: that is precisely the case where a stale legacy chunk would otherwise leak
/// through and contradict the tag we just wrote.
public struct TagMetadataLoader: MetadataLoading {
    private let fallback: any MetadataLoading

    public init(fallback: any MetadataLoading = AVMetadataLoader()) {
        self.fallback = fallback
    }

    public func load(_ url: URL) async -> TrackMetadata {
        var result = await fallback.load(url)
        guard let own = TagReader.read(url) else { return result }
        result.title = own.title
        result.artist = own.artist
        result.album = own.album
        return result
    }
}
