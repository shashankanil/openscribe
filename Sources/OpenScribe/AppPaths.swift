import Foundation

/// Debug builds can exercise first launch without reading or changing the user's profile.
enum AppPaths {
    static var root: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["OPENSCRIBE_TEST_PROFILE"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("WhisperFlow", isDirectory: true)
    }
}
