import Foundation

/// Keep service diagnostics in Details; the transient bubble stays short and actionable.
enum UserNotice {
    static func summary(_ message: String) -> String {
        let value = message.lowercased()
        if value.contains("401") || value.contains("unauthorized") || value.contains("invalid api key") {
            return "Check your provider key in Settings."
        }
        if value.contains("403") || value.contains("forbidden") {
            return "This provider account can’t use that model. Check Settings and try again."
        }
        if value.contains("429") || value.contains("rate limit") {
            return "Provider limit reached. Try again shortly."
        }
        if value.contains("timed out") || value.contains("network") || value.contains("offline") {
            return "Connection interrupted. Check your network and retry."
        }
        if value.contains("unreadable response")
            || value.contains("malformed response")
            || value.contains("couldn’t be decoded")
            || value.contains("could not be decoded")
            || value.contains("invalid json") {
            return "That result wasn’t usable. Please try again."
        }
        if value.contains("no speech") || value.contains("too short") || value.contains("empty transcript") {
            return "We couldn’t find enough speech. Try recording again."
        }
        // Never surface a provider's response body in the transient notice. It can contain
        // implementation details, model output, or language that is meaningless to users.
        if value.contains("provider request failed") || value.contains("http 4") || value.contains("http 5") {
            return "The provider couldn’t complete this request. Please try again."
        }
        if value.contains("disk") || value.contains("no space") {
            return "Couldn’t save. Check available disk space."
        }
        if message.count <= 100 && !message.contains("\n") { return message }
        return "This action couldn’t finish. Open Details for the next step."
    }
}
