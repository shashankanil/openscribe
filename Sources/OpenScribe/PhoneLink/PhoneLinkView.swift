import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings → Phone: pair the Android app, then use it as a press-to-talk microphone and share the clipboard.
struct PhoneLinkView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var link: PhoneLinkController
    @State private var removing: PairedPhone?
    @State private var showingDownload = false

    private var enabled: Bool { controller.settings.phoneLinkEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                connectionSection
                if enabled { phonesSection }
                talkingSection
                cloudSection
                clipboardSection
                Text("Phone Link works on your local network only. Each phone has its own key, and audio and clipboard text are encrypted between the phone and this Mac. Transcription uses this Mac’s providers, so the phone needs no API keys.")
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { link.pairing != nil }, set: { if !$0 { link.cancelPairing() } })) {
            if let pairing = link.pairing { PairingSheet(pairing: pairing) { link.cancelPairing() } }
        }
        .sheet(isPresented: $showingDownload) { AndroidDownloadSheet { showingDownload = false } }
        .alert("Remove \(removing?.name ?? "phone")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { link.remove(removing) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The phone disconnects and can’t reconnect until you pair it again.")
        }
    }

    private var connectionSection: some View {
        FlowSettingsGroup(title: "Phone Link", footer: "Install OpenScribe on your Android phone, then pair it here. Hold the talk button on the phone to dictate into the app that’s focused on this Mac.") {
            FlowSettingsRow(title: "Get the Android app", detail: "Scan a code with your phone’s camera to download the latest OpenScribe for Android.",
                            symbol: "arrow.down.app") {
                Button("Download for Android…") { showingDownload = true }.buttonStyle(.flowSecondary)
            }
            FlowRowDivider()
            FlowSettingsRow(title: "Allow phones on this network", detail: statusDetail, symbol: "smartphone") {
                statusBadge
                Toggle("Allow phones on this network", isOn: Binding(get: { enabled }, set: { value in
                    controller.updateSettings { $0.phoneLinkEnabled = value }
                })).labelsHidden().toggleStyle(.switch)
            }
            if enabled {
                FlowRowDivider()
                FlowSettingsRow(title: "Pair a phone", detail: "Shows a code to scan with the OpenScribe app. It works once, for 10 minutes.", symbol: "qrcode") {
                    Button("Pair a phone…") { link.beginPairing() }
                        .buttonStyle(.flowPrimary).disabled(link.port == nil)
                }
            }
        }
    }

    private var statusDetail: String {
        switch link.serverState {
        case .stopped: return "Off. Phones can’t connect."
        case .starting: return "Starting…"
        case .listening(let port):
            let addresses = LocalNetwork.ipv4Addresses()
            return "Listening on \(addresses.first.map { "\($0):" } ?? "port ")\(port)"
        case .failed(let message): return "Couldn’t start: \(message)"
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if let talk = link.activeTalk {
            FlowBadge(text: "\(talk.phoneName) is talking", color: FlowTheme.recording, pulsing: true)
        } else if !link.connected.isEmpty {
            FlowBadge(text: link.connected.count == 1 ? "1 phone connected" : "\(link.connected.count) phones connected", color: FlowTheme.success)
        } else if case .failed = link.serverState {
            FlowBadge(text: "Error", color: FlowTheme.warning)
        }
    }

    private var phonesSection: some View {
        let paired = link.phones.filter(\.hasConnected)
        return FlowSettingsGroup(title: "Paired phones", footer: paired.isEmpty ? "No phones yet." : nil) {
            ForEach(Array(paired.enumerated()), id: \.element.id) { index, phone in
                if index > 0 { FlowRowDivider() }
                let session = link.connected.first { $0.deviceID == phone.id }
                FlowSettingsRow(title: phone.name, detail: session.map { $0.route == .cloud ? "Connected through OpenScribe Cloud" : "Connected on this network" } ?? lastSeen(phone),
                                symbol: "smartphone") {
                    if session != nil { FlowBadge(text: "Online", color: FlowTheme.success) }
                    Button("Remove…") { removing = phone }.buttonStyle(.flow(.secondary, size: .small))
                }
            }
        }
    }

    private var talkingSection: some View {
        let settings = controller.settings
        let streams = settings.automaticStreaming && StreamingCapability.resolve(settings) != nil
        return FlowSettingsGroup(title: "Talking from the phone", footer: settings.phoneTranscribesLocally
            ? "Only your transcription key is shared, over the encrypted link, with paired phones. It’s deleted from a phone when you remove it or turn this off. Cleanup, your dictionary and pasting still happen on this Mac."
            : "The phone sends audio and this Mac transcribes it.") {
            FlowSettingsRow(title: "Transcribe on the phone",
                            detail: streams
                                ? "Faster: the phone streams to \(settings.speechProvider.title) as you speak and sends this Mac text."
                                : "Faster: the phone transcribes as you pause, with \(settings.speechProvider.title), and sends this Mac text.",
                            symbol: "waveform.badge.mic") {
                toggle("Transcribe on the phone", \.phoneTranscribesLocally)
            }
        }
    }

    private var cloudSection: some View {
        FlowSettingsGroup(title: "Away from home", footer: "Uses OpenScribe Cloud. Audio and clipboard text stay end-to-end encrypted, so the server only passes them along. Images are encrypted before upload and deleted after 2 days.") {
            if link.cloudAvailable {
                FlowSettingsRow(title: "Connect from anywhere, and share images",
                                detail: "When a phone isn’t on this network, it connects through OpenScribe Cloud. Copied images go both ways.",
                                symbol: "icloud") {
                    FlowBadge(text: "On", color: FlowTheme.success)
                }
            } else {
                FlowSettingsRow(title: "Connect from anywhere, and share images",
                                detail: "Sign in to OpenScribe Cloud with Google to use your phone away from this network and copy images between them.",
                                symbol: "icloud") {
                    Button("Sign in…") { controller.open(.ai) }.buttonStyle(.flow(.secondary, size: .small))
                }
            }
        }
    }

    private func lastSeen(_ phone: PairedPhone) -> String {
        guard let date = phone.lastSeen else { return "Never connected" }
        return "Last seen \(date.formatted(.relative(presentation: .named)))"
    }

    private var clipboardSection: some View {
        FlowSettingsGroup(title: "Clipboard", footer: clipboardFooter) {
            FlowSettingsRow(title: "Send Mac copies to the phone", detail: "Text you copy here appears on the phone’s clipboard while it’s connected. Passwords from password managers are never sent.",
                            symbol: "arrow.up.forward.app") {
                toggle("Send Mac copies to the phone", \.phoneClipboardToPhone)
            }
            FlowRowDivider()
            FlowSettingsRow(title: "Send to phone shortcut", detail: "Puts the selected text, or what you last copied, on the phone’s clipboard. Works even with automatic sending off.",
                            symbol: "iphone.and.arrow.forward") {
                if let shortcut = controller.settings.shortcut(for: .sendToPhone) {
                    FlowKeycaps(shortcut: shortcut.display)
                }
                Button(controller.settings.shortcut(for: .sendToPhone) == nil ? "Set shortcut…" : "Change…") { controller.open(.shortcuts) }
                    .buttonStyle(.flow(.secondary, size: .small))
            }
            FlowRowDivider()
            FlowSettingsRow(title: "Accept text from the phone", detail: "Use Send clipboard, the Quick Settings tile or Share on the phone.",
                            symbol: "arrow.down.backward.square") {
                toggle("Accept text from the phone", \.phoneClipboardFromPhone)
            }
        }
    }

    private var clipboardFooter: String? {
        guard let event = link.lastClipboard else { return nil }
        let direction = event.direction == .toPhone ? "Sent to \(event.phone)" : "Received from \(event.phone)"
        let when = event.date.formatted(.relative(presentation: .named))
        if event.isImage { return "\(direction) \(when): an image" }
        let preview = event.text.replacingOccurrences(of: "\n", with: " ").prefix(60)
        return "\(direction) \(when): “\(preview)\(event.text.count > 60 ? "…" : "")”"
    }

    private func toggle(_ label: String, _ key: WritableKeyPath<AppSettings, Bool>) -> some View {
        Toggle(label, isOn: Binding(get: { controller.settings[keyPath: key] }, set: { value in
            controller.updateSettings { $0[keyPath: key] = value }
        }))
        .labelsHidden().toggleStyle(.switch).disabled(!enabled)
    }
}

struct PairingSheet: View {
    let pairing: PhoneLinkPairing
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan with OpenScribe on your phone").font(.system(size: 17, weight: .semibold))
            Text("Open the OpenScribe app and tap Scan. Keep the phone on the same Wi-Fi as this Mac.")
                .font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let image = Self.qrImage(pairing.url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 240, height: 240)
                    .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the phone…").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
            }
            Link("No OpenScribe on your phone yet? Download it first.", destination: PhoneLinkProtocol.androidDownloadURL)
                .font(.system(size: 11.5)).foregroundStyle(FlowTheme.accent)
            HStack {
                Button("Copy link") { copySecretly(pairing.url.absoluteString) }.buttonStyle(.flowSecondary)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.flowSecondary).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 360)
    }

    /// The link holds the pairing secret: mark it concealed so clipboard managers and Phone Link never share it.
    private func copySecretly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    nonisolated static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// A QR code for the Android download: point the phone's camera at it and open the link.
private struct AndroidDownloadSheet: View {
    let onClose: () -> Void
    private let url = PhoneLinkProtocol.androidDownloadURL

    var body: some View {
        VStack(spacing: 16) {
            Text("Get OpenScribe for Android").font(.system(size: 17, weight: .semibold))
            Text("Open the camera on your phone, point it at this code, and tap the link. When the download finishes, open it and allow installing from your browser if Android asks.")
                .font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let image = PairingSheet.qrImage(url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                    .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("QR code for the Android download")
            }
            Text("Android 10 or later. After installing, come back and choose Pair a phone.")
                .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint).multilineTextAlignment(.center)
            HStack {
                Button("Copy link") { FlowFormat.copy(url.absoluteString) }.buttonStyle(.flowSecondary)
                Spacer()
                Button("Done", action: onClose).buttonStyle(.flowPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 360)
    }
}

