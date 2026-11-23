package org.opensource.openscribe.speech

import okhttp3.OkHttpClient
import java.io.IOException
import java.util.concurrent.TimeUnit

/** What a [Transcriber] reports. Called on its own threads; never while it holds a lock of its own. */
interface TranscriberListener {
    /** Everything heard so far (it may revise earlier words). */
    fun onPartial(text: String)
    /** The final transcript, after [Transcriber.finish]. At most one of [onFinal] and [onError] is called, once. */
    fun onFinal(text: String)
    fun onError(error: Exception)
}

/**
 * Transcribes one talk on the phone. Audio is 16 kHz mono PCM16 little-endian, fed as it is recorded.
 * Implementations copy what they keep: the caller reuses its buffer.
 */
interface Transcriber {
    fun start()
    fun feed(pcm: ByteArray, offset: Int, length: Int)
    /** No more audio: report [TranscriberListener.onFinal] (or onError) when the text is ready. */
    fun finish()
    /** Stops without any further callbacks. */
    fun cancel()
}

/** A transcription request failed. Messages never contain the API key. */
class SpeechException(message: String, val status: Int? = null) : IOException(message) {
    /** Worth one more try: network trouble, rate limits and server errors, but not a refused key. */
    val retryable: Boolean get() = status == null || status == 408 || status == 429 || status >= 500
}

object Transcribers {
    /** How the phone handles talks for a Mac's speech settings. */
    enum class Mode { STREAMING, CHUNKED, MAC }

    fun mode(config: SpeechConfig?): Mode = when {
        config == null -> Mode.MAC
        config.streaming != null -> Mode.STREAMING
        // AssemblyAI's file API uploads, then polls for a job: slower than letting the Mac do it.
        config.provider == SpeechConfig.ASSEMBLYAI -> Mode.MAC
        else -> Mode.CHUNKED
    }

    /** A factory for this talk's transcriber, or null when the audio should go to the Mac as before. */
    fun factory(config: SpeechConfig?, http: OkHttpClient): ((TranscriberListener) -> Transcriber)? {
        if (config == null) return null
        return when (mode(config)) {
            Mode.STREAMING -> { listener -> StreamingTranscriber(http, config, listener) }
            Mode.CHUNKED -> {
                val files = FileTranscriber(http, config)
                return { listener -> ChunkedTranscriber(files::transcribe, listener) }
            }
            Mode.MAC -> null
        }
    }

    /** Short timeouts: a stalled request should fall back to the Mac quickly, not hang the talk. */
    fun httpClient(base: OkHttpClient): OkHttpClient = base.newBuilder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .callTimeout(45, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()
}
