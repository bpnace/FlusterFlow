import XCTest

final class TestResourceLoaderTests: XCTestCase {
    func testProductionSourcesResolveToTheLiveCheckout() throws {
        let expected = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WhisperFlow/App/AppEnvironment.swift")
            .standardizedFileURL

        XCTAssertEqual(
            try TestResourceLoader.url("WhisperFlow/App/AppEnvironment.swift"),
            expected
        )
    }
}
