import AVFoundation
import AppKit
import SwiftUI
import XCTest
@testable import OpenScribe

@MainActor
final class CaptureHubTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-hub-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Shortcuts

    func testLegacyHoldShortcutMovesToPushToTalkWithoutConflicts() throws {
        let legacy = #"{"shortcutKeyCode": 49, "shortcutModifiers": 524288, "shortcutDisplay": "⌥ Space", "dictationMode": "holdToTalk"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.shortcut(for: .holdToTalk), .optionSpace)
        // The default dictate key would collide with the user's existing key, so it stays unset.
        XCTAssertNil(settings.shortcut(for: .dictate))
        XCTAssertNotNil(settings.shortcut(for: .screenshotArea))
    }

    func testLegacyToggleShortcutKeepsItsKeyAndGainsCaptureDefaults() throws {
        let legacy = #"{"shortcutKeyCode": 63, "shortcutModifiers": 8388608, "shortcutDisplay": "Globe", "dictationMode": "toggle"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        // Globe always records while held.
        XCTAssertEqual(settings.shortcut(for: .holdToTalk), .globe)
        XCTAssertEqual(settings.shortcut(for: .dictate), .optionSpace)
        XCTAssertEqual(settings.shortcut(for: .meeting)?.display, "⌥⇧ M")
    }

    func testAssigningATakenShortcutMovesIt() {
        var settings = AppSettings()
        let displaced = settings.assign(.optionSpace, to: .holdToTalk)
        XCTAssertEqual(displaced, .dictate)
        XCTAssertNil(settings.shortcut(for: .dictate))
        XCTAssertEqual(settings.shortcut(for: .holdToTalk), .optionSpace)
        XCTAssertEqual(settings.dictationHint, "⌥ Space")
        XCTAssertEqual(settings.dictationMode, .holdToTalk)
    }

    func testShortcutsRoundTrip() throws {
        var settings = AppSettings()
        settings.assign(KeyShortcut(keyCode: 3, modifiers: [.control, .option]), to: .pasteLast)
        settings.flowbarPlacement = FlowbarPlacement(screen: "Built-in", x: 0.25, y: 0.9)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.shortcuts, settings.shortcuts)
        XCTAssertEqual(restored.shortcut(for: .pasteLast)?.display, "⌃⌥ F")
        XCTAssertEqual(restored.flowbarPlacement, settings.flowbarPlacement)
    }

    // MARK: - Day timeline

    func testMeetingScreenshotsStayInTheDayWhenTheMeetingIsDeleted() throws {
        let store = AppStore(rootURL: root)
        let meetingID = UUID()
        let start = Date()
        store.addCapture(NoteCapture(id: UUID(), createdAt: start, title: "Sync", rawText: "", text: "", duration: 0,
                                     sourceApplication: nil, sourceBundleIdentifier: nil, kind: .meeting, meetingID: meetingID))
        for offset in [120.0, 60.0] {
            store.addCapture(NoteCapture(id: UUID(), createdAt: start.addingTimeInterval(offset), title: "", rawText: "", text: "", duration: 0,
                                         sourceApplication: nil, sourceBundleIdentifier: nil, kind: .screenshot,
                                         attachment: "Shot-\(Int(offset)).png", meetingID: meetingID))
        }
        XCTAssertEqual(store.meetingScreenshots(meetingID).map(\.attachment), ["Shot-60.png", "Shot-120.png"])

        store.removeMeetingEntries(meetingID)
        XCTAssertTrue(store.meetingScreenshots(meetingID).isEmpty)
        let kinds = store.notes.flatMap { $0.captures ?? [] }.map(\.entryKind)
        XCTAssertEqual(kinds, [.screenshot, .screenshot], "Deleting a meeting keeps its screenshots in the day note")
    }

    func testScreenshotsMeetingsAndWrittenEntriesJoinTheDay() throws {
        let store = AppStore(rootURL: root)
        let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let dictationID = UUID()
        store.addNote(id: dictationID, createdAt: morning, rawText: "hello", cleanedText: "Hello.", duration: 2, sourceApplication: "Notes")
        try FileManager.default.createDirectory(at: store.attachmentsURL, withIntermediateDirectories: true)
        let file = "Screenshot-test.png"
        try Data([0x89]).write(to: store.attachmentURL(file))
        let meetingID = UUID()
        store.addCapture(NoteCapture(id: UUID(), createdAt: morning.addingTimeInterval(60), title: "", rawText: "", text: "", duration: 0,
                                     sourceApplication: "Safari", sourceBundleIdentifier: nil, kind: .screenshot, attachment: file,
                                     recognizedText: "Quarterly revenue"))
        store.addCapture(NoteCapture(id: UUID(), createdAt: morning.addingTimeInterval(120), title: "Design sync", rawText: "", text: "",
                                     duration: 0, sourceApplication: nil, sourceBundleIdentifier: nil, kind: .meeting, meetingID: meetingID))

        let restored = AppStore(rootURL: root)
        let day = try XCTUnwrap(restored.dayNote(for: morning))
        XCTAssertEqual(restored.notes.count, 1)
        XCTAssertEqual(day.id, dictationID)
        XCTAssertEqual(day.captures?.map(\.entryKind), [.dictation, .screenshot, .meeting])
        XCTAssertEqual(day.displayText, "Hello.")
        XCTAssertTrue(day.captures?.contains { $0.matches("revenue") } == true)
        XCTAssertEqual(EntryCounts(day).summary, "1 dictation · 1 meeting · 1 screenshot")

        restored.removeMeetingEntries(meetingID)
        XCTAssertEqual(restored.dayNote(for: morning)?.captures?.count, 2)
        let screenshot = try XCTUnwrap(restored.dayNote(for: morning)?.captures?.first { $0.entryKind == .screenshot })
        restored.removeCapture(screenshot.id, from: day.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.attachmentURL(file).path), "Removing a screenshot deletes its file")
    }

    func testEditingOneEntryKeepsTheOthers() throws {
        let store = AppStore(rootURL: root)
        let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        store.addNote(createdAt: morning, rawText: "one", cleanedText: "One.", duration: 1)
        let day = store.addNote(createdAt: morning.addingTimeInterval(30), rawText: "two", cleanedText: "Two.", duration: 1)
        var first = try XCTUnwrap(day.captures?.first)
        first.text = "One, edited."
        XCTAssertTrue(store.updateCapture(first, in: day.id))
        let restored = try XCTUnwrap(AppStore(rootURL: root).dayNote(for: morning))
        XCTAssertEqual(restored.displayText, "One, edited.\n\nTwo.")
        XCTAssertEqual(restored.captures?.first?.rawText, "one")
    }

    func testDeletingTheLastEntryRemovesTheEmptyDay() throws {
        let store = AppStore(rootURL: root)
        let day = store.addNote(rawText: "only", cleanedText: "", duration: 1)
        store.removeCapture(try XCTUnwrap(day.captures?.first?.id), from: day.id)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testDayExportSkipsReplacedDictations() {
        var note = VoiceNote(title: "", rawText: "", cleanedText: "", duration: 0)
        note.captures = []
        note.appendCaptures([NoteCapture(id: UUID(), createdAt: Date(), title: "", rawText: "raw", text: "Original.", duration: 1,
                                         sourceApplication: nil, sourceBundleIdentifier: nil)])
        note.editedText = "Rewritten."
        let migrated = note.migratedToTimeline()
        let markdown = DayNoteExport.markdown(migrated)
        XCTAssertTrue(markdown.contains("Rewritten."))
        XCTAssertFalse(markdown.contains("Original."))
        XCTAssertEqual(migrated.visibleCaptures.first?.rawText, "raw", "The written entry can still show the original transcript")
    }

    // MARK: - Dictation

    func testFinishingDoesNotWaitOutTheIdlePoll() async throws {
        let live = DictationLiveTranscriber(store: DictationRecoveryStore(root: root)) { _, _ in "" }
        live.start(UUID())
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        await live.finish()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "Stopping should not sit through the one-second section poll")
    }

    // MARK: - Flowbar

    func testActiveFlowbarStatesStayLineOnly() {
        // Active states are compact: no buttons, just the line (meetings add a stop button).
        for mode in [FlowbarMode.dictating, .processing("Transcribing"), .meetingSaving] {
            XCTAssertLessThanOrEqual(mode.width, 100)
        }
        XCTAssertLessThanOrEqual(FlowbarMode.meeting(paused: false).width, 130)
        // Idle is the smallest, thinnest state: a sliver that almost disappears.
        for mode in [FlowbarMode.idleExpanded, .dictating, .confirmation("Saved"), .meeting(paused: false)] {
            XCTAssertLessThan(FlowbarMode.idle.width, mode.width)
            XCTAssertLessThan(FlowbarMode.idle.height, mode.height)
        }
        XCTAssertGreaterThanOrEqual(FlowbarLayout.maxWidth, [FlowbarMode.idle, .idleExpanded, .dictating, .meeting(paused: true), .meeting(paused: false, expanded: true)].map(\.width).max()!)
        // Hovering a meeting reveals notes and screenshot buttons.
        XCTAssertGreaterThan(FlowbarMode.meeting(paused: false, expanded: true).width, FlowbarMode.meeting(paused: false).width)
    }

    func testLiveSquiggleGrowsWithTheVoiceAndMeetsTheMidline() {
        let size = CGSize(width: 60, height: 20)
        let quiet = FlowSquiggle.path(in: size, phase: 1.234, level: 0).boundingRect
        let loud = FlowSquiggle.path(in: size, phase: 1.234, level: 1).boundingRect
        XCTAssertGreaterThan(loud.height, quiet.height * 2)
        XCTAssertGreaterThan(quiet.height, 1, "Silence still shows a gentle wave")
        XCTAssertLessThanOrEqual(loud.maxY, size.height)
        XCTAssertGreaterThanOrEqual(loud.minY, 0)
    }

    func testVoiceFollowerRisesFastSettlesSlowlyAndRipples() {
        let follower = VoiceFollower()
        var time = 0.0
        follower.step(to: 0, at: time)
        for _ in 0..<3 { time += 1 / 60; follower.step(to: 0.6, at: time) }
        XCTAssertGreaterThan(follower.level(delay: 0), 0.6, "Speech reaches the line within a few frames")
        XCTAssertLessThan(follower.level(delay: 0.04), follower.level(delay: 0), "The ends still show the moment before")
        let phase = follower.phase
        for _ in 0..<3 { time += 1 / 60; follower.step(to: 0, at: time) }
        XCTAssertGreaterThan(follower.level(delay: 0), 0.4, "Falling silent eases off instead of snapping flat")
        XCTAssertGreaterThan(follower.phase, phase)
    }

    func testRenderFlowbarStates() throws {
        let states: [(String, AnyView)] = [
            ("idle", AnyView(pill(FlowbarMode.idle.width, height: FlowbarMode.idle.height, padding: 6, fill: 0.28) { Color.clear })),
            ("listening-quiet", AnyView(pill(88) { liveSquiggle(level: 0.05) })),
            ("listening-loud", AnyView(pill(88) { liveSquiggle(level: 0.8) })),
            ("listening-syllable", AnyView(pill(88) { rippleSquiggle() })),
            ("transcribing-a", AnyView(pill(88) { traceFrame(0.2) })),
            ("transcribing-b", AnyView(pill(88) { traceFrame(0.55) })),
            ("transcribing-c", AnyView(pill(88) { traceFrame(0.9) })),
            ("meeting", AnyView(pill(FlowbarMode.meeting(paused: false).width) { meetingContent() })),
            ("meeting-vertical", AnyView(pill(FlowbarMode.meeting(paused: false).width) { meetingContent() }
                .rotationEffect(.degrees(90)).frame(width: 32, height: FlowbarMode.meeting(paused: false).width))),
        ]
        for (name, view) in states {
            let host = NSHostingView(rootView: view.padding(10).background(Color(white: 0.85)))
            host.frame = name.hasSuffix("vertical") ? NSRect(x: 0, y: 0, width: 52, height: 140) : NSRect(x: 0, y: 0, width: 140, height: 52)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/openscribe-flowbar-\(name).png"))
            XCTAssertGreaterThan(png.count, 500)
        }
    }

    /// A frozen frame of the live line, so previews are deterministic.
    private func liveSquiggle(level: CGFloat) -> some View {
        Canvas { graphics, size in
            graphics.stroke(FlowSquiggle.path(in: size, phase: 0.4, level: level), with: .color(FlowbarLayout.cream),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }.frame(height: 20)
    }

    /// A syllable that has just peaked at the center while the ends still show the quieter moment before.
    private func rippleSquiggle() -> some View {
        Canvas { graphics, size in
            let path = FlowSquiggle.path(in: size, phase: 0.4) { delay in max(0.15, 0.9 - CGFloat(delay) * 2.6) }
            graphics.stroke(path, with: .color(FlowbarLayout.cream), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }.frame(height: 20)
    }

    private func traceFrame(_ time: TimeInterval) -> some View {
        Canvas { graphics, size in
            FlowSquiggle.trace(in: &graphics, size: size, time: time, color: FlowbarLayout.amber, lineWidth: 2)
        }.frame(height: 16)
    }

    private func meetingContent() -> some View {
        HStack(spacing: 6) {
            liveSquiggle(level: 0.5).frame(height: 18)
            RoundedRectangle(cornerRadius: 2).fill(FlowbarLayout.red).frame(width: 7, height: 7)
                .frame(width: 20, height: 20).background(FlowbarLayout.red.opacity(0.16), in: Circle())
        }
    }

    private func pill<Content: View>(_ width: CGFloat, height: CGFloat = FlowbarLayout.pillHeight, padding: CGFloat = 11, fill: Double = 1,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        HStack { content() }
            .padding(.horizontal, padding)
            .frame(width: width, height: height)
            .background(Capsule().fill(FlowbarLayout.ink.opacity(fill)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

@MainActor
final class SpeechUploadTests: XCTestCase {
    func testRecordingsShrinkToSixteenKilohertzBeforeUpload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-48k-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 2)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.05) * 0.3) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let compact = try XCTUnwrap(SpeechUpload.compact(url))
        defer { try? FileManager.default.removeItem(at: compact) }
        let converted = try AVAudioFile(forReading: compact)
        XCTAssertEqual(converted.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(converted.length) / 16_000, 2, accuracy: 0.05, "Duration is preserved")
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: compact.path)[.size] as? Int)
        XCTAssertLessThan(after * 5, before, "Upload is several times smaller")
        XCTAssertNil(SpeechUpload.compact(compact), "Already-compact files are sent as is")
    }
}
