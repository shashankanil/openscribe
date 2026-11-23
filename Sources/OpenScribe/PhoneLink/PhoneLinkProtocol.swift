import CryptoKit
import Foundation

/// Wire format shared with the Android companion app. The spec, with test vectors, is docs/PHONE-LINK.md;
/// `android/app/src/main/java/org/opensource/openscribe/link/LinkProtocol.kt` must stay byte-compatible.
enum PhoneLinkProtocol {
    static let version = 1
    static let bonjourType = "_openscribe._tcp"
    static let preferredPort: UInt16 = 47_689
    /// Larger frames are a protocol error. Clipboard text is capped well below this.
    static let maxFrameLength = 1 << 20
    static let maxClipboardBytes = 256 * 1024
    static let nonceLength = 16
    /// Always the newest Android build (attached to each GitHub release under this fixed name).
    static let androidDownloadURL = URL(string: "https://github.com/shashankanil/openscribe/releases/latest/download/OpenScribe-Android.apk")!
    static let keyLength = 32

    enum Kind: UInt8 {
        case message = 0x01
        case audio = 0x02
    }

    /// Phone audio: 16 kHz mono signed 16-bit little-endian PCM, the format speech providers prefer.
    static let audioSampleRate: Double = 16_000

    // MARK: Framing

    /// A 4-byte big-endian length followed by the payload.
    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    /// Splits complete frames off the front of `buffer`, leaving any partial frame in place.
    static func takeFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= maxFrameLength else { throw PhoneLinkError.frameTooLarge }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return frames
    }

    // MARK: Keys

    struct SessionKeys {
        let clientToServer: SymmetricKey
        let serverToClient: SymmetricKey
    }

    /// Per-session keys from the pairing secret and both sides' fresh nonces, so no two sessions share a key
    /// and per-direction counters can start at zero.
    static func sessionKeys(secret: Data, clientNonce: Data, serverNonce: Data) -> SessionKeys {
        let ikm = SymmetricKey(data: secret)
        let salt = clientNonce + serverNonce
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("openscribe-link-v1 \(label)".utf8), outputByteCount: keyLength)
        }
        return SessionKeys(clientToServer: derive("c2s"), serverToClient: derive("s2c"))
    }

    /// The relay room for a pairing, derived from its secret so OpenScribe Cloud never learns the secret.
    static func relayRoom(secret: Data) -> String {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(),
                               info: Data("openscribe-link-v1 room".utf8), outputByteCount: 16)
            .withUnsafeBytes { Data($0) }.hexString
    }

    /// Images are at most this big before encryption (docs/PHONE-LINK.md, Images).
    static let maxImageBytes = 10 * 1024 * 1024

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// AES-256-GCM in one direction. The nonce is 4 zero bytes then a 64-bit big-endian counter, so frames that
/// arrive out of order, twice, or from another session fail to open.
struct PhoneLinkCipher {
    private let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    private func nonce(_ value: UInt64) throws -> AES.GCM.Nonce {
        var big = value.bigEndian
        return try AES.GCM.Nonce(data: Data(count: 4) + Data(bytes: &big, count: 8))
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce(counter))
        counter += 1
        // `ciphertext` is a slice of the combined box; rebase so callers can index from zero.
        var sealed = Data(box.ciphertext)
        sealed.append(box.tag)
        return sealed
    }

    mutating func open(_ payload: Data) throws -> Data {
        guard payload.count >= 16 else { throw PhoneLinkError.badCiphertext }
        let split = payload.index(payload.endIndex, offsetBy: -16)
        let box = try AES.GCM.SealedBox(nonce: nonce(counter), ciphertext: payload[..<split], tag: payload[split...])
        do {
            let plain = try AES.GCM.open(box, using: key)
            counter += 1
            return plain
        } catch { throw PhoneLinkError.badCiphertext }
    }
}

/// Encrypts clipboard images for R2 with a one-time key: `nonce ‖ ciphertext ‖ tag`, AES-256-GCM, no AAD.
enum PhoneLinkBlob {
    static func seal(_ plaintext: Data, key: Data, nonce: Data? = nil) throws -> Data {
        let gcmNonce = try nonce.map(AES.GCM.Nonce.init(data:)) ?? AES.GCM.Nonce()
        guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: gcmNonce).combined else {
            throw PhoneLinkError.badCiphertext
        }
        return Data(combined)
    }

    static func open(_ blob: Data, key: Data) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: SymmetricKey(data: key)) }
        catch { throw PhoneLinkError.badCiphertext }
    }
}

enum PhoneLinkError: LocalizedError, Equatable {
    case frameTooLarge
    case badCiphertext
    case badMessage
    case unpaired
    case versionMismatch

    var errorDescription: String? {
        switch self {
        case .frameTooLarge: return "The phone sent a message that is too large."
        case .badCiphertext: return "The phone's message could not be verified. Pair it again."
        case .badMessage: return "The phone sent a message OpenScribe does not understand."
        case .unpaired: return "This phone is not paired with this Mac."
        case .versionMismatch: return "Update OpenScribe on the phone and the Mac to the same version."
        }
    }
}

/// What the QR code on the Mac carries. The phone keeps it and uses it to find and authenticate the Mac.
struct PhoneLinkPairing: Equatable {
    var macID: String
    var macName: String
    var deviceID: String
    var secret: Data
    var hosts: [String]
    var port: UInt16

    var url: URL {
        var components = URLComponents()
        components.scheme = "openscribe"
        components.host = "link"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(PhoneLinkProtocol.version)),
            URLQueryItem(name: "mac", value: macID),
            URLQueryItem(name: "name", value: macName),
            URLQueryItem(name: "device", value: deviceID),
            URLQueryItem(name: "k", value: secret.base64URLEncoded),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
        ]
        return components.url!
    }

    init(macID: String, macName: String, deviceID: String, secret: Data, hosts: [String], port: UInt16) {
        self.macID = macID
        self.macName = macName
        self.deviceID = deviceID
        self.secret = secret
        self.hosts = hosts
        self.port = port
    }

    init?(url: URL) {
        guard url.scheme == "openscribe", url.host == "link",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == String(PhoneLinkProtocol.version),
              let mac = value("mac"), let device = value("device"),
              let secret = value("k").flatMap(Data.init(base64URLEncoded:)), secret.count == PhoneLinkProtocol.keyLength,
              let port = value("p").flatMap(UInt16.init) else { return nil }
        self.init(macID: mac, macName: value("name") ?? "Mac", deviceID: device, secret: secret,
                  hosts: (value("h") ?? "").split(separator: ",").map(String.init), port: port)
    }
}

/// JSON messages inside `Kind.message` frames. `t` names the message; unknown types are ignored so either
/// side can add messages without breaking the other.
struct PhoneLinkMessage: Codable, Equatable {
    var t: String
    var v: Int?
    var device: String?
    var mac: String?
    var name: String?
    var nonce: String?
    var app: String?
    var id: String?
    var text: String?
    var state: String?
    var error: String?
    var code: String?
    var rate: Int?
    var channels: Int?
    var format: String?
    var clipboard: Bool?
    /// cloud: OpenScribe Cloud's address for this phone, empty when cloud features are off.
    var url: String?
    var token: String?
    /// clip: "image" for an image stored (encrypted) in R2, otherwise text.
    var kind: String?
    var mime: String?
    var blob: String?
    var key: String?
    var size: Int?
    /// speech: the transcription connection a phone may use itself (only the transcription key, never the writing key).
    var provider: String?
    var model: String?
    var streaming: String?
    var terms: [String]?
    /// talk_start: "text" when the phone transcribes and sends talk_partial / talk_text instead of audio.
    var mode: String?
    /// auth: stable per phone app install, so pairing the same phone again replaces its old slot.
    var install: String?
    /// talk_state: the Mac app the dictation is going to, and whether it will be pasted there.
    var target: String?
    var pasted: Bool?

    init(t: String) { self.t = t }

    static func encode(_ message: PhoneLinkMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(message)
    }

    static func decode(_ data: Data) throws -> PhoneLinkMessage {
        do { return try JSONDecoder().decode(PhoneLinkMessage.self, from: data) }
        catch { throw PhoneLinkError.badMessage }
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
