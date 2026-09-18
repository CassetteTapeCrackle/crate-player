import Foundation
import Testing
@testable import CrateCore

@Test func numbersSortNumericallyNotLexically() {
    #expect(naturalLess("track 2.mp3", "track 10.mp3"))
    #expect(!naturalLess("track 10.mp3", "track 2.mp3"))
}

@Test func accentedNamesSortSensibly() {
    #expect(naturalLess("Apres La Pluie.wav", "Zulu.wav"))
    #expect(naturalLess("Après La Pluie.wav", "Zulu.wav"))
}

@Test func caseIsIgnored() {
    #expect(naturalLess("apple.mp3", "Banana.mp3"))
}

@Test func trackExposesFilenameWithoutExtension() {
    let t = Track(url: URL(fileURLWithPath: "/m/TechNO!/Hypnotic/Cult - High Pressure.mp3"))
    #expect(t.filename == "Cult - High Pressure")
    #expect(t.folderURL.lastPathComponent == "Hypnotic")
}

@Test func loopModeCyclesOffFolderTrack() {
    #expect(LoopMode.off.next == .folder)
    #expect(LoopMode.folder.next == .track)
    #expect(LoopMode.track.next == .off)
}
