import XCTest
import SwiftUI
import OpenScribeObjC
@testable import OpenScribe

final class ExperienceTests: XCTestCase {
    func testFreshAndIncompleteSetupAlwaysResume() {
        let ready = SetupReadiness(microphone: true, accessibility: true, speechKey: true, pasteEnabled: true)
        XCTAssertTrue(ready.shouldPresent(completed: false))
        XCTAssertFalse(ready.shouldPresent(completed: true))
        XCTAssertTrue(ready.shouldPresent(completed: true, explicitlyRequested: true))
        for missing in [
            SetupReadiness(microphone: false, accessibility: true, speechKey: true, pasteEnabled: true),
            SetupReadiness(microphone: true, accessibility: false, speechKey: true, pasteEnabled: true),
            SetupReadiness(microphone: true, accessibility: true, speechKey: false, pasteEnabled: true)
        ] { XCTAssertTrue(missing.shouldPresent(completed: true)) }
        XCTAssertTrue(SetupReadiness(microphone: true, accessibility: false, speechKey: true, pasteEnabled: false).canDictate)
    }

    func testInterleavedUploadBoundariesBecomeReadablePassagesWithoutLosingSources() {
        let segments = (0..<6).flatMap { index in
            ["microphone", "system"].map { track in
                MeetingSegment(id: "\(track)-\(index)", track: track, start: Double(index * 15), duration: 15, text: "\(track) sentence \(index).")
            }
        }
        let passages = MeetingTranscript.passages(segments.reversed())
        XCTAssertEqual(passages.count, 2)
        XCTAssertEqual(Set(passages.flatMap(\.segmentIDs)), Set(segments.map(\.id)))
        XCTAssertTrue(passages.allSatisfy { $0.segmentIDs.count == 6 })
        XCTAssertEqual(MeetingTranscript.passages(segments, track: "system").count, 1)
    }

    func testPausesSeparatePassagesAndExportUsesSamePresentation() {
        let segments = [
            MeetingSegment(id: "a", track: "microphone", start: 0, duration: 15, text: "First."),
            MeetingSegment(id: "b", track: "microphone", start: 15, duration: 15, text: "Second."),
            MeetingSegment(id: "c", track: "microphone", start: 60, duration: 15, text: "After a pause.")
        ]
        var record = MeetingRecord(title: "Example", settings: AppSettings())
        record.segments = segments
        XCTAssertEqual(MeetingTranscript.passages(segments).count, 2)
        XCTAssertTrue(record.transcript.contains("First. Second."))
        XCTAssertFalse(record.transcript.contains("[00:15]"))
        XCTAssertTrue(record.transcript.contains("[01:00]"))
        XCTAssertEqual(record.segments, segments)
    }

    func testServiceDiagnosticsStayOutOfBubble() {
        XCTAssertEqual(UserNotice.summary("HTTP 401 unauthorized"), "Check your provider key in Settings.")
        XCTAssertEqual(UserNotice.summary("The provider returned an unreadable response."), "That result wasn’t usable. Please try again.")
        XCTAssertEqual(UserNotice.summary("Provider request failed (HTTP 400): internal model details"), "The provider couldn’t complete this request. Please try again.")
        XCTAssertEqual(UserNotice.summary("The recording was too short to transcribe."), "We couldn’t find enough speech. Try recording again.")
        XCTAssertLessThan(UserNotice.summary(String(repeating: "diagnostic ", count: 200)).count, 100)
        XCTAssertEqual(UserNotice.summary("Finish the meeting first."), "Finish the meeting first.")
    }
}

@MainActor
final class ExperienceRenderingTests: XCTestCase {
    func testWorkspaceAndSetupRenderInBothAppearances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-visual-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AppController(rootURL: root)
        var firstNote = controller.store.addNote(rawText: "Um let’s give people a clear next step when a recording needs attention.", cleanedText: "Let’s give people a clear next step when a recording needs attention.", duration: 12, sourceApplication: "Mail")
        firstNote.isPinned = true
        controller.store.updateNote(firstNote)
        controller.store.addNote(rawText: "Pick up oat milk, coffee, and a notebook on the way home.", cleanedText: "Pick up oat milk, coffee, and a notebook on the way home.", duration: 8, sourceApplication: "Notes")
        controller.store.addNote(createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!, rawText: "Make room for writing in the morning.", cleanedText: "Make room for writing in the morning.", duration: 5, sourceApplication: "Safari")
        var manual = controller.store.addManualNote()
        manual.title = "Weekend plans"
        manual.editedText = "A long walk, good coffee, and time to read."
        controller.store.updateNote(manual)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            controller.workspaceSection = .notes
            try render(MainWorkspaceView(controller: controller), name: "workspace-\(name)", scheme: scheme, appearance: appearance, width: 1080, height: 720)
            try render(MainWorkspaceView(controller: controller), name: "workspace-compact-\(name)", scheme: scheme, appearance: appearance, width: 900, height: 620)
            try render(ProviderConnectionEditor(controller: controller, purpose: .speech, onClose: {}), name: "connection-\(name)", scheme: scheme, appearance: appearance, width: 675, height: 552)
            for section in WorkspaceSection.settings {
                controller.workspaceSection = section
                try render(SettingsView(controller: controller, section: section), name: "\(section.rawValue)-\(name)", scheme: scheme, appearance: appearance, width: 672, height: 620)
            }
            try render(OnboardingView(controller: controller), name: "setup-\(name)", scheme: scheme, appearance: appearance, width: 900, height: 620)
            try render(QuickPanelView(controller: controller, close: {}), name: "quick-panel-\(name)", scheme: scheme, appearance: appearance, width: 340, height: 500)
        }
        XCTAssertEqual(controller.notes.count, 3)
        XCTAssertEqual(controller.notes.filter(\.isDailyNote).count, 2)
        XCTAssertTrue(controller.meetings.meetings.isEmpty)
    }

    private func render<Content: View>(_ content: Content, name: String, scheme: ColorScheme, appearance: NSAppearance.Name, width: CGFloat, height: CGFloat) throws {
        let view = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/openscribe-ux-\(name).png"))
        XCTAssertGreaterThan(png.count, 1000)
    }

    func testAudioExceptionsBecomeRecoverableErrors() {
        XCTAssertThrowsError(try ObjCTry.perform {
            NSException(name: .invalidArgumentException, reason: "Invalid microphone format", userInfo: nil).raise()
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid microphone format"))
        }
    }

    func testMeetingReaderRendersWithIsolatedHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MeetingController(store: MeetingStore(root: root))
        var record = MeetingRecord(title: "Product planning", settings: AppSettings())
        record.status = .ready
        record.duration = 45
        record.segments = [
            .init(id: "m0", track: "microphone", start: 0, duration: 15, text: "Let’s simplify the first run."),
            .init(id: "s0", track: "system", start: 0, duration: 15, text: "Agreed. We can guide people through setup."),
            .init(id: "m1", track: "microphone", start: 15, duration: 15, text: "Keep the recording controls easy to find."),
            .init(id: "s1", track: "system", start: 15, duration: 15, text: "Then test the installation with a fresh account.")
        ]
        let view = NSHostingView(rootView: MeetingDetailView(record: record, meetings: controller, onClose: {}).background(FlowTheme.background).environment(\.colorScheme, .light))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 850, height: 700)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/openscribe-meeting-reader.png"))
        XCTAssertGreaterThan(png.count, 1000)
        XCTAssertTrue(controller.meetings.isEmpty)
    }
}
