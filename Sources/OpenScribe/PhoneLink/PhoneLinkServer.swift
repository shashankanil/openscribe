import Foundation
import Network

/// Serial queues that know when code is already running on them, so sends from a session's own callbacks don't hop.
enum PhoneLinkQueue {
    private static let key = DispatchSpecificKey<UUID>()

    static func make(_ label: String) -> DispatchQueue {
        let queue = DispatchQueue(label: label)
        queue.setSpecific(key: key, value: UUID())
        return queue
    }

    static func isCurrent(_ queue: DispatchQueue) -> Bool {
        guard let id = queue.getSpecific(key: key) else { return false }
        return DispatchQueue.getSpecific(key: key) == id
    }
}

/// How a phone session reached this Mac.
enum PhoneLinkRoute: Equatable { case localNetwork, cloud }

/// Carries whole frames for one phone session: TCP on the local network, or the OpenScribe Cloud relay.
/// Callbacks arrive on the queue passed to `start`.
protocol PhoneLinkTransport: AnyObject {
    var route: PhoneLinkRoute { get }
    func start(queue: DispatchQueue, onFrame: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void)
    func send(_ frame: Data, completion: (() -> Void)?)
    func cancel()
}

/// Length-prefixed frames over a TCP connection from the local network.
final class TCPFrameTransport: PhoneLinkTransport, @unchecked Sendable {
    let route = PhoneLinkRoute.localNetwork
    private let connection: NWConnection
    private var buffer = Data()
    private var onFrame: ((Data) -> Void)?
    private var onClose: ((Error?) -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    func start(queue: DispatchQueue, onFrame: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) {
        self.onFrame = onFrame
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.onFrame != nil else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                do {
                    for frame in try PhoneLinkProtocol.takeFrames(from: &self.buffer) {
                        self.onFrame?(frame)
                        if self.onFrame == nil { return }
                    }
                } catch {
                    self.finish(error)
                    return
                }
            }
            if let error { self.finish(error); return }
            if isComplete { self.finish(nil); return }
            self.receive()
        }
    }

    func send(_ frame: Data, completion: (() -> Void)?) {
        connection.send(content: PhoneLinkProtocol.frame(frame), completion: .contentProcessed { _ in completion?() })
    }

    func cancel() { connection.cancel() }

    private func finish(_ error: Error?) {
        let close = onClose
        onFrame = nil
        onClose = nil
        connection.cancel()
        close?(error)
    }
}

/// One phone session: plaintext hello/welcome, then encrypted frames (docs/PHONE-LINK.md), over any transport.
/// All state lives on `queue`; callbacks are delivered on `queue` too.
final class PhoneLinkConnection: @unchecked Sendable {
    enum Event {
        case ready(name: String)
        case message(PhoneLinkMessage)
        case audio(Data)
        /// Sent for every connection, including ones that never authenticated.
        case closed(Error?)
    }

    /// `rejecting`: an error reply is on its way; the connection closes once it has been sent.
    private enum Stage { case hello, auth, ready, rejecting, closed }

    let id = UUID()
    private(set) var deviceID: String?
    private(set) var phoneName = ""
    private(set) var installID: String?
    private let transport: PhoneLinkTransport
    private let queue: DispatchQueue
    private let macID: String
    private let macName: () -> String
    private let secretFor: (String) -> Data?
    private var stage = Stage.hello
    private var receiver: PhoneLinkCipher?
    private var sender: PhoneLinkCipher?
    private var lastHeard = Date()
    private var watchdog: DispatchSourceTimer?
    var onEvent: ((PhoneLinkConnection, Event) -> Void)?

    static let handshakeTimeout: TimeInterval = 10
    static let silenceTimeout: TimeInterval = 45

    var route: PhoneLinkRoute { transport.route }

    init(transport: PhoneLinkTransport, queue: DispatchQueue, macID: String, macName: @escaping () -> String,
         secretFor: @escaping (String) -> Data?) {
        self.transport = transport
        self.queue = queue
        self.macID = macID
        self.macName = macName
        self.secretFor = secretFor
    }

    func start() {
        transport.start(queue: queue, onFrame: { [weak self] frame in
            guard let self, self.stage != .closed else { return }
            self.lastHeard = Date()
            do { try self.handle(frame) } catch { self.close(error) }
        }, onClose: { [weak self] error in self?.close(error) })
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkLiveness() }
        timer.resume()
        watchdog = timer
    }

    private func checkLiveness() {
        let limit = stage == .ready ? Self.silenceTimeout : Self.handshakeTimeout
        if Date().timeIntervalSince(lastHeard) > limit { close(nil) }
    }

    private func handle(_ frame: Data) throws {
        switch stage {
        case .hello:
            let hello = try PhoneLinkMessage.decode(frame)
            guard hello.t == "hello" else { throw PhoneLinkError.badMessage }
            guard hello.v == PhoneLinkProtocol.version else { return reject("version") }
            guard let device = hello.device, let secret = secretFor(device) else { return reject("unpaired") }
            guard let clientNonce = hello.nonce.flatMap(Data.init(base64URLEncoded:)), clientNonce.count == PhoneLinkProtocol.nonceLength else {
                throw PhoneLinkError.badMessage
            }
            let serverNonce = PhoneLinkProtocol.randomBytes(PhoneLinkProtocol.nonceLength)
            let keys = PhoneLinkProtocol.sessionKeys(secret: secret, clientNonce: clientNonce, serverNonce: serverNonce)
            receiver = PhoneLinkCipher(key: keys.clientToServer)
            sender = PhoneLinkCipher(key: keys.serverToClient)
            deviceID = device
            var welcome = PhoneLinkMessage(t: "welcome")
            welcome.v = PhoneLinkProtocol.version
            welcome.mac = macID
            welcome.nonce = serverNonce.base64URLEncoded
            sendPlain(welcome)
            stage = .auth
        case .auth:
            // Opening the first frame proves the phone holds the pairing secret.
            guard case let (.message, body)? = try open(frame) else { throw PhoneLinkError.badMessage }
            let auth = try PhoneLinkMessage.decode(body)
            guard auth.t == "auth" else { throw PhoneLinkError.badMessage }
            phoneName = String((auth.name ?? "Phone").prefix(80))
            installID = auth.install.map { String($0.prefix(64)) }
            stage = .ready
            var ready = PhoneLinkMessage(t: "ready")
            ready.name = macName()
            ready.clipboard = true
            send(ready)
            onEvent?(self, .ready(name: phoneName))
        case .ready:
            guard let (kind, body) = try open(frame) else { return }
            switch kind {
            case .message:
                let message = try PhoneLinkMessage.decode(body)
                if message.t == "ping" { send(PhoneLinkMessage(t: "pong")); return }
                onEvent?(self, .message(message))
            case .audio:
                onEvent?(self, .audio(body))
            }
        case .rejecting, .closed:
            return
        }
    }

    /// Tells the phone why it can't connect, then closes once the reply has gone out.
    private func reject(_ code: String) {
        stage = .rejecting
        var reply = PhoneLinkMessage(t: "error")
        reply.code = code
        sendPlain(reply, thenClose: true)
    }

    /// Returns nil for an unknown kind, which is ignored.
    private func open(_ frame: Data) throws -> (PhoneLinkProtocol.Kind, Data)? {
        guard var cipher = receiver else { throw PhoneLinkError.badCiphertext }
        let plain = try cipher.open(frame)
        receiver = cipher
        guard let first = plain.first else { throw PhoneLinkError.badMessage }
        guard let kind = PhoneLinkProtocol.Kind(rawValue: first) else { return nil }
        return (kind, Data(plain.dropFirst()))
    }

    private func sendPlain(_ message: PhoneLinkMessage, thenClose: Bool = false) {
        guard let body = try? PhoneLinkMessage.encode(message) else { return }
        transport.send(body) { [weak self] in
            if thenClose { self?.queue.async { self?.close(nil) } }
        }
    }

    /// Sends an encrypted message. Safe to call from any thread.
    func send(_ message: PhoneLinkMessage) {
        guard let body = try? PhoneLinkMessage.encode(message) else { return }
        sendEncrypted(kind: .message, body: body)
    }

    private func sendEncrypted(kind: PhoneLinkProtocol.Kind, body: Data) {
        let work = { [self] in
            guard stage == .ready || stage == .auth, var cipher = sender,
                  let sealed = try? cipher.seal(Data([kind.rawValue]) + body) else { return }
            sender = cipher
            transport.send(sealed, completion: nil)
        }
        if PhoneLinkQueue.isCurrent(queue) { work() } else { queue.async(execute: work) }
    }

    func cancel() { queue.async { [weak self] in self?.close(nil) } }

    private func close(_ error: Error?) {
        guard stage != .closed else { return }
        stage = .closed
        watchdog?.cancel()
        watchdog = nil
        transport.cancel()
        onEvent?(self, .closed(error))
        onEvent = nil
    }
}

/// Listens for phones on the local network and advertises this Mac over Bonjour.
final class PhoneLinkServer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    let queue = PhoneLinkQueue.make("org.open-source.openscribe.phone-link")
    private var listener: NWListener?
    private var connections: [UUID: PhoneLinkConnection] = [:]
    private let macID: String
    private let macName: () -> String
    private let secretFor: (String) -> Data?
    /// Delivered on the server queue.
    var onState: ((State) -> Void)?
    var onConnectionEvent: ((PhoneLinkConnection, PhoneLinkConnection.Event) -> Void)?

    init(macID: String, macName: @escaping () -> String, secretFor: @escaping (String) -> Data?) {
        self.macID = macID
        self.macName = macName
        self.secretFor = secretFor
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            onState?(.starting)
            startListener(port: NWEndpoint.Port(rawValue: PhoneLinkProtocol.preferredPort) ?? .any, allowFallback: true)
        }
    }

    private func startListener(port: NWEndpoint.Port, allowFallback: Bool) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 20
        }
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: port) }
        catch {
            if allowFallback { startListener(port: .any, allowFallback: false) }
            else { onState?(.failed(error.localizedDescription)) }
            return
        }
        listener.service = NWListener.Service(name: macName(), type: PhoneLinkProtocol.bonjourType, domain: nil,
                                              txtRecord: NWTXTRecord(["id": macID, "v": String(PhoneLinkProtocol.version)]))
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.onState?(.listening(port: listener.port?.rawValue ?? 0))
            case .failed(let error):
                listener.cancel()
                self.listener = nil
                if allowFallback, case .posix(let code) = error, code == .EADDRINUSE {
                    self.startListener(port: .any, allowFallback: false)
                } else {
                    self.onState?(.failed(error.localizedDescription))
                }
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ nw: NWConnection) {
        let connection = PhoneLinkConnection(transport: TCPFrameTransport(nw), queue: queue, macID: macID, macName: macName, secretFor: secretFor)
        connections[connection.id] = connection
        connection.onEvent = { [weak self] connection, event in
            if case .closed = event { self?.connections[connection.id] = nil }
            self?.onConnectionEvent?(connection, event)
        }
        connection.start()
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            onState?(.stopped)
        }
    }

    /// Drops every session with this phone, such as after it is removed.
    func disconnect(deviceID: String) {
        queue.async { [self] in
            for connection in connections.values where connection.deviceID == deviceID { connection.cancel() }
        }
    }

    /// Updates the Bonjour name after the Mac is renamed.
    func refreshAdvertisement() {
        queue.async { [self] in
            listener?.service = NWListener.Service(name: macName(), type: PhoneLinkProtocol.bonjourType, domain: nil,
                                                   txtRecord: NWTXTRecord(["id": macID, "v": String(PhoneLinkProtocol.version)]))
        }
    }
}

enum LocalNetwork {
    /// This Mac's private IPv4 addresses, Wi-Fi and Ethernet first, for the pairing code's fallback hosts.
    static func ipv4Addresses() -> [String] {
        var results: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if !value.hasPrefix("169.254.") { results.append((name, value)) }
        }
        return results.sorted { $0.name < $1.name }.map(\.address)
    }
}
