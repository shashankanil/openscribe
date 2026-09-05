import XCTest
@testable import OpenScribe

final class TranscriptionRetryTests: XCTestCase {
    func testTransientFailuresRetryAndReturnSuccessfulResult() async throws {
        var attempts = 0
        let result = try await TranscriptionRetry.run(delay: 0) {
            attempts += 1
            if attempts < 3 { throw URLError(.networkConnectionLost) }
            return "Recovered transcript"
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(result, "Recovered transcript")
    }

    func testAuthenticationFailureDoesNotRepeatUpload() async {
        var attempts = 0
        do {
            _ = try await TranscriptionRetry.run(delay: 0) { () -> String in
                attempts += 1
                throw ProviderClient.ClientError.http(status: 401, message: "Invalid key")
            }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(attempts, 1) }
    }

    func testRetryBudgetAndCancellationAreBounded() async {
        var attempts = 0
        do {
            _ = try await TranscriptionRetry.run(delay: 0) { () -> String in
                attempts += 1
                throw ProviderClient.ClientError.http(status: 429, message: "Rate limited")
            }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(attempts, 3) }
        attempts = 0
        do {
            _ = try await TranscriptionRetry.run(delay: 0) { () -> String in
                attempts += 1
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual(attempts, 1) }
    }
}
