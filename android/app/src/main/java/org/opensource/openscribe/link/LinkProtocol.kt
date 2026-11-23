package org.opensource.openscribe.link

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Wire format shared with OpenScribe on the Mac. The spec, with test vectors, is docs/PHONE-LINK.md, and the
 * Mac side is Sources/OpenScribe/PhoneLink/PhoneLinkProtocol.swift. Keep the two byte-compatible.
 *
 * Pure JVM: no android.* imports, so the unit tests run on the host.
 */
object LinkProtocol {
    const val VERSION = 1
    const val SERVICE_TYPE = "_openscribe._tcp"
    const val DEFAULT_PORT = 47689
    const val MAX_FRAME_LENGTH = 1 shl 20
    const val MAX_CLIPBOARD_BYTES = 256 * 1024
    const val NONCE_LENGTH = 16
    const val KEY_LENGTH = 32
    const val TAG_LENGTH = 16

    const val KIND_MESSAGE: Byte = 0x01
    const val KIND_AUDIO: Byte = 0x02

    const val AUDIO_SAMPLE_RATE = 16_000
    /** 40 ms of 16 kHz mono audio. */
    const val AUDIO_FRAME_SAMPLES = 640
    const val AUDIO_FRAME_BYTES = AUDIO_FRAME_SAMPLES * 2

    private val random = SecureRandom()

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also { random.nextBytes(it) }

    // Framing

    /** A 4-byte big-endian length followed by the payload. */
    fun frame(payload: ByteArray): ByteArray {
        require(payload.size <= MAX_FRAME_LENGTH) { "frame too large" }
        return ByteBuffer.allocate(4 + payload.size).putInt(payload.size).put(payload).array()
    }

    fun writeFrame(out: OutputStream, payload: ByteArray) {
        out.write(frame(payload))
        out.flush()
    }

    /** Reads one frame. Throws [EOFException] at end of stream and [LinkProtocolException] for oversize frames. */
    fun readFrame(input: InputStream): ByteArray {
        val data = if (input is DataInputStream) input else DataInputStream(input)
        val length = data.readInt()
        if (length < 0 || length > MAX_FRAME_LENGTH) throw LinkProtocolException("frame too large ($length bytes)")
        val payload = ByteArray(length)
        data.readFully(payload)
        return payload
    }

    // Keys

    /** RFC 5869 HKDF with SHA-256. */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val okm = ByteArrayOutputStream()
        var previous = ByteArray(0)
        var counter = 1
        while (okm.size() < length) {
            mac.update(previous)
            mac.update(info)
            mac.update(counter.toByte())
            previous = mac.doFinal()
            okm.write(previous)
            counter++
        }
        return okm.toByteArray().copyOf(length)
    }

    class SessionKeys(val clientToServer: ByteArray, val serverToClient: ByteArray)

    fun sessionKeys(secret: ByteArray, clientNonce: ByteArray, serverNonce: ByteArray): SessionKeys {
        val salt = clientNonce + serverNonce
        fun derive(label: String) = hkdfSha256(secret, salt, "openscribe-link-v1 $label".toByteArray(Charsets.UTF_8), KEY_LENGTH)
        return SessionKeys(derive("c2s"), derive("s2c"))
    }

    /** The OpenScribe Cloud relay room for a pairing: 32 lowercase hex characters derived from its secret. */
    fun relayRoom(secret: ByteArray): String =
        hkdfSha256(secret, ByteArray(0), "openscribe-link-v1 room".toByteArray(Charsets.UTF_8), 16).toHex()

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }

    // Plaintext of encrypted frames

    fun messagePlaintext(message: JSONObject): ByteArray =
        byteArrayOf(KIND_MESSAGE) + message.toString().toByteArray(Charsets.UTF_8)

    fun audioPlaintext(pcm: ByteArray, offset: Int = 0, length: Int = pcm.size): ByteArray {
        val out = ByteArray(1 + length)
        out[0] = KIND_AUDIO
        System.arraycopy(pcm, offset, out, 1, length)
        return out
    }
}

class LinkProtocolException(message: String) : IOException(message)

/** The Mac refused the handshake with `{"t":"error","code":…}`. */
class LinkRefusedException(val code: String) : IOException("refused: $code")

/**
 * AES-256-GCM in one direction. The nonce is 4 zero bytes then a 64-bit big-endian counter, so frames that
 * arrive out of order, twice, or from another session fail to open. Not thread-safe: callers serialize.
 */
class LinkCipher(key: ByteArray) {
    private val keySpec = SecretKeySpec(key.copyOf(), "AES")
    var counter: Long = 0
        private set

    private fun nonce(value: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(value).array()

    /** Returns `ciphertext ‖ tag`. */
    fun seal(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(LinkProtocol.TAG_LENGTH * 8, nonce(counter)))
        val sealed = cipher.doFinal(plaintext)
        counter++
        return sealed
    }

    /** Opens `ciphertext ‖ tag`, or throws [LinkProtocolException]. The counter advances only on success. */
    fun open(payload: ByteArray): ByteArray {
        if (payload.size < LinkProtocol.TAG_LENGTH) throw LinkProtocolException("short ciphertext")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(LinkProtocol.TAG_LENGTH * 8, nonce(counter)))
        val plain = try {
            cipher.doFinal(payload)
        } catch (e: AEADBadTagException) {
            throw LinkProtocolException("frame failed to open")
        } catch (e: Exception) {
            throw LinkProtocolException("frame failed to open: ${e.message}")
        }
        counter++
        return plain
    }
}

/**
 * Images on the clipboard travel through OpenScribe Cloud as blobs sealed with a one-time key:
 * AES-256-GCM, no AAD, and the blob is `nonce (12 bytes) ‖ ciphertext ‖ tag`. The key only travels inside the
 * encrypted link, so the cloud never sees the image.
 */
object BlobCipher {
    const val KEY_LENGTH = 32
    const val NONCE_LENGTH = 12
    /** Bytes a sealed blob adds to the plaintext. */
    const val OVERHEAD = NONCE_LENGTH + LinkProtocol.TAG_LENGTH
    /** Largest image plaintext; bigger images are re-encoded first. */
    const val MAX_PLAINTEXT = 10 * 1024 * 1024

    fun newKey(): ByteArray = LinkProtocol.randomBytes(KEY_LENGTH)

    fun seal(key: ByteArray, plaintext: ByteArray, nonce: ByteArray = LinkProtocol.randomBytes(NONCE_LENGTH)): ByteArray {
        require(key.size == KEY_LENGTH && nonce.size == NONCE_LENGTH)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(LinkProtocol.TAG_LENGTH * 8, nonce))
        return nonce + cipher.doFinal(plaintext)
    }

    /** Opens a sealed blob, or throws [LinkProtocolException] if it was tampered with or the key is wrong. */
    fun open(key: ByteArray, blob: ByteArray): ByteArray {
        if (key.size != KEY_LENGTH) throw LinkProtocolException("bad blob key")
        if (blob.size < OVERHEAD) throw LinkProtocolException("short blob")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"),
            GCMParameterSpec(LinkProtocol.TAG_LENGTH * 8, blob, 0, NONCE_LENGTH),
        )
        return try {
            cipher.doFinal(blob, NONCE_LENGTH, blob.size - NONCE_LENGTH)
        } catch (e: Exception) {
            throw LinkProtocolException("blob failed to open")
        }
    }
}

object Base64Url {
    fun encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    /** Accepts padded or unpadded input, and standard `+/` too. Returns null if it is not base64. */
    fun decode(text: String): ByteArray? = try {
        Base64.getUrlDecoder().decode(text.trim().replace('+', '-').replace('/', '_').trimEnd('='))
    } catch (e: IllegalArgumentException) {
        null
    }
}

/** What the QR code on the Mac carries. The phone keeps it and uses it to find and authenticate the Mac. */
data class PairingLink(
    val macId: String,
    val macName: String,
    val deviceId: String,
    val secret: ByteArray,
    val hosts: List<String>,
    val port: Int,
) {
    fun toUri(): String = buildString {
        append("openscribe://link?")
        append(
            listOf(
                "v" to LinkProtocol.VERSION.toString(),
                "mac" to macId,
                "name" to macName,
                "device" to deviceId,
                "k" to Base64Url.encode(secret),
                "h" to hosts.joinToString(","),
                "p" to port.toString(),
            ).joinToString("&") { (k, v) -> "$k=${percentEncode(v)}" }
        )
    }

    override fun equals(other: Any?): Boolean =
        other is PairingLink && macId == other.macId && macName == other.macName && deviceId == other.deviceId &&
            secret.contentEquals(other.secret) && hosts == other.hosts && port == other.port

    override fun hashCode(): Int = listOf(macId, macName, deviceId, secret.contentHashCode(), hosts, port).hashCode()

    override fun toString(): String = "PairingLink(mac=$macId, name=$macName, device=$deviceId, hosts=$hosts, port=$port)"

    companion object {
        /** Parses `openscribe://link?…`, or returns null if it is not a valid version-1 pairing link. */
        fun parse(text: String): PairingLink? {
            val trimmed = text.trim()
            val prefix = "openscribe://link"
            if (!trimmed.startsWith(prefix, ignoreCase = true)) return null
            val rest = trimmed.substring(prefix.length).removePrefix("/")
            if (!rest.startsWith("?")) return null
            val query = rest.substring(1).substringBefore('#')
            val items = query.split('&').filter { it.isNotEmpty() }.associate { item ->
                val name = item.substringBefore('=')
                val value = if (item.contains('=')) item.substringAfter('=') else ""
                percentDecode(name) to percentDecode(value)
            }
            if (items["v"] != LinkProtocol.VERSION.toString()) return null
            val mac = items["mac"]?.takeIf { it.isNotEmpty() } ?: return null
            val device = items["device"]?.takeIf { it.isNotEmpty() } ?: return null
            val secret = items["k"]?.let(Base64Url::decode)?.takeIf { it.size == LinkProtocol.KEY_LENGTH } ?: return null
            val port = items["p"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val hosts = (items["h"] ?: "").split(',').map { it.trim() }.filter { it.isNotEmpty() }
            return PairingLink(mac, items["name"]?.takeIf { it.isNotEmpty() } ?: "Mac", device, secret, hosts, port)
        }

        private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,"

        private fun percentEncode(value: String): String = buildString {
            for (b in value.toByteArray(Charsets.UTF_8)) {
                val c = (b.toInt() and 0xff).toChar()
                if (c in UNRESERVED) append(c) else append('%').append("%02X".format(b.toInt() and 0xff))
            }
        }

        /** Percent-decoding without treating `+` as a space (URLComponents on the Mac leaves `+` literal). */
        private fun percentDecode(value: String): String {
            val out = ByteArrayOutputStream()
            var i = 0
            while (i < value.length) {
                val c = value[i]
                if (c == '%' && i + 2 < value.length) {
                    val hex = value.substring(i + 1, i + 3).toIntOrNull(16)
                    if (hex != null) {
                        out.write(hex); i += 3; continue
                    }
                }
                out.write(c.toString().toByteArray(Charsets.UTF_8))
                i++
            }
            return out.toString("UTF-8")
        }
    }
}

/** JSON messages inside [LinkProtocol.KIND_MESSAGE] frames. Unknown types and fields are ignored by readers. */
object LinkMessages {
    fun newId(): String = UUID.randomUUID().toString()

    fun hello(deviceId: String, nonce: ByteArray) = JSONObject()
        .put("t", "hello").put("v", LinkProtocol.VERSION).put("device", deviceId).put("nonce", Base64Url.encode(nonce))

    /** [install] is stable per app install, so a Mac can drop the old slot when the same phone pairs again. */
    fun auth(name: String, appVersion: String, install: String? = null) =
        JSONObject().put("t", "auth").put("name", name).put("app", appVersion).apply { if (install != null) put("install", install) }

    fun ping() = JSONObject().put("t", "ping")

    fun clip(id: String, text: String) = JSONObject().put("t", "clip").put("id", id).put("text", text)

    fun clipAck(id: String) = JSONObject().put("t", "clip_ack").put("id", id)

    /** An image clip: the sealed bytes are in OpenScribe Cloud as [blob], and [key] opens them. */
    fun imageClip(id: String, mime: String, blob: String, key: ByteArray, size: Int) = JSONObject()
        .put("t", "clip").put("id", id).put("kind", "image").put("mime", mime).put("blob", blob)
        .put("key", Base64Url.encode(key)).put("size", size)

    fun talkStart(id: String) = JSONObject().put("t", "talk_start").put("id", id)
        .put("rate", LinkProtocol.AUDIO_SAMPLE_RATE).put("channels", 1).put("format", "pcm_s16le")

    /** A talk the phone transcribes itself: no audio follows, only `talk_partial` and `talk_text`. */
    fun talkStartText(id: String) = JSONObject().put("t", "talk_start").put("id", id).put("mode", "text")

    fun talkPartial(id: String, text: String) = JSONObject().put("t", "talk_partial").put("id", id).put("text", text)

    fun talkText(id: String, text: String) = JSONObject().put("t", "talk_text").put("id", id).put("text", text)

    fun talkEnd(id: String) = JSONObject().put("t", "talk_end").put("id", id)

    fun talkCancel(id: String) = JSONObject().put("t", "talk_cancel").put("id", id)

    /** Parses a JSON message body, or returns null if it is not an object with a string `t`. */
    fun parse(body: ByteArray, offset: Int = 0): JSONObject? = try {
        JSONObject(String(body, offset, body.size - offset, Charsets.UTF_8)).takeIf { it.optString("t").isNotEmpty() }
    } catch (e: Exception) {
        null
    }

    /** `optString` returns "" for JSON null; this returns null for missing or null fields. */
    fun JSONObject.string(name: String): String? = if (has(name) && !isNull(name)) optString(name) else null
}
