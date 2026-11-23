import AVFoundation
import AppKit
import CryptoKit
import Network
import XCTest
@testable import OpenScribe

/// Test vectors from docs/PHONE-LINK.md. The Android app's LinkProtocolTest checks the same values.
final class PhoneLinkProtocolTests: XCTestCase {
    private let secret = Data((0..<32).map { UInt8($0) })
    private let clientNonce = Data((0xa0...0xaf).map { UInt8($0) })
    private let serverNonce = Data((0xb0...0xbf).map { UInt8($0) })

    private func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.hexString }
    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    func testSessionKeysMatchVectors() {
        let keys = PhoneLinkProtocol.sessionKeys(secret: secret, clientNonce: clientNonce, serverNonce: serverNonce)
        XCTAssertEqual(hex(keys.clientToServer), "03348d6f70f8ac9aa1cabad86367f4513517ea375d87f445506a9f72adcf897a")
        XCTAssertEqual(hex(keys.serverToClient), "c26ac681a4d44217865e142797c7bec66db24e28eb283edb1734c3ae494e044a")
    }

    func testSealedFramesMatchVectors() throws {
        let keys = PhoneLinkProtocol.sessionKeys(secret: secret, clientNonce: clientNonce, serverNonce: serverNonce)
        var client = PhoneLinkCipher(key: keys.clientToServer)
        XCTAssertEqual(try client.seal(bytes("017b226e616d65223a22546573742070686f6e65222c2274223a2261757468227d")).hexString,
                       "130a6599aacb5a2112c773c03028fb014c39d3289266edd3165c912a0c1a3a8c37a7ffc05cac9e93d4ff4dbdf5626fb830")
        XCTAssertEqual(try client.seal(bytes("020100ff7f")).hexString, "9b06155de0a93a3f92c811102f32a12e76c964c754")
        var server = PhoneLinkCipher(key: keys.serverToClient)
        XCTAssertEqual(try server.seal(bytes("017b226e616d65223a2254657374204d6163222c2274223a227265616479227d")).hexString,
                       "ae4f24953ac956e25b733ca49a608eb9ac704713e8495e604f14afd8146d7142901306fecae8f98b42b4d5d2f7bc6f94")
    }

    func testRelayRoomAndBlobMatchVectors() throws {
        XCTAssertEqual(PhoneLinkProtocol.relayRoom(secret: secret), "14da9ca9ec019835c941f773b307b562")
        let key = Data((0x40...0x5f).map { UInt8($0) })
        let blob = try PhoneLinkBlob.seal(Data("OpenScribe image".utf8), key: key, nonce: Data((0x60...0x6b).map { UInt8($0) }))
        XCTAssertEqual(blob.hexString, "606162636465666768696a6be3586c6b54f7e2cf6be4595f68e73b6e85f8f610058025c8643d673817bb9316")
        XCTAssertEqual(try PhoneLinkBlob.open(blob, key: key), Data("OpenScribe image".utf8))
        var tampered = blob
        tampered[20] ^= 1
        XCTAssertThrowsError(try PhoneLinkBlob.open(tampered, key: key))
    }

    func testOpeningRejectsTamperingReplayAndReordering() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = PhoneLinkCipher(key: key)
        let first = try sender.seal(Data("one".utf8))
        let second = try sender.seal(Data("two".utf8))
        XCTAssertEqual(first.startIndex, 0)

        var outOfOrder = PhoneLinkCipher(key: key)
        XCTAssertThrowsError(try outOfOrder.open(second))

        var receiver = PhoneLinkCipher(key: key)
        var tampered = first
        tampered[0] ^= 1
        XCTAssertThrowsError(try receiver.open(tampered))
        XCTAssertEqual(try receiver.open(first), Data("one".utf8))
        XCTAssertThrowsError(try receiver.open(first), "A replayed frame must not open")
        XCTAssertEqual(try receiver.open(second), Data("two".utf8))
    }

    func testFramingSplitsPartialAndMultipleFrames() throws {
        var stream = PhoneLinkProtocol.frame(Data("hello".utf8)) + PhoneLinkProtocol.frame(Data()) + PhoneLinkProtocol.frame(Data("wor".utf8))
        var buffer = Data(stream.prefix(7))
        stream.removeFirst(7)
        XCTAssertEqual(try PhoneLinkProtocol.takeFrames(from: &buffer), [])
        buffer.append(stream)
        let frames = try PhoneLinkProtocol.takeFrames(from: &buffer)
        XCTAssertEqual(frames, [Data("hello".utf8), Data(), Data("wor".utf8)])
        XCTAssertEqual(frames.map(\.startIndex), [0, 0, 0])
        XCTAssertTrue(buffer.isEmpty)

        var huge = Data([0x7f, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try PhoneLinkProtocol.takeFrames(from: &huge))
    }

    func testPairingLinkMatchesVectorAndRoundTrips() throws {
        let pairing = PhoneLinkPairing(macID: "M1", macName: "Test Mac", deviceID: "D1", secret: secret,
                                       hosts: ["192.168.1.5", "10.0.0.2"], port: 47_689)
        XCTAssertEqual(pairing.url.absoluteString,
                       "openscribe://link?v=1&mac=M1&name=Test%20Mac&device=D1&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&h=192.168.1.5,10.0.0.2&p=47689")
        XCTAssertEqual(PhoneLinkPairing(url: pairing.url), pairing)
        XCTAssertNil(PhoneLinkPairing(url: URL(string: "openscribe://link?v=2&mac=M1&device=D1&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&p=1")!))
        XCTAssertNil(PhoneLinkPairing(url: URL(string: "openscribe://link?v=1&mac=M1&device=D1&k=AAEC&p=1")!), "A short secret is rejected")
    }

    func testStoreExpiresUnusedPairingCodesButKeepsPairedPhones() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PhoneLinkStore(root: root)
        let unused = try store.createPendingPhone(now: start)
        let used = try store.createPendingPhone(now: start)
        store.markSeen(used.id, name: "Pixel", now: start.addingTimeInterval(60))

        let later = start.addingTimeInterval(PhoneLinkStore.pendingLifetime + 1)
        XCTAssertNil(store.secret(for: unused.id, now: later))
        XCTAssertEqual(store.secret(for: used.id, now: later), used.secret)

        let reopened = PhoneLinkStore(root: root)
        XCTAssertEqual(reopened.macID, store.macID)
        XCTAssertEqual(reopened.phone(used.id)?.name, "Pixel")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("PhoneLink/devices.json").path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        try reopened.remove(used.id)
        XCTAssertNil(reopened.secret(for: used.id, now: later))
    }

    func testPhoneImagesBecomePasteableAndLargeOnesFit() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 192, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // Noise, so PNG can't compress it away and resizing has real work to do.
        for index in 0..<(rep.bytesPerRow * rep.pixelsHigh) { rep.bitmapData![index] = UInt8.random(in: 0...255) }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let gif = try XCTUnwrap(rep.representation(using: .gif, properties: [:]))
        XCTAssertEqual(ClipboardImage.pasteable(png)?.data, png, "PNG passes through untouched")
        let converted = try XCTUnwrap(ClipboardImage.pasteable(gif))
        XCTAssertEqual(converted.mime, "image/png")
        XCTAssertTrue(converted.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertNil(ClipboardImage.pasteable(Data("not an image".utf8)))

        let limit = png.count / 4
        let fitted = try XCTUnwrap(ClipboardImage.fit(png, mime: "image/png", limit: limit))
        XCTAssertLessThanOrEqual(fitted.data.count, limit)
        XCTAssertEqual(fitted.mime, "image/jpeg")
    }

    func testPairingTheSamePhoneAgainReplacesItsOldSlot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhoneLinkStore(root: root)
        let old = try store.createPendingPhone(), other = try store.createPendingPhone(), new = try store.createPendingPhone()
        for phone in [old, other, new] { store.markSeen(phone.id, name: "Phone") }
        XCTAssertEqual(store.claim(old.id, installID: "install-A"), [])
        XCTAssertEqual(store.claim(other.id, installID: "install-B"), [])
        let stale = store.claim(new.id, installID: "install-A")
        XCTAssertEqual(stale.map(\.id), [old.id])
        XCTAssertEqual(Set(store.phones.map(\.id)), [other.id, new.id], "A different phone keeps its slot")
    }

    func testClipboardSkipsPrivateAndPhoneOriginatedText() {
        XCTAssertEqual(ClipboardBridge.shareableText(types: [.string], string: "hello"), "hello")
        XCTAssertNil(ClipboardBridge.shareableText(types: [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], string: "hunter2"))
        XCTAssertNil(ClipboardBridge.shareableText(types: [.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], string: "dictation"))
        XCTAssertNil(ClipboardBridge.shareableText(types: [.string, ClipboardBridge.fromPhoneType], string: "echo"))
        XCTAssertNil(ClipboardBridge.shareableText(types: [.string], string: "  \n"))
        XCTAssertNil(ClipboardBridge.shareableText(types: [.string], string: String(repeating: "a", count: PhoneLinkProtocol.maxClipboardBytes + 1)))
    }

    @MainActor
    func testExternalRecordingWritesChunksMeasuredBySamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder()
        try recorder.startExternal(directoryURL: directory)
        XCTAssertTrue(recorder.isRecordingExternal)
        // One second of a 440 Hz tone at about -12 dBFS, in 40 ms frames.
        for frame in 0..<25 {
            var pcm = Data(capacity: 1280)
            for index in 0..<640 {
                let t = Double(frame * 640 + index) / 16_000
                var sample = Int16(sin(2 * .pi * 440 * t) * 8_000).littleEndian
                pcm.append(Data(bytes: &sample, count: 2))
            }
            recorder.appendExternal(pcm16: pcm)
        }
        XCTAssertEqual(recorder.duration, 1, accuracy: 0.001)
        XCTAssertGreaterThan(recorder.peakLevel, AppController.speechLevel)
        let result = try recorder.stop()
        XCTAssertEqual(result.chunkURLs.count, 1)
        let file = try AVAudioFile(forReading: result.chunkURLs[0])
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.length, 16_000)
        XCTAssertFalse(recorder.isRecordingExternal)
    }
}

/// Drives the real server over TCP as a phone would, using only the wire format from the spec.
final class PhoneLinkServerTests: XCTestCase {
    private final class FakePhone {
        let connection: NWConnection
        var buffer = Data()
        var pending: [Data] = []
        var sender: PhoneLinkCipher?
        var receiver: PhoneLinkCipher?

        init(port: UInt16) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }

        func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                connection.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; continuation.resume()
                    case .failed(let error): resumed = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
                connection.start(queue: .global())
            }
        }

        func sendRaw(_ payload: Data) {
            connection.send(content: PhoneLinkProtocol.frame(payload), completion: .contentProcessed { _ in })
        }

        func send(_ kind: UInt8, _ body: Data) throws {
            sendRaw(try sender!.seal(Data([kind]) + body))
        }

        func send(_ json: [String: Any]) throws {
            try send(1, try JSONSerialization.data(withJSONObject: json))
        }

        /// Next frame, or nil if the server closed the connection.
        func nextFrame() async throws -> Data? {
            while true {
                pending += try PhoneLinkProtocol.takeFrames(from: &buffer)
                if !pending.isEmpty { return pending.removeFirst() }
                let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if complete { continuation.resume(returning: nil) }
                        else { continuation.resume(returning: Data()) }
                    }
                }
                guard let chunk else { return nil }
                buffer.append(chunk)
            }
        }

        func nextMessage() async throws -> [String: Any]? {
            guard let frame = try await nextFrame() else { return nil }
            let plain = try receiver!.open(frame)
            XCTAssertEqual(plain.first, 1)
            return try JSONSerialization.jsonObject(with: plain.dropFirst()) as? [String: Any]
        }
    }

    private func startServer(secrets: [String: Data]) async throws -> (PhoneLinkServer, UInt16, AsyncStream<PhoneLinkConnection.Event>) {
        let (events, continuation) = AsyncStream<PhoneLinkConnection.Event>.makeStream()
        let server = PhoneLinkServer(macID: "MAC", macName: { "Test Mac" }, secretFor: { secrets[$0] })
        server.onConnectionEvent = { _, event in continuation.yield(event) }
        let port: UInt16 = try await withCheckedThrowingContinuation { result in
            var resumed = false
            server.onState = { state in
                guard !resumed else { return }
                switch state {
                case .listening(let port): resumed = true; result.resume(returning: port)
                case .failed(let message): resumed = true; result.resume(throwing: NSError(domain: "PhoneLink", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                default: break
                }
            }
            server.start()
        }
        return (server, port, events)
    }

    func testHandshakeClipAndAudioRoundTrip() async throws {
        let secret = PhoneLinkProtocol.randomBytes(32)
        let (server, port, events) = try await startServer(secrets: ["D1": secret])
        defer { server.stop() }
        let phone = FakePhone(port: port)
        try await phone.start()
        defer { phone.connection.cancel() }

        let clientNonce = PhoneLinkProtocol.randomBytes(16)
        phone.sendRaw(try JSONSerialization.data(withJSONObject: ["t": "hello", "v": 1, "device": "D1", "nonce": clientNonce.base64URLEncoded]))
        let welcomeFrame = try await phone.nextFrame()
        let welcome = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(welcomeFrame)) as? [String: Any])
        XCTAssertEqual(welcome["t"] as? String, "welcome")
        XCTAssertEqual(welcome["mac"] as? String, "MAC")
        let serverNonce = try XCTUnwrap((welcome["nonce"] as? String).flatMap(Data.init(base64URLEncoded:)))
        let keys = PhoneLinkProtocol.sessionKeys(secret: secret, clientNonce: clientNonce, serverNonce: serverNonce)
        phone.sender = PhoneLinkCipher(key: keys.clientToServer)
        phone.receiver = PhoneLinkCipher(key: keys.serverToClient)

        try phone.send(["t": "auth", "name": "Pixel", "app": "0.1.0"])
        let ready = try await phone.nextMessage()
        XCTAssertEqual(ready?["t"] as? String, "ready")
        XCTAssertEqual(ready?["name"] as? String, "Test Mac")

        try phone.send(["t": "ping"])
        let pong = try await phone.nextMessage()
        XCTAssertEqual(pong?["t"] as? String, "pong")

        try phone.send(["t": "clip", "id": "C1", "text": "from phone"])
        try phone.send(2, Data([1, 0, 2, 0]))

        var iterator = events.makeAsyncIterator()
        guard case .ready(let name)? = await iterator.next() else { return XCTFail("Expected ready") }
        XCTAssertEqual(name, "Pixel")
        guard case .message(let clip)? = await iterator.next() else { return XCTFail("Expected clip") }
        XCTAssertEqual(clip.t, "clip")
        XCTAssertEqual(clip.text, "from phone")
        guard case .audio(let audio)? = await iterator.next() else { return XCTFail("Expected audio") }
        XCTAssertEqual(audio, Data([1, 0, 2, 0]))
    }

    func testUnpairedPhoneIsRefused() async throws {
        let (server, port, _) = try await startServer(secrets: [:])
        defer { server.stop() }
        let phone = FakePhone(port: port)
        try await phone.start()
        defer { phone.connection.cancel() }
        phone.sendRaw(try JSONSerialization.data(withJSONObject: ["t": "hello", "v": 1, "device": "nope",
                                                                  "nonce": PhoneLinkProtocol.randomBytes(16).base64URLEncoded]))
        let frame = try await phone.nextFrame()
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(frame)) as? [String: Any])
        XCTAssertEqual(reply["t"] as? String, "error")
        XCTAssertEqual(reply["code"] as? String, "unpaired")
    }

    func testWrongSecretNeverGetsReady() async throws {
        let (server, port, _) = try await startServer(secrets: ["D1": PhoneLinkProtocol.randomBytes(32)])
        defer { server.stop() }
        let phone = FakePhone(port: port)
        try await phone.start()
        defer { phone.connection.cancel() }
        let clientNonce = PhoneLinkProtocol.randomBytes(16)
        phone.sendRaw(try JSONSerialization.data(withJSONObject: ["t": "hello", "v": 1, "device": "D1", "nonce": clientNonce.base64URLEncoded]))
        let welcomeFrame = try await phone.nextFrame()
        let welcome = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(welcomeFrame)) as? [String: Any])
        let serverNonce = try XCTUnwrap((welcome["nonce"] as? String).flatMap(Data.init(base64URLEncoded:)))
        let keys = PhoneLinkProtocol.sessionKeys(secret: PhoneLinkProtocol.randomBytes(32), clientNonce: clientNonce, serverNonce: serverNonce)
        phone.sender = PhoneLinkCipher(key: keys.clientToServer)
        try phone.send(["t": "auth", "name": "Impostor"])
        let next = try await phone.nextFrame()
        XCTAssertNil(next, "The server must close the connection instead of answering")
    }
}

/// Runs the Mac's relay client against a fake Worker relay (a local WebSocket server) that plays the phone.
final class PhoneLinkRelayTests: XCTestCase {
    func testRelaySessionHandshakesAndCarriesMessages() async throws {
        let secret = PhoneLinkProtocol.randomBytes(32)
        let ws = NWProtocolWebSocket.Options()
        var sawAuthorization: String?
        ws.setClientRequestHandler(.main) { _, headers in
            sawAuthorization = headers.first { $0.name.lowercased() == "authorization" }?.value
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        let (phoneSide, accepted) = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            accepted.yield(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { result in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                if case .ready = state { resumed = true; result.resume(returning: listener.port!.rawValue) }
                if case .failed(let error) = state { resumed = true; result.resume(throwing: error) }
            }
            listener.start(queue: .main)
        }
        defer { listener.cancel() }

        let request = try XCTUnwrap(PhoneLinkRelay.request(server: URL(string: "http://127.0.0.1:\(port)")!, token: "osk_test", secret: secret))
        XCTAssertEqual(request.url?.path, "/api/v1/link/relay/\(PhoneLinkProtocol.relayRoom(secret: secret))")
        let relay = PhoneLinkRelay(deviceID: "D1", request: request)
        let (events, sink) = AsyncStream<PhoneLinkConnection.Event>.makeStream()
        relay.onSession = { [weak relay] transport in
            guard let relay else { return }
            let connection = PhoneLinkConnection(transport: transport, queue: relay.queue, macID: "MAC", macName: { "Test Mac" },
                                                 secretFor: { $0 == "D1" ? secret : nil })
            (transport as? RelaySessionTransport)?.owner = connection
            connection.onEvent = { _, event in sink.yield(event) }
            connection.start()
        }
        relay.start()
        defer { relay.stop() }

        var connections = phoneSide.makeAsyncIterator()
        let accepted1 = await connections.next()
        let socket = try XCTUnwrap(accepted1)
        func send(_ data: Data, text: Bool = false) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: text ? .text : .binary)
            socket.send(content: data, contentContext: NWConnection.ContentContext(identifier: "m", metadata: [metadata]),
                        isComplete: true, completion: .contentProcessed { _ in })
        }
        func receive() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                socket.receiveMessage { data, _, _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
                }
            }
        }

        // The Worker announces the phone, then the phone runs the normal handshake through the relay.
        send(Data(#"{"t":"peer","present":true}"#.utf8), text: true)
        let clientNonce = PhoneLinkProtocol.randomBytes(16)
        send(try JSONSerialization.data(withJSONObject: ["t": "hello", "v": 1, "device": "D1", "nonce": clientNonce.base64URLEncoded]))
        let welcomeData = try await receive()
        let welcome = try XCTUnwrap(try JSONSerialization.jsonObject(with: welcomeData) as? [String: Any])
        XCTAssertEqual(welcome["t"] as? String, "welcome")
        let serverNonce = try XCTUnwrap((welcome["nonce"] as? String).flatMap(Data.init(base64URLEncoded:)))
        let keys = PhoneLinkProtocol.sessionKeys(secret: secret, clientNonce: clientNonce, serverNonce: serverNonce)
        var sender = PhoneLinkCipher(key: keys.clientToServer)
        var receiver = PhoneLinkCipher(key: keys.serverToClient)
        send(try sender.seal(Data([1]) + Data(#"{"t":"auth","name":"Pixel"}"#.utf8)))
        let readyFrame = try await receive()
        let ready = try receiver.open(readyFrame)
        let readyMessage = try PhoneLinkMessage.decode(Data(ready.dropFirst()))
        XCTAssertEqual(readyMessage.t, "ready")
        XCTAssertEqual(readyMessage.name, "Test Mac")
        send(try sender.seal(Data([1]) + Data(#"{"t":"clip","id":"C1","text":"via cloud"}"#.utf8)))

        var iterator = events.makeAsyncIterator()
        guard case .ready(let name)? = await iterator.next() else { return XCTFail("Expected ready") }
        XCTAssertEqual(name, "Pixel")
        guard case .message(let clip)? = await iterator.next() else { return XCTFail("Expected clip") }
        XCTAssertEqual(clip.text, "via cloud")
        XCTAssertEqual(sawAuthorization, "Bearer osk_test")

        // The phone leaving ends the session.
        send(Data(#"{"t":"peer","present":false}"#.utf8), text: true)
        guard case .closed? = await iterator.next() else { return XCTFail("Expected the session to close") }
    }
}
