import XCTest
@testable import LivekeetCore

final class ModelCatalogTests: XCTestCase {
    func testAvailableModelsIncludesDefaultParakeetV2() {
        XCTAssertTrue(ModelCatalog.availableModels.contains { $0.id == "mlx-community/parakeet-tdt-0.6b-v2" })
    }

    func testDescriptorLookupForKnownId() {
        let d = ModelCatalog.descriptor(for: "mlx-community/parakeet-tdt-0.6b-v2")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.backend, .parakeet)
    }

    func testDescriptorLookupForUnknownIdReturnsNil() {
        XCTAssertNil(ModelCatalog.descriptor(for: "acme/custom-model"))
    }

    func testLegacyStoredStringStillResolvesWhenItMatchesACatalogEntry() {
        // Simulates an existing user whose UserDefaults still holds the old default string.
        let stored = "mlx-community/parakeet-tdt-0.6b-v2"
        XCTAssertNotNil(ModelCatalog.descriptor(for: stored))
    }

    func testLegacyStoredStringForCustomValueReturnsNil() {
        // A custom id from a user who typed their own value should not match any descriptor.
        let stored = "my-org/my-custom-stt"
        XCTAssertNil(ModelCatalog.descriptor(for: stored))
    }

    func testAllDescriptorsHaveUniqueIds() {
        let ids = ModelCatalog.availableModels.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
