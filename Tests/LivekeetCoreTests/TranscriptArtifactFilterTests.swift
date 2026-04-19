import XCTest
@testable import LivekeetCore

final class TranscriptArtifactFilterTests: XCTestCase {
    func testStripsKnownTokens() {
        // Internal whitespace is preserved (we only trim outer); callers never see a double space
        // because the token absorbs its own surrounding space in practice.
        XCTAssertEqual(TranscriptArtifactFilter.clean("hello [BLANK_AUDIO] world"), "hello  world")
    }

    func testCollapsesToEmpty() {
        XCTAssertEqual(TranscriptArtifactFilter.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptArtifactFilter.clean("  [NO_SPEECH]  "), "")
        XCTAssertEqual(TranscriptArtifactFilter.clean("(blank audio)"), "")
    }

    func testStripsAllVariants() {
        let all = "[BLANK_AUDIO] [NO_SPEECH] (blank audio) (no speech) [MUSIC] [APPLAUSE] [LAUGHTER] [SILENCE] <|nospeech|>"
        XCTAssertEqual(TranscriptArtifactFilter.clean(all), "")
    }

    func testPreservesLegitimateBracketedText() {
        // Footnote markers and descriptive brackets not in the set should survive.
        XCTAssertEqual(TranscriptArtifactFilter.clean("see [1] and [inaudible]"), "see [1] and [inaudible]")
    }

    func testTrimsOuterWhitespaceOnly() {
        XCTAssertEqual(TranscriptArtifactFilter.clean("  hello world  "), "hello world")
    }

    func testLeavesCleanTextUnchanged() {
        XCTAssertEqual(TranscriptArtifactFilter.clean("hello world"), "hello world")
    }
}
