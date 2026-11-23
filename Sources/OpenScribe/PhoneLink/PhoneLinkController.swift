import AppKit
import Combine
import Foundation
import SystemConfiguration

/// Where phone press-to-talk goes. `AppController` runs it through the normal dictation pipeline.
@MainActor
protocol PhoneTalkHandler: AnyObject {
    /// Returns an error message when dictation can't start, such as while a meeting is recording.
    func phoneTalkStarted(session: PhoneTalkSession) -> String?
    func phoneTalkAudio(session: PhoneTalkSession, pcm16: Data)
    func phoneTalkEnded(session: PhoneTalkSession)
    func phoneTalkCancelled(session: PhoneTalkSession)
    /// The phone transcribes this talk itself: expect partial text, then the final text, instead of audio.
    func phoneTextTalkStarted(session: PhoneTalkSession) -> String?
    func phoneTalkPartial(session: PhoneTalkSession, text: String)
    func phoneTalkText(session: PhoneTalkSession, text: String)
}

struct PhoneTalkSession: Equatable {
    let id: String
    let connectionID: UUID
    let phoneName: String
}

struct ConnectedPhone: Identifiable, Equatable {
    let id: UUID
    let deviceID: String
    let name: String
    let route: PhoneLinkRoute
}

struct PhoneClipboardEvent: Equatable {
    enum Direction { case toPhone, fromPhone }
    let direction: Direction
    let text: String
    let phone: String
    let date: Date
    var isImage = false
}

/// Phone Link on the Mac: the local-network server, paired phones, clipboard sync and phone press-to-talk.
@MainActor
final class PhoneLinkController: ObservableObject {
    @Published private(set) var serverState: PhoneLinkServer.State = .stopped
    @Published private(set) var phones: [PairedPhone] = []
    @Published private(set) var connected: [ConnectedPhone] = []
    /// The code being shown for a phone to scan, if any.
    @Published private(set) var pairing: PhoneLinkPairing?
    @Published private(set) var lastClipboard: PhoneClipboardEvent?
    @Published private(set) var activeTalk: PhoneTalkSession?
    /// A one-off message for the Mac UI, such as "Paired with Pixel 8".
    var onNotice: ((String) -> Void)?
    weak var talkHandler: PhoneTalkHandler?
    /// The `speech` message for phones: this Mac's transcription connection, or an empty one when phones shouldn't
    /// transcribe themselves. Provided by AppController, which owns settings and keys.
    var speechConfig: (() -> PhoneLinkMessage)?
    private var lastSpeechFingerprint: Data?
    /// OpenScribe Cloud, for the relay and clipboard images. Both need the Mac signed in with Google.
    private weak var cloud: CloudSyncController?
    private var cloudSubscription: AnyCancellable?
    private var relays: [String: PhoneLinkRelay] = [:]

    let store: PhoneLinkStore
    private let bridge = ClipboardBridge()
    private var server: PhoneLinkServer?
    private var connections: [UUID: PhoneLinkConnection] = [:]
    private var enabled = false
    private var sendsMacClipboard = true
    private var acceptsPhoneClipboard = true
    nonisolated let macName: String

    init(root: URL) {
        store = PhoneLinkStore(root: root)
        // Host.current() can block on DNS for seconds; the System Configuration name is instant.
        macName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        phones = store.phones
        bridge.onCopy = { [weak self] text in self?.macCopied(text) }
    }

    // MARK: Relay

    /// One relay socket per phone that has connected before, while Phone Link is on and the Mac is signed in.
    private func updateRelays() {
        let wanted: Set<String> = enabled && cloudAccess != nil ? Set(store.phones.filter(\.hasConnected).map(\.id)) : []
        for (id, relay) in relays where !wanted.contains(id) {
            relay.stop()
            relays[id] = nil
        }
        guard let access = cloudAccess else { return }
        for id in wanted where relays[id] == nil {
            guard let secret = store.secret(for: id),
                  let request = PhoneLinkRelay.request(server: access.server, token: access.token, secret: secret) else { continue }
            let relay = PhoneLinkRelay(deviceID: id, request: request)
            let store = store, macID = store.macID, macName = macName
            relay.onSession = { [weak self, weak relay] transport in
                guard let relay else { return }
                // This room belongs to one phone; only its secret is offered.
                let connection = PhoneLinkConnection(transport: transport, queue: relay.queue, macID: macID, macName: { macName },
                                                     secretFor: { $0 == id ? store.secret(for: $0) : nil })
                (transport as? RelaySessionTransport)?.owner = connection
                connection.onEvent = { [weak self] connection, event in
                    Task { @MainActor in self?.handle(event, from: connection) }
                }
                connection.start()
            }
            relays[id] = relay
            relay.start()
        }
    }

    /// Gives a phone OpenScribe Cloud's address and its own token, or tells it cloud features are off.
    private func sendCloudConfig(to connection: PhoneLinkConnection) {
        guard let deviceID = connection.deviceID else { return }
        guard let access = cloudAccess, let cloud else {
            connection.send(PhoneLinkMessage(t: "cloud"))
            return
        }
        let server = access.server.absoluteString
        Task { @MainActor in
            var token = store.cloudToken(for: deviceID, server: server)
            if token == nil {
                do {
                    let minted = try await cloud.mintPhoneToken(deviceID: deviceID, name: connection.phoneName)
                    store.setCloudToken(minted, for: deviceID, server: server)
                    token = minted
                } catch {
                    NSLog("OpenScribe could not set up OpenScribe Cloud for %@: %@", connection.phoneName, error.localizedDescription)
                    return
                }
            }
            var message = PhoneLinkMessage(t: "cloud")
            message.url = server
            message.token = token
            connection.send(message)
        }
    }

    var isEnabled: Bool { enabled }
    private var cloudAccess: (server: URL, token: String)? { cloud?.linkAccess }
    var cloudAvailable: Bool { cloudAccess != nil }

    func attachCloud(_ cloud: CloudSyncController) {
        self.cloud = cloud
        cloudSubscription = cloud.$account.map { if case .signedIn = $0 { true } else { false } }.removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.cloudAccountChanged() } }
        updateRelays()
    }

    /// Signing in or out changes what phones may use; tell connected phones and start or stop the relays.
    private func cloudAccountChanged() {
        if cloudAccess == nil { store.clearCloudTokens() }
        for connection in connections.values { sendCloudConfig(to: connection) }
        updateRelays()
        updateClipboardWatching()
        objectWillChange.send()
    }
    var port: UInt16? { if case .listening(let port) = serverState { return port } else { return nil } }

    func apply(_ settings: AppSettings) {
        sendsMacClipboard = settings.phoneClipboardToPhone
        acceptsPhoneClipboard = settings.phoneClipboardFromPhone
        if settings.phoneLinkEnabled != enabled {
            enabled = settings.phoneLinkEnabled
            enabled ? startServer() : stopServer()
        }
        updateClipboardWatching()
    }

    private func startServer() {
        let store = store
        let server = PhoneLinkServer(macID: store.macID, macName: { [macName] in macName }, secretFor: { store.secret(for: $0) })
        // A server that was just turned off can still report; only the current one counts.
        server.onState = { [weak self, weak server] state in
            Task { @MainActor in
                guard let self, let server, self.server === server else { return }
                self.serverState = state
            }
        }
        server.onConnectionEvent = { [weak self, weak server] connection, event in
            Task { @MainActor in
                guard let self, let server, self.server === server else { return }
                self.handle(event, from: connection)
            }
        }
        self.server = server
        server.start()
        updateRelays()
    }

    private func stopServer() {
        if let talk = activeTalk { talkHandler?.phoneTalkEnded(session: talk) }
        activeTalk = nil
        server?.stop()
        server = nil
        connections.removeAll()
        connected.removeAll()
        updateRelays()
        cancelPairing()
        serverState = .stopped
        updateClipboardWatching()
    }

    private func updateClipboardWatching() {
        let shouldWatch = enabled && sendsMacClipboard && !connected.isEmpty
        if shouldWatch && !bridge.isWatching { bridge.startWatching() }
        if !shouldWatch && bridge.isWatching { bridge.stopWatching() }
        bridge.onCopyImage = shouldWatch && cloudAccess != nil
            ? { [weak self] data, mime in Task { @MainActor in await self?.sendImage(data, mime: mime) } }
            : nil
    }

    // MARK: Pairing

    /// Shows a QR code for a new phone. Each code has its own secret and works for 10 minutes.
    func beginPairing() {
        guard enabled, let port else { return }
        cancelPairing()
        do {
            let phone = try store.createPendingPhone()
            pairing = PhoneLinkPairing(macID: store.macID, macName: macName, deviceID: phone.id, secret: phone.secret,
                                       hosts: LocalNetwork.ipv4Addresses(), port: port)
            phones = store.phones
        } catch {
            onNotice?("Could not create a pairing code: \(error.localizedDescription)")
        }
    }

    func cancelPairing() {
        if let pairing { store.discardIfUnused(pairing.deviceID) }
        pairing = nil
        phones = store.phones
    }

    func remove(_ phone: PairedPhone) {
        do { try store.remove(phone.id) } catch { onNotice?(error.localizedDescription) }
        server?.disconnect(deviceID: phone.id)
        for connection in connections.values where connection.deviceID == phone.id { connection.cancel() }
        if let cloud, cloudAccess != nil { Task { await cloud.revokePhoneToken(deviceID: phone.id) } }
        phones = store.phones
        updateRelays()
    }

    // MARK: Events

    private func handle(_ event: PhoneLinkConnection.Event, from connection: PhoneLinkConnection) {
        switch event {
        case .ready(let name):
            guard enabled, let deviceID = connection.deviceID else { connection.cancel(); return }
            connections[connection.id] = connection
            connected.removeAll { $0.id == connection.id }
            // A phone reconnecting through the relay replaces its older session.
            for (id, other) in connections where id != connection.id && other.deviceID == deviceID { other.cancel() }
            connected.append(ConnectedPhone(id: connection.id, deviceID: deviceID, name: name, route: connection.route))
            let firstTime = store.phone(deviceID)?.hasConnected == false
            store.markSeen(deviceID, name: name)
            // The same phone paired again: retire its old slot, its sessions and its cloud token.
            if let install = connection.installID {
                for stale in store.claim(deviceID, installID: install) {
                    server?.disconnect(deviceID: stale.id)
                    for other in connections.values where other.deviceID == stale.id { other.cancel() }
                    if stale.cloudToken != nil, let cloud { Task { await cloud.revokePhoneToken(deviceID: stale.id) } }
                }
            }
            phones = store.phones
            if firstTime { updateRelays() }
            sendCloudConfig(to: connection)
            if let speech = speechConfig?() { connection.send(speech) }
            if pairing?.deviceID == deviceID {
                pairing = nil
                onNotice?("Paired with \(name)")
            }
            updateClipboardWatching()
        case .message(let message):
            guard connections[connection.id] != nil else { return }
            handle(message, from: connection)
        case .audio(let data):
            guard let talk = activeTalk, talk.connectionID == connection.id else { return }
            talkHandler?.phoneTalkAudio(session: talk, pcm16: data)
        case .closed:
            guard connections.removeValue(forKey: connection.id) != nil else { return }
            connected.removeAll { $0.id == connection.id }
            if let deviceID = connection.deviceID { store.markSeen(deviceID, name: nil) }
            phones = store.phones
            // Whatever was said before the link dropped is still transcribed.
            if let talk = activeTalk, talk.connectionID == connection.id {
                activeTalk = nil
                talkHandler?.phoneTalkEnded(session: talk)
            }
            updateClipboardWatching()
        }
    }

    private func handle(_ message: PhoneLinkMessage, from connection: PhoneLinkConnection) {
        switch message.t {
        case "clip" where message.kind == "image":
            receiveImage(message, from: connection)
        case "clip":
            guard let text = message.text, !text.isEmpty, text.utf8.count <= PhoneLinkProtocol.maxClipboardBytes else { return }
            var ack = PhoneLinkMessage(t: "clip_ack"); ack.id = message.id
            guard acceptsPhoneClipboard else {
                ack.error = "Clipboard from the phone is turned off on this Mac."
                connection.send(ack)
                return
            }
            bridge.write(text)
            connection.send(ack)
            lastClipboard = PhoneClipboardEvent(direction: .fromPhone, text: text, phone: connection.phoneName, date: Date())
        case "talk_start":
            guard let id = message.id else { return }
            if let current = activeTalk {
                // A newer press from the same phone replaces an abandoned one; another phone has to wait.
                guard current.connectionID == connection.id else {
                    sendTalkState(PhoneTalkSession(id: id, connectionID: connection.id, phoneName: connection.phoneName),
                                  state: "failed", error: "Another phone is dictating.")
                    return
                }
                activeTalk = nil
                talkHandler?.phoneTalkCancelled(session: current)
            }
            if message.mode == "text" {
                let session = PhoneTalkSession(id: id, connectionID: connection.id, phoneName: connection.phoneName)
                activeTalk = session
                let refusal: String? = talkHandler.map { $0.phoneTextTalkStarted(session: session) } ?? "Dictation isn't available."
                if let error = refusal {
                    activeTalk = nil
                    sendTalkState(session, state: "failed", error: error)
                }
                return
            }
            guard message.rate == nil || message.rate == Int(PhoneLinkProtocol.audioSampleRate),
                  message.channels == nil || message.channels == 1,
                  message.format == nil || message.format == "pcm_s16le" else {
                sendTalkState(PhoneTalkSession(id: id, connectionID: connection.id, phoneName: connection.phoneName),
                              state: "failed", error: "Unsupported audio format. Update OpenScribe on the phone.")
                return
            }
            let session = PhoneTalkSession(id: id, connectionID: connection.id, phoneName: connection.phoneName)
            activeTalk = session
            let refusal: String? = talkHandler.map { $0.phoneTalkStarted(session: session) } ?? "Dictation isn't available."
            if let error = refusal {
                activeTalk = nil
                sendTalkState(session, state: "failed", error: error)
            }
        case "talk_partial":
            guard let talk = activeTalk, talk.connectionID == connection.id, talk.id == message.id, let text = message.text else { return }
            talkHandler?.phoneTalkPartial(session: talk, text: String(text.prefix(20_000)))
        case "talk_text":
            guard let talk = activeTalk, talk.connectionID == connection.id, talk.id == message.id else { return }
            activeTalk = nil
            talkHandler?.phoneTalkText(session: talk, text: String((message.text ?? "").prefix(100_000)))
        case "talk_end":
            guard let talk = activeTalk, talk.connectionID == connection.id, talk.id == message.id else { return }
            activeTalk = nil
            talkHandler?.phoneTalkEnded(session: talk)
        case "talk_cancel":
            guard let talk = activeTalk, talk.connectionID == connection.id, talk.id == message.id else { return }
            activeTalk = nil
            talkHandler?.phoneTalkCancelled(session: talk)
        default:
            break // pong, clip_ack and future message types
        }
    }

    /// Re-sends the transcription connection to connected phones when it changed (settings, key, dictionary).
    func refreshSpeechConfig() {
        guard let speech = speechConfig?() else { return }
        let fingerprint = try? PhoneLinkMessage.encode(speech)
        guard fingerprint != lastSpeechFingerprint else { return }
        lastSpeechFingerprint = fingerprint
        for connection in connections.values { connection.send(speech) }
    }

    /// Tells the phone how its dictation is going: recording, transcribing, done, discarded or failed.
    func sendTalkState(_ session: PhoneTalkSession, state: String, text: String? = nil, error: String? = nil,
                       target: String? = nil, pasted: Bool? = nil) {
        guard let connection = connections[session.connectionID] else { return }
        var message = PhoneLinkMessage(t: "talk_state")
        message.id = session.id
        message.state = state
        message.text = text
        message.error = error
        message.target = target
        message.pasted = pasted
        connection.send(message)
    }

    /// The Mac ended a phone dictation itself, such as the dictation shortcut being pressed.
    func talkFinishedOnMac(_ session: PhoneTalkSession) {
        if activeTalk == session { activeTalk = nil }
    }

    enum SendResult: Equatable { case sent(String), tooLarge, noPhone, needsCloud, failed(String) }

    /// Shares an image through OpenScribe Cloud: encrypted with a one-time key, stored in R2 for two days, and
    /// announced to connected phones with the key over the end-to-end encrypted link.
    @discardableResult
    func sendImage(_ data: Data, mime: String) async -> SendResult {
        guard enabled, !connections.isEmpty else { return .noPhone }
        guard let cloud, cloudAccess != nil else { return .needsCloud }
        guard let fitted = ClipboardImage.fit(data, mime: mime) else { return .tooLarge }
        let key = PhoneLinkProtocol.randomBytes(PhoneLinkProtocol.keyLength)
        do {
            let blobID = try await cloud.uploadLinkBlob(try PhoneLinkBlob.seal(fitted.data, key: key))
            var message = PhoneLinkMessage(t: "clip")
            message.id = UUID().uuidString
            message.kind = "image"
            message.mime = fitted.mime
            message.blob = blobID
            message.key = key.base64URLEncoded
            message.size = fitted.data.count
            for connection in connections.values { connection.send(message) }
            let names = connected.map(\.name).joined(separator: ", ")
            lastClipboard = PhoneClipboardEvent(direction: .toPhone, text: "Image", phone: names, date: Date(), isImage: true)
            return .sent(names)
        } catch {
            NSLog("OpenScribe could not share an image: %@", error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    private func receiveImage(_ message: PhoneLinkMessage, from connection: PhoneLinkConnection) {
        var ack = PhoneLinkMessage(t: "clip_ack")
        ack.id = message.id
        guard acceptsPhoneClipboard else {
            ack.error = "Clipboard from the phone is turned off on this Mac."
            connection.send(ack)
            return
        }
        guard let cloud, cloudAccess != nil, let blobID = message.blob,
              let key = message.key.flatMap(Data.init(base64URLEncoded:)), key.count == PhoneLinkProtocol.keyLength else {
            ack.error = "Images need OpenScribe Cloud on this Mac."
            connection.send(ack)
            return
        }
        Task { @MainActor in
            do {
                let image = try PhoneLinkBlob.open(try await cloud.downloadLinkBlob(blobID), key: key)
                guard image.count <= PhoneLinkProtocol.maxImageBytes, let pasteable = ClipboardImage.pasteable(image) else { throw PhoneLinkError.badMessage }
                bridge.writeImage(pasteable.data, mime: pasteable.mime)
                lastClipboard = PhoneClipboardEvent(direction: .fromPhone, text: "Image", phone: connection.phoneName, date: Date(), isImage: true)
            } catch {
                ack.error = "The image couldn't be downloaded: \(error.localizedDescription)"
            }
            connection.send(ack)
        }
    }

    /// Sends text to every connected phone's clipboard on request, whether or not automatic sync is on.
    func sendToPhones(_ text: String) -> SendResult {
        guard enabled, !connections.isEmpty else { return .noPhone }
        guard text.utf8.count <= PhoneLinkProtocol.maxClipboardBytes else { return .tooLarge }
        let names = connected.map(\.name).joined(separator: ", ")
        // Automatic sync may have just sent this same copy; don't put it on the phone twice.
        if let last = lastClipboard, last.direction == .toPhone, last.text == text, Date().timeIntervalSince(last.date) < 3 {
            return .sent(names)
        }
        bridge.noteSent(text)
        var message = PhoneLinkMessage(t: "clip")
        message.id = UUID().uuidString
        message.text = text
        for connection in connections.values { connection.send(message) }
        lastClipboard = PhoneClipboardEvent(direction: .toPhone, text: text, phone: names, date: Date())
        return .sent(names)
    }

    private func macCopied(_ text: String) {
        guard enabled, sendsMacClipboard, !connections.isEmpty else { return }
        var message = PhoneLinkMessage(t: "clip")
        message.id = UUID().uuidString
        message.text = text
        for connection in connections.values { connection.send(message) }
        lastClipboard = PhoneClipboardEvent(direction: .toPhone, text: text,
                                            phone: connected.map(\.name).joined(separator: ", "), date: Date())
    }
}
