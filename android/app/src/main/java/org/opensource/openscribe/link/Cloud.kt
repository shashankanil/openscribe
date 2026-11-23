package org.opensource.openscribe.link

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import org.json.JSONObject
import org.opensource.openscribe.link.LinkMessages.string
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * OpenScribe Cloud access the Mac handed this phone over the encrypted link (`{"t":"cloud","url","token"}`).
 * [token] is a phone token (`oslp_…`) the Mac minted for this pairing and can revoke.
 */
data class CloudConfig(val url: String, val token: String) {
    val baseUrl: String get() = url.trimEnd('/')

    /** Leaves the token out of logs. */
    override fun toString() = "CloudConfig(url=$url)"

    fun toJson(): JSONObject = JSONObject().put("url", url).put("token", token)

    companion object {
        /** Cleartext would expose the token, and Android blocks it anyway. */
        fun isValidUrl(url: String) =
            url.startsWith("https://", ignoreCase = true) && url.length > "https://".length && !url.contains(' ')

        fun fromJson(json: JSONObject): CloudConfig? {
            val url = json.string("url")?.trim() ?: return null
            val token = json.string("token")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            return if (isValidUrl(url)) CloudConfig(url, token) else null
        }
    }
}

/** An image clip the Mac sent: download [blob], open it with [key], and expect [size] bytes of [mime]. */
data class ImageClip(val id: String, val mime: String, val blob: String, val key: ByteArray, val size: Int) {
    override fun equals(other: Any?) = other is ImageClip && id == other.id && mime == other.mime &&
        blob == other.blob && key.contentEquals(other.key) && size == other.size

    override fun hashCode() = listOf(id, mime, blob, key.contentHashCode(), size).hashCode()

    override fun toString() = "ImageClip(id=$id, mime=$mime, blob=$blob, size=$size)"
}

/** A cloud request failed, with a message fit for a toast. */
class CloudException(message: String, val status: Int? = null) : IOException(message)

/** Encrypted image blobs in OpenScribe Cloud (`/api/v1/link/blobs`). Blocking: call off the main thread. */
class CloudBlobs(private val http: OkHttpClient) {
    /** Uploads a sealed blob and returns its id. */
    fun upload(config: CloudConfig, sealed: ByteArray): String {
        if (sealed.size > MAX_BLOB) throw CloudException("That image is too large to send")
        val request = Request.Builder()
            .url("${config.baseUrl}/api/v1/link/blobs")
            .header("Authorization", "Bearer ${config.token}")
            .put(sealed.toRequestBody(OCTET_STREAM))
            .build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw error(response.code)
            val text = response.body.string()
            val id = try { JSONObject(text).string("id") } catch (e: Exception) { null }
            return id?.takeIf(::isValidId) ?: throw CloudException("OpenScribe Cloud sent an odd reply")
        }
    }

    /** Downloads the sealed blob [id]. */
    fun download(config: CloudConfig, id: String): ByteArray {
        if (!isValidId(id)) throw CloudException("Bad image id")
        val request = Request.Builder()
            .url("${config.baseUrl}/api/v1/link/blobs/$id")
            .header("Authorization", "Bearer ${config.token}")
            .get()
            .build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw error(response.code)
            val body = response.body
            if (body.contentLength() > MAX_BLOB) throw CloudException("That image is too large")
            // Read at most one byte past the limit, so a lying server can't fill memory.
            val buffer = Buffer()
            val source = body.source()
            while (buffer.size <= MAX_BLOB) {
                if (source.read(buffer, 64 * 1024) == -1L) break
            }
            if (buffer.size > MAX_BLOB) throw CloudException("That image is too large")
            return buffer.readByteArray()
        }
    }

    private fun error(code: Int) = CloudException(
        when (code) {
            401, 403 -> "OpenScribe Cloud refused this phone. Check that your Mac is still signed in."
            404 -> "That image expired. Copy it again."
            413 -> "That image is too large to send"
            429 -> "OpenScribe Cloud is busy. Try again in a minute."
            else -> "OpenScribe Cloud answered $code"
        },
        code,
    )

    companion object {
        const val MAX_BLOB = BlobCipher.MAX_PLAINTEXT + BlobCipher.OVERHEAD
        private val OCTET_STREAM = "application/octet-stream".toMediaType()
        private val ID = Regex("^[A-Za-z0-9_-]{1,128}$")

        fun isValidId(id: String) = ID.matches(id)

        /** A client suited to the relay and blobs: no overall call timeout, so big images on slow networks finish. */
        fun httpClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}

/** The relay as the client's fallback route, used only while this Mac has a cloud config. */
interface RelayDialer {
    /** What the settings screen shows as the address, or null when there is no relay to try. */
    fun label(): String?

    /** Opens a relay transport with the Mac already on the other end, or throws. */
    fun dial(): FrameTransport
}

class CloudRelayDialer(
    private val http: OkHttpClient,
    pairing: PairingLink,
    private val config: () -> CloudConfig?,
    private val presenceTimeoutMs: Long = 15_000,
) : RelayDialer {
    private val room = LinkProtocol.relayRoom(pairing.secret)

    override fun label(): String? = config()?.let { "OpenScribe Cloud (${it.baseUrl.substringAfter("://").substringBefore('/')})" }

    override fun dial(): FrameTransport {
        val current = config() ?: throw IOException("No OpenScribe Cloud access")
        return RelayFrameTransport.connect(http, current, room, presenceTimeoutMs)
    }
}
