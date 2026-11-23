import Foundation

/// Keeps this Mac waiting in one phone's OpenScribe Cloud relay room, and starts a session whenever the phone
/// joins. The Worker only forwards frames; they are end-to-end encrypted exactly as on the local network.
/// See docs/PHONE-LINK.md, "Relay".
final class PhoneLinkRelay: @unchecked Sendable {
    let deviceID: String
    let queue = PhoneLinkQueue.make("org.open-source.openscribe.phone-link.relay")
    private let request: URLRequest
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var backoff: TimeInterval = 2
    private var current: RelaySessionTransport?
    private var keepalive: DispatchSourceTimer?
    /// A phone joined: run a session over this transport. Called on `queue`.
    var onSession: ((PhoneLinkTransport) -> Void)?

    init(deviceID: String, request: URLRequest) {
        self.deviceID = deviceID
        self.request = request
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// `wss://…/api/v1/link/relay/<room>` with the Mac's app token.
    static func request(server: URL, token: String, secret: Data) -> URLRequest? {
        guard var components = URLComponents(url: server.appendingPathComponent("api/v1/link/relay/\(PhoneLinkProtocol.relayRoom(secret: secret))"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func start() { queue.async { [self] in connect() } }

    func stop() {
        queue.async { [self] in
            stopped = true
            endSession(nil)
            keepalive?.cancel()
            keepalive = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            session.invalidateAndCancel()
        }
    }

    private func connect() {
        guard !stopped else { return }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = PhoneLinkProtocol.maxFrameLength + 1024
        self.task = task
        task.resume()
        receive(on: task)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        // Keeps the socket alive; the Worker answers without waking the relay (hibernation auto-response).
        timer.setEventHandler { [weak task] in task?.send(.string("ping")) { _ in } }
        timer.resume()
        keepalive?.cancel()
        keepalive = timer
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard task === self.task else { return }
                switch result {
                case .success(let message):
                    self.backoff = 2
                    switch message {
                    case .string(let text): self.handleText(text)
                    case .data(let frame): self.current?.deliver(frame)
                    @unknown default: break
                    }
                    self.receive(on: task)
                case .failure(let error):
                    self.reconnect(after: error)
                }
            }
        }
    }

    private func handleText(_ text: String) {
        struct Peer: Decodable { let t: String; let present: Bool? }
        guard let peer = try? JSONDecoder().decode(Peer.self, from: Data(text.utf8)), peer.t == "peer" else { return }
        if peer.present == true {
            // Every arrival is a new phone session (it may have replaced an older socket), so start over.
            endSession(nil)
            let transport = RelaySessionTransport(relay: self)
            current = transport
            onSession?(transport)
        } else {
            endSession(nil)
        }
    }

    private func endSession(_ error: Error?) {
        let session = current
        current = nil
        session?.end(error)
    }

    private func reconnect(after error: Error?) {
        // 4000: another socket of this Mac's role took the room (this Mac relaunched). Leave it to the newer one.
        if task?.closeCode.rawValue == 4000 { stopped = true }
        endSession(error)
        keepalive?.cancel()
        keepalive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard !stopped else { return }
        let delay = backoff
        backoff = min(backoff * 2, 60)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    fileprivate func send(_ frame: Data, completion: (() -> Void)?) {
        guard let task else { completion?(); return }
        task.send(.data(frame)) { _ in completion?() }
    }

    /// The Mac ended a session (for example a phone that failed to authenticate). Dropping the socket tells the
    /// phone at once, through the Worker's presence message, and a fresh socket waits for its next attempt.
    fileprivate func sessionCancelled(_ transport: RelaySessionTransport) {
        guard transport === current else { return }
        reconnect(after: nil)
    }
}

/// One phone session over a relay socket.
final class RelaySessionTransport: PhoneLinkTransport {
    let route = PhoneLinkRoute.cloud
    private weak var relay: PhoneLinkRelay?
    /// The session running over this transport, kept alive until the session ends.
    var owner: AnyObject?
    private var onFrame: ((Data) -> Void)?
    private var onClose: ((Error?) -> Void)?
    private var ended = false

    fileprivate init(relay: PhoneLinkRelay) { self.relay = relay }

    func start(queue: DispatchQueue, onFrame: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) {
        self.onFrame = onFrame
        self.onClose = onClose
    }

    func send(_ frame: Data, completion: (() -> Void)?) { relay?.send(frame, completion: completion) }

    func cancel() {
        guard !ended else { return }
        relay?.sessionCancelled(self)
        end(nil)
    }

    fileprivate func deliver(_ frame: Data) { if !ended { onFrame?(frame) } }

    fileprivate func end(_ error: Error?) {
        guard !ended else { return }
        ended = true
        let close = onClose
        onFrame = nil
        onClose = nil
        close?(error)
        owner = nil
    }
}
