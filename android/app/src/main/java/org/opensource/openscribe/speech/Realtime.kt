package org.opensource.openscribe.speech

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/**
 * The realtime transcription wire formats, exactly as the Mac speaks them (Sources/OpenScribe/StreamingCapability.swift
 * and RealtimeTranscription.swift): endpoints, query parameters, auth, session setup, audio framing, and the end
 * of the stream. Pure, so every builder is unit tested.
 */
object RealtimeProtocol {
    /** OpenAI's newer live models emit text without commits; the rest need one every 2 s of audio. */
    private val LIVE_OPENAI_MODELS = setOf("gpt-live-transcribe", "gpt-realtime-whisper")
    /** 2 s of 24 kHz PCM16. */
    const val OPENAI_COMMIT_BYTES = 96_000
    /** 100 ms of 24 kHz PCM16: the least OpenAI accepts in a commit. */
    const val OPENAI_MIN_COMMIT_BYTES = 4_800

    fun endpoint(transport: StreamingTransport): String = when (transport) {
        StreamingTransport.OPENAI -> "wss://api.openai.com/v1/realtime"
        StreamingTransport.MISTRAL -> "wss://api.mistral.ai/v1/audio/transcriptions/realtime"
        StreamingTransport.DEEPGRAM -> "wss://api.deepgram.com/v1/listen"
        StreamingTransport.ASSEMBLYAI -> "wss://streaming.assemblyai.com/v3/ws"
    }

    fun sampleRate(transport: StreamingTransport): Int = if (transport == StreamingTransport.OPENAI) 24_000 else 16_000

    /** The socket URL with its query; [base] replaces the provider endpoint in tests. */
    fun url(transport: StreamingTransport, model: String, terms: List<String>, base: String = endpoint(transport)): HttpUrl {
        // OkHttp wants http(s); it upgrades ws(s) URLs the same way.
        val builder = base.replaceFirst(Regex("^ws", RegexOption.IGNORE_CASE), "http").toHttpUrl().newBuilder()
        when (transport) {
            StreamingTransport.OPENAI -> builder.addQueryParameter("intent", "transcription")
            StreamingTransport.MISTRAL -> builder.addQueryParameter("model", model)
            StreamingTransport.DEEPGRAM -> {
                listOf(
                    "model" to model, "encoding" to "linear16", "sample_rate" to "16000", "channels" to "1",
                    "interim_results" to "true", "smart_format" to "true",
                ).forEach { (k, v) -> builder.addQueryParameter(k, v) }
                val hintName = if (model.startsWith("nova-3")) "keyterm" else "keywords"
                terms.forEach { builder.addQueryParameter(hintName, it) }
            }
            StreamingTransport.ASSEMBLYAI -> {
                listOf("speech_model" to model, "sample_rate" to "16000", "encoding" to "pcm_s16le", "format_turns" to "true")
                    .forEach { (k, v) -> builder.addQueryParameter(k, v) }
                if (terms.isNotEmpty()) builder.addQueryParameter("keyterms_prompt", JSONArray(terms).toString())
            }
        }
        return builder.build()
    }

    fun authorization(transport: StreamingTransport, apiKey: String): String {
        val key = apiKey.trim()
        return when (transport) {
            StreamingTransport.DEEPGRAM -> Hints.deepgramAuthorization(key)
            StreamingTransport.ASSEMBLYAI -> key
            else -> "Bearer $key"
        }
    }

    /** The event the provider sends first, before it takes audio; null when audio can flow right away. */
    fun greeting(transport: StreamingTransport): String? = when (transport) {
        StreamingTransport.OPENAI, StreamingTransport.MISTRAL -> "session.created"
        StreamingTransport.ASSEMBLYAI -> "Begin"
        StreamingTransport.DEEPGRAM -> null
    }

    /** What to send after the greeting, and the event that confirms it; null when the greeting is enough. */
    fun sessionUpdate(transport: StreamingTransport, model: String, terms: List<String>): JSONObject? = when (transport) {
        StreamingTransport.MISTRAL -> JSONObject().put("type", "session.update").put(
            "session", JSONObject().put("audio_format", JSONObject().put("encoding", "pcm_s16le").put("sample_rate", 16000)),
        )
        StreamingTransport.OPENAI -> {
            val transcription = JSONObject().put("model", model)
            Hints.prompt(terms)?.let { transcription.put("prompt", it) }
            JSONObject().put("type", "session.update").put(
                "session", JSONObject().put("type", "transcription").put(
                    "audio", JSONObject().put(
                        "input", JSONObject()
                            .put("format", JSONObject().put("type", "audio/pcm").put("rate", 24000))
                            .put("transcription", transcription)
                            .put("turn_detection", JSONObject.NULL),
                    ),
                ),
            )
        }
        else -> null
    }

    const val SESSION_UPDATED = "session.updated"

    /** A JSON text message carrying [pcm], or null for transports that take binary frames. */
    fun audioMessage(transport: StreamingTransport, pcm: ByteArray): JSONObject? = when (transport) {
        StreamingTransport.MISTRAL -> JSONObject().put("type", "input_audio.append").put("audio", Base64.getEncoder().encodeToString(pcm))
        StreamingTransport.OPENAI -> JSONObject().put("type", "input_audio_buffer.append").put("audio", Base64.getEncoder().encodeToString(pcm))
        else -> null
    }

    fun commitsPeriodically(transport: StreamingTransport, model: String) =
        transport == StreamingTransport.OPENAI && model !in LIVE_OPENAI_MODELS

    fun commit(): JSONObject = JSONObject().put("type", "input_audio_buffer.commit")

    /**
     * The messages that end the audio. For OpenAI, [pendingBytes] is the audio since the last commit: a commit
     * needs at least 100 ms, so a short tail is padded with silence first.
     */
    fun end(transport: StreamingTransport, pendingBytes: Int): List<JSONObject> = when (transport) {
        StreamingTransport.OPENAI -> buildList {
            if (pendingBytes < OPENAI_MIN_COMMIT_BYTES) add(audioMessage(transport, ByteArray(OPENAI_MIN_COMMIT_BYTES - pendingBytes))!!)
            add(commit())
        }
        StreamingTransport.MISTRAL -> listOf(JSONObject().put("type", "input_audio.end"))
        StreamingTransport.DEEPGRAM -> listOf(JSONObject().put("type", "CloseStream"))
        StreamingTransport.ASSEMBLYAI -> listOf(JSONObject().put("type", "Terminate"))
    }
}

/**
 * Turns provider events into the text heard so far, the Mac's `RealtimeTranscript` reducer: partial revisions,
 * final replacements, and the terminal event. Not thread-safe.
 */
class RealtimeTranscript(private val transport: StreamingTransport) {
    var text = ""
        private set
    private val finalParts = HashMap<String, String>()
    private val order = ArrayList<String>()
    val completed = HashSet<String>()
    var terminal = false
        private set

    /** Throws [SpeechException] when the provider reports an error. */
    fun consume(event: JSONObject) {
        val type = event.optString("type")
        if (type == "error" || type == "Error" || type.endsWith(".failed")) {
            throw SpeechException("Live transcription was rejected")
        }
        when (transport) {
            StreamingTransport.MISTRAL -> {
                if (type == "transcription.text.delta") text += event.optString("text")
                if (type == "transcription.done") {
                    text = if (event.has("text") && !event.isNull("text")) event.optString("text") else text
                    terminal = true
                }
            }
            StreamingTransport.DEEPGRAM -> {
                if (type == "Results") {
                    val transcript = event.optJSONObject("channel")?.optJSONArray("alternatives")?.optJSONObject(0)
                        ?.takeIf { it.has("transcript") }?.optString("transcript")
                    if (transcript != null) {
                        val key = event.optDouble("start", 0.0).let { if (it.isNaN()) 0.0 else it }.toString()
                        if (event.optBoolean("is_final", false)) {
                            if (key !in order) order.add(key)
                            finalParts[key] = transcript
                            text = order.mapNotNull { finalParts[it] }.joinToString(" ")
                        } else {
                            text = (order.mapNotNull { finalParts[it] } + transcript).joinToString(" ")
                        }
                    }
                }
                if (type == "Metadata") {
                    terminal = true
                    text = order.mapNotNull { finalParts[it] }.joinToString(" ")
                }
            }
            StreamingTransport.ASSEMBLYAI -> {
                if (type == "Turn" && event.opt("turn_order") is Number && event.opt("transcript") is String) {
                    finalParts[event.getInt("turn_order").toString()] = event.getString("transcript")
                    text = finalParts.keys.sortedBy { it.toIntOrNull() ?: 0 }.mapNotNull { finalParts[it] }.joinToString(" ")
                }
                if (type == "Termination") terminal = true
            }
            StreamingTransport.OPENAI -> {
                val id = event.opt("item_id") as? String
                if (type == "input_audio_buffer.committed" && id != null && id !in order) order.add(id)
                if (id != null) {
                    if (id !in order) order.add(id)
                    if (type == "conversation.item.input_audio_transcription.delta" && id !in completed) {
                        finalParts[id] = (finalParts[id] ?: "") + event.optString("delta")
                    }
                    if (type == "conversation.item.input_audio_transcription.completed") {
                        finalParts[id] = event.optString("transcript")
                        completed.add(id)
                    }
                    text = order.mapNotNull { finalParts[it] }.joinToString(" ")
                }
            }
        }
    }
}
