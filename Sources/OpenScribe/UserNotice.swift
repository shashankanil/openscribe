import Foundation

/// Keep service diagnostics in Details; the transient bubble stays short and actionable.
enum UserNotice {
    static func summary(_ message: String) -> String {
        let value = message.lowercased()
        if value.contains("401") || value.contains("unauthorized") || value.contains("invalid api key") {
            return "Check your provider key in Settings."
        }
        if value.contains("429") || value.contains("rate limit") {
            return "Provider limit reached. Try again shortly."
        }
        if value.contains("timed out") || value.contains("network") || value.contains("offline") {
            return "Connection interrupted. Check your network and retry."
        }
        if value.contains("disk") || value.contains("no space") {
            return "Couldn’t save. Check available disk space."
        }
        if message.count <= 100 && !message.contains("\n") { return message }
        return "This action couldn’t finish. Open Details for the next step."
    }
}
