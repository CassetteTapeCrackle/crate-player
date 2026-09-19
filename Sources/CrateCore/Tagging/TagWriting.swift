import Foundation

/// What an edit does to one field.
///
/// Three states rather than `String?`, because "leave this alone" and "make this
/// empty" are different instructions and only one of them is expressible as nil. The
/// distinction is also what lets a multi-track edit work without a separate code
/// path: a field whose selected tracks disagree simply sends `.unchanged`.
public enum FieldEdit: Equatable, Sendable {
    case unchanged
    case set(String)
    case cleared

    /// Applies this edit to whatever is on disk. A `.set` of an all-whitespace string
    /// counts as clearing, so the editor cannot write a frame that renders blank.
    func resolve(_ current: String?) -> String? {
        switch self {
        case .unchanged: current
        case .cleared: nil
        case .set(let value):
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
    }
}

/// The three fields Crate can write. Everything else in a tag is passed through
/// untouched.
public struct TagEdit: Equatable, Sendable {
    public var title: FieldEdit
    public var artist: FieldEdit
    public var album: FieldEdit

    public init(title: FieldEdit = .unchanged,
                artist: FieldEdit = .unchanged,
                album: FieldEdit = .unchanged) {
        self.title = title
        self.artist = artist
        self.album = album
    }

    public var touchesNothing: Bool {
        title == .unchanged && artist == .unchanged && album == .unchanged
    }
}

/// Title, artist and album as they stand in a file. Deliberately not `TrackMetadata`:
/// this layer knows nothing about duration or artwork, which still come from
/// AVFoundation.
public struct TagFields: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }

    public var isEmpty: Bool { title == nil && artist == nil && album == nil }

    func applying(_ edit: TagEdit) -> TagFields {
        TagFields(title: edit.title.resolve(title),
                  artist: edit.artist.resolve(artist),
                  album: edit.album.resolve(album))
    }
}

public enum TagWriteError: Error, Equatable, Sendable {
    /// A container with no writer yet. m4a and friends land here until issue #2.
    case unsupportedFormat(String)
    case notWritable
    /// The parse could not account for every byte, so the file is left alone. On
    /// irreplaceable files a refusal beats a guess.
    case malformed(String)
    case io(String)
}

extension TagWriteError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedFormat(let ext): "Crate cannot write \(ext.uppercased()) tags yet"
        case .notWritable: "The file is not writable"
        case .malformed(let why): "The existing tag could not be read: \(why)"
        case .io(let why): "Could not write the file: \(why)"
        }
    }
}

/// The three editable fields, named so the interface can talk about one of them
/// without the view layer inventing its own vocabulary.
public enum TagField: String, CaseIterable, Sendable {
    case title, artist, album

    public var label: String { rawValue.uppercased() }

    public func value(in fields: TagFields) -> String? {
        switch self {
        case .title: fields.title
        case .artist: fields.artist
        case .album: fields.album
        }
    }
}

extension TagEdit {
    /// An edit touching exactly one field, which is what inline editing produces.
    public init(_ field: TagField, _ edit: FieldEdit) {
        self.init()
        switch field {
        case .title: title = edit
        case .artist: artist = edit
        case .album: album = edit
        }
    }
}
