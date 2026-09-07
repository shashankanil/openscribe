import Foundation

struct SetupReadiness: Equatable {
    let microphone: Bool
    let accessibility: Bool
    let speechKey: Bool
    let pasteEnabled: Bool
    var canDictate: Bool { microphone && speechKey && (!pasteEnabled || accessibility) }
    func shouldPresent(completed: Bool, explicitlyRequested: Bool = false) -> Bool {
        explicitlyRequested || !completed || !canDictate
    }
}
