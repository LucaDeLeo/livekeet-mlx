import XCTest
@testable import LivekeetCore

final class CorrectionPromptBuilderTests: XCTestCase {
    private func seg(_ text: String, time: String = "00:00:01", speaker: String = "Me") -> TranscriptSegment {
        TranscriptSegment(
            offsetSeconds: 0,
            text: text,
            channel: "mic",
            timestamp: time,
            startTime: Date(timeIntervalSince1970: 0),
            speakerIndex: 0,
            speaker: speaker
        )
    }

    func testDefaultPromptStartsWithInstruction() {
        let builder = CorrectionPromptBuilder()
        let out = builder.build(segments: [seg("hello")], context: [], speakers: [])
        XCTAssertTrue(out.hasPrefix("Fix obvious speech-to-text errors"))
    }

    func testBasePromptIsRespected() {
        let builder = CorrectionPromptBuilder(basePrompt: "CUSTOM BASE")
        let out = builder.build(segments: [seg("a")], context: [], speakers: [])
        XCTAssertTrue(out.hasPrefix("CUSTOM BASE"))
    }

    func testSpeakersBlockOmittedWhenEmpty() {
        let builder = CorrectionPromptBuilder()
        let out = builder.build(segments: [seg("a")], context: [], speakers: [])
        XCTAssertFalse(out.contains("Speakers in this conversation"))
    }

    func testSpeakersBlockIncludedWhenPresent() {
        let builder = CorrectionPromptBuilder()
        let out = builder.build(segments: [seg("a")], context: [], speakers: ["Luca", "Luke"])
        XCTAssertTrue(out.contains("Speakers in this conversation: Luca, Luke"))
    }

    func testContextBlockOmittedWhenEmpty() {
        let builder = CorrectionPromptBuilder()
        let out = builder.build(segments: [seg("a")], context: [], speakers: [])
        XCTAssertFalse(out.contains("Recent context"))
    }

    func testContextBlockIncludedWhenPresent() {
        let builder = CorrectionPromptBuilder()
        let out = builder.build(
            segments: [seg("current")],
            context: [seg("prior", time: "00:00:00", speaker: "Me")],
            speakers: []
        )
        XCTAssertTrue(out.contains("Recent context"))
        XCTAssertTrue(out.contains("[00:00:00] Me: prior"))
    }

    func testSegmentsRenderedWithIndex() {
        let builder = CorrectionPromptBuilder()
        let out = builder.build(
            segments: [seg("first"), seg("second", time: "00:00:02")],
            context: [],
            speakers: []
        )
        XCTAssertTrue(out.contains("0: [00:00:01] Me: \"first\""))
        XCTAssertTrue(out.contains("1: [00:00:02] Me: \"second\""))
    }

    func testDefaultModelMatchesExpectedConstant() {
        XCTAssertEqual(CorrectionPromptBuilder.defaultModel, "claude-haiku-4-5-20251001")
    }
}
