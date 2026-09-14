import XCTest
@testable import WhisperFlow

final class RecognitionDeadlinePolicyTests: XCTestCase {
    func testSlowAndLongDictationsReceiveMoreThanThirtySeconds() {
        XCTAssertEqual(RecognitionDeadlinePolicy.budget(audioDuration: 10), .seconds(320))
        XCTAssertEqual(RecognitionDeadlinePolicy.budget(audioDuration: 180), .seconds(660))
        XCTAssertEqual(RecognitionDeadlinePolicy.budget(audioDuration: nil), .seconds(300))
    }

    func testInvalidMetadataCannotRemoveStallProtection() {
        XCTAssertEqual(RecognitionDeadlinePolicy.budget(audioDuration: .infinity), .seconds(300))
        XCTAssertEqual(RecognitionDeadlinePolicy.budget(audioDuration: -100), .seconds(300))
        XCTAssertEqual(RecognitionDeadlinePolicy.budget(audioDuration: 100_000), .seconds(900))
    }
}
