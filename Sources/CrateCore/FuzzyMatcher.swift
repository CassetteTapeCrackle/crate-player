import Foundation

/// Case- and accent-insensitive subsequence matching for music search.
public enum FuzzyMatcher {
    /// Folds case and diacritics without changing whitespace or punctuation.
    public static func normalise(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Scores the earliest greedy subsequence, returning nil if it is incomplete.
    /// Consecutive characters and word starts outweigh the small position bonus.
    /// After normalisation, scanning is linear with constant auxiliary state.
    public static func score(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard !candidate.isEmpty else { return nil }

        let needle = Array(normalise(query))
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(normalise(candidate))
        guard needle.count <= haystack.count else { return nil }

        var queryIndex = 0
        var previousMatch = -1
        var previousIsWordCharacter = false
        var total = 0

        for (index, character) in haystack.enumerated() {
            let isWordCharacter = character.isLetter || character.isNumber
            let isWordStart = isWordCharacter && !previousIsWordCharacter
            previousIsWordCharacter = isWordCharacter

            guard character == needle[queryIndex] else { continue }

            total += 10
            if isWordStart { total += 12 }
            if queryIndex == 0 {
                total -= index
                if index == 0 { total += 30 }
            } else if index == previousMatch + 1 {
                total += 20
            }

            previousMatch = index
            queryIndex += 1
            if queryIndex == needle.count { return total }
        }

        return nil
    }
}
