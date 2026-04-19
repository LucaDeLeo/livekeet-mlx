import XCTest
@testable import LivekeetCore

final class CorrectorErrorTests: XCTestCase {
    func testNotAvailableHasLocalizedDescription() {
        let err = TranscriptCorrector.CorrectorError.notAvailable("python3 missing")
        XCTAssertEqual(err.errorDescription, "Transcript correction unavailable: python3 missing")
    }

    func testProcessFailedHasLocalizedDescription() {
        let err = TranscriptCorrector.CorrectorError.processFailed("exit 1")
        XCTAssertEqual(err.errorDescription, "Transcript correction failed: exit 1")
    }

    func testDescriptionMatchesErrorDescription() {
        let err = TranscriptCorrector.CorrectorError.notAvailable("x")
        XCTAssertEqual(err.description, err.errorDescription)
    }
}
