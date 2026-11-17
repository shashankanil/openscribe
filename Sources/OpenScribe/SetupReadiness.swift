import Foundation

/// What OpenScribe needs, split into what dictation requires (microphone and a speech key) and what
/// only widens where the words go (Accessibility, for pasting into other apps and event-tap shortcuts).
struct SetupReadiness: Equatable {
    enum Requirement: Equatable { case microphone, speechKey }

    let microphone: Bool
    let accessibility: Bool
    let speechKey: Bool
    let pasteEnabled: Bool

    /// Dictation works: it records and transcribes. Without Accessibility the text goes to Notes.
    var canDictate: Bool { microphone && speechKey }
    /// Text can be typed into the focused app.
    var canPasteAnywhere: Bool { accessibility }
    /// Paste into other apps is switched on, but macOS isn't allowing it, so dictations land in Notes.
    var pasteBlocked: Bool { pasteEnabled && !accessibility }
    /// The first thing dictation still needs, in the order setup asks for it.
    var missingRequirement: Requirement? {
        if !microphone { return .microphone }
        if !speechKey { return .speechKey }
        return nil
    }

    /// Onboarding appears on launch only until it has been completed once. Anything that goes missing
    /// afterwards is shown as a banner and a notice instead of the full flow.
    func shouldPresent(completed: Bool, explicitlyRequested: Bool = false) -> Bool {
        explicitlyRequested || !completed
    }
}
