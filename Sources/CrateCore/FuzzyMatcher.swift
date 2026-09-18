import Foundation

/// Case- and accent-insensitive subsequence matching for music search.
public enum FuzzyMatcher {
    /// Folds case and diacritics without changing whitespace or punctuation.
    public static func normalise(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Returns nil when `query` is not a subsequence of `candidate`, otherwise a
    /// score where higher is better.
    public static func score(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard !candidate.isEmpty else { return nil }

        let needle = Array(normalise(query))
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(normalise(candidate))
        guard needle.count <= haystack.count else { return nil }

        // A single greedy pass commits to the first occurrence of the opening
        // character, which scores badly when the real match sits further in. Searching
        // "apres" over "evil grimace - apres la pluie" would otherwise latch onto the
        // a in "grimace" and never consider the actual word. Many library tracks have
        // no title tag, so their haystack is a long filename and this case is common.
        // Retry from each plausible opening and keep the best result.
        var best: Int?
        var triedAny = false

        for start in haystack.indices where haystack[start] == needle[0] {
            let atWordStart = start == 0 || !isWordCharacter(haystack[start - 1])

            // Always try the first occurrence, then only word starts after that.
            // That bounds the work to roughly the number of words in the candidate.
            if !atWordStart && triedAny { continue }
            triedAny = true

            if let candidateScore = match(needle, haystack, from: start) {
                best = max(best ?? candidateScore, candidateScore)
            }
        }
        return best
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// Scores one alignment, requiring the first query character to sit at `start`.
    private static func match(_ needle: [Character], _ haystack: [Character],
                              from start: Int) -> Int? {
        var queryIndex = 0
        var previousMatch = -1
        var firstMatch = -1
        var total = 0
        var index = start

        while index < haystack.count, queryIndex < needle.count {
            defer { index += 1 }
            guard haystack[index] == needle[queryIndex] else { continue }

            let atWordStart = isWordCharacter(haystack[index])
                && (index == 0 || !isWordCharacter(haystack[index - 1]))

            total += 10
            if atWordStart { total += 12 }

            if queryIndex == 0 {
                firstMatch = index
                total -= index
                if index == 0 { total += 30 }
            } else if index == previousMatch + 1 {
                total += 20
            }

            previousMatch = index
            queryIndex += 1
        }

        guard queryIndex == needle.count else { return nil }

        // Penalise how spread out the match is. A run of adjacent characters has a
        // span of zero; characters scattered across the string are worth much less
        // even when each one lands on a word start.
        let span = previousMatch - firstMatch - (needle.count - 1)
        return total - span * 3
    }
}
