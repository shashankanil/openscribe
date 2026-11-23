package org.opensource.openscribe.speech

import org.json.JSONArray
import org.json.JSONObject
import org.opensource.openscribe.link.LinkMessages.string

/** The Mac's realtime transports (`StreamingCapability.Transport`), by their wire names. */
enum class StreamingTransport(val wire: String) {
    OPENAI("openAI"),
    MISTRAL("mistral"),
    DEEPGRAM("deepgram"),
    ASSEMBLYAI("assemblyAI");

    companion object {
        fun fromWire(name: String?): StreamingTransport? = entries.firstOrNull { it.wire == name }
    }
}

/**
 * The transcription connection a Mac shares with this phone (`{"t":"speech",…}` in docs/PHONE-LINK.md), so the
 * phone can transcribe while you speak and send the Mac only text. [key] is the Mac's transcription API key: it
 * is stored encrypted, never logged, and left out of [toString].
 */
data class SpeechConfig(
    val provider: String,
    val url: String,
    val model: String,
    val key: String,
    val streaming: StreamingTransport?,
    val terms: List<String>,
) {
    /** The base URL without trailing slashes or whitespace, as the Mac joins paths onto it. */
    val baseUrl: String get() = url.trim().trimEnd('/')

    override fun toString() =
        "SpeechConfig(provider=$provider, url=$url, model=$model, streaming=${streaming?.wire}, terms=${terms.size})"

    fun toJson(): JSONObject = JSONObject()
        .put("provider", provider).put("url", url).put("model", model).put("key", key)
        .put("streaming", streaming?.wire ?: JSONObject.NULL)
        .put("terms", JSONArray(terms))

    companion object {
        const val OPEN_ROUTER = "openRouter"
        const val OPENAI = "openAI"
        const val GROQ = "groq"
        const val DEEPGRAM = "deepgram"
        const val ASSEMBLYAI = "assemblyAI"
        const val MISTRAL = "mistral"
        const val CUSTOM = "custom"
        val PROVIDERS = setOf(OPEN_ROUTER, OPENAI, GROQ, DEEPGRAM, ASSEMBLYAI, MISTRAL, CUSTOM)
        private const val MAX_TERMS = 100

        /**
         * Reads a `speech` message (or a stored config). Returns null for `{"t":"speech"}` and for anything the phone
         * can't use: an unknown provider, a URL that isn't https, or a missing model or key. Callers treat null as
         * "transcription stays on the Mac".
         */
        fun fromJson(json: JSONObject): SpeechConfig? {
            val provider = json.string("provider")?.trim()?.takeIf { it in PROVIDERS } ?: return null
            val url = json.string("url")?.trim()?.takeIf(::isValidUrl) ?: return null
            val model = json.string("model")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val key = json.string("key")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val terms = json.optJSONArray("terms")?.let { array ->
                (0 until array.length()).mapNotNull { array.opt(it) as? String }
                    .map { it.trim() }.filter { it.isNotEmpty() }.distinct().take(MAX_TERMS)
            } ?: emptyList()
            return SpeechConfig(provider, url, model, key, StreamingTransport.fromWire(json.string("streaming")), terms)
        }

        /** Cleartext would expose the key, and Android blocks it anyway. */
        fun isValidUrl(url: String) =
            url.startsWith("https://", ignoreCase = true) && url.length > "https://".length && url.none { it.isWhitespace() }
    }
}
