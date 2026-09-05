import Foundation

/// Retries transient failures only; cancellation and invalid credentials never start another upload.
enum TranscriptionRetry {
    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? ProviderClient.ClientError, case let .http(status, _) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        return false
    }

    static func run<T>(delay: TimeInterval = 1, operation: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard attempt < 2, isTransient(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * pow(2, Double(attempt)) * 1_000_000_000))
            }
        }
        throw URLError(.unknown)
    }
}
