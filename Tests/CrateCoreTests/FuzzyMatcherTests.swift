import Foundation
import Testing
@testable import CrateCore

@Test func matchesInitialsAcrossWords() {
    #expect(FuzzyMatcher.score(query: "stfmnd", candidate: "Stef Mendesidis") != nil)
    #expect(FuzzyMatcher.score(query: "sm", candidate: "Stef Mendesidis") != nil)
}

@Test func rejectsCharactersNotPresentInOrder() {
    #expect(FuzzyMatcher.score(query: "zzz", candidate: "Stef Mendesidis") == nil)
    #expect(FuzzyMatcher.score(query: "sidnem", candidate: "Stef Mendesidis") == nil)
}

@Test func ignoresCaseAndAccents() {
    #expect(FuzzyMatcher.score(query: "apres", candidate: "Après La Pluie") != nil)
    #expect(FuzzyMatcher.score(query: "APRES", candidate: "après la pluie") != nil)
}

@Test func contiguousPrefixOutranksScatteredMatch() {
    let tight = FuzzyMatcher.score(query: "deep", candidate: "Deep Burnt")!
    let loose = FuzzyMatcher.score(query: "deep", candidate: "Diverse Echo Empty Park")!
    #expect(tight > loose)
}

@Test func wordStartsOutrankMidWordMatches() {
    let start = FuzzyMatcher.score(query: "hp", candidate: "High Pressure")!
    let mid = FuzzyMatcher.score(query: "hp", candidate: "Shopping")!
    #expect(start > mid)
}

@Test func emptyQueryMatchesEverythingNeutrally() {
    #expect(FuzzyMatcher.score(query: "", candidate: "anything") == 0)
}

@Test func emptyCandidateNeverMatchesNonEmptyQuery() {
    #expect(FuzzyMatcher.score(query: "a", candidate: "") == nil)
}

@Test func realCollectionQueriesResolve() {
    #expect(FuzzyMatcher.score(query: "gigi", candidate: "GiGi FM - Gabriella") != nil)
    #expect(FuzzyMatcher.score(query: "pepe burnt", candidate: "Pepe Bradock - Deep Burnt") != nil)
}

@Test func matchIsFoundEvenWhenTheOpeningLetterAppearsEarlierByChance() {
    // Untagged files fall back to the whole filename, so the real match often sits
    // well past a coincidental occurrence of the first character.
    let hay = "EVIL GRIMACE - Après La Pluie -ALBUM- - 01 Après La Pluie"
    let decoy = "Anticlockwise MIKROTAKT Presence LP"
    #expect(FuzzyMatcher.score(query: "apres", candidate: hay)!
            > FuzzyMatcher.score(query: "apres", candidate: decoy)!)
}

@Test func contiguousRunBeatsCharactersScatteredAcrossWordStarts() {
    let tight = FuzzyMatcher.score(query: "abc", candidate: "abcdef")!
    let scattered = FuzzyMatcher.score(query: "abc", candidate: "alpha bravo charlie")!
    #expect(tight > scattered)
}
