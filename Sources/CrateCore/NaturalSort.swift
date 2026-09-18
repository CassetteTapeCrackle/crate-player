import Foundation

/// Finder's ordering. `localizedStandardCompare` is the exact comparator Finder uses,
/// so "track 2" precedes "track 10" and accented characters land where a French
/// speaker expects them.
public func naturalLess(_ a: String, _ b: String) -> Bool {
    a.localizedStandardCompare(b) == .orderedAscending
}
