package org.opensource.openscribe.speech

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * One realtime WebSocket per talk, for the transports in [RealtimeProtocol]. Opened on [start]; audio recorded
 * before the provider is ready waits in memory. Audio goes out in 100 ms packets (resampled to 24 kHz for OpenAI),
 * like the Mac's `LiveAudioSink`. Partial text is reported on every event; [finish] ends the stream and the final
 * text arrives when the provider says it is done. Gives up with onError if setup takes longer than
 * [setupTimeoutMs] or the final text longer than [finishTimeoutMs].
 */
class StreamingTranscriber(
    private val http: OkHttpClient,
    private val config: SpeechConfig,
    private val listener: TranscriberListener,
    private val endpoint: String? = null,
    private val setupTimeoutMs: Long = 10_000,
    private val finishTimeoutMs: Long = 15_000,
) : Transcriber {
    private val transport = config.streaming ?: throw IllegalArgumentException("not a streaming config")
    private val lock = Any()
    private val transcript = RealtimeTranscript(transport)
    private val resampler = if (RealtimeProtocol.sampleRate(transport) != 16_000) LinearResampler(16_000, RealtimeProtocol.sampleRate(transport)) else null
    private val packetBytes = RealtimeProtocol.sampleRate(transport) / 10 * 2
    private val packet = ByteArrayOutputStream(packetBytes * 2)
    private val waiting = ArrayList<ByteArray>()
    private val timers: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "openscribe-speech-timer").apply { isDaemon = true }
    }
    private var socket: WebSocket? = null
    /** The event the provider must send next during setup; null once audio can flow. */
    private var expecting: String? = null
    private var ready = false
    private var finishRequested = false
    private var ended = false
    private var over = false
    private var pendingBytes = 0
    private var commits = 0

    override fun start() {
        val request = Request.Builder()
            .url(RealtimeProtocol.url(transport, config.model, config.terms, endpoint ?: RealtimeProtocol.endpoint(transport)))
            .header("Authorization", RealtimeProtocol.authorization(transport, config.key))
            .build()
        synchronized(lock) {
            expecting = RealtimeProtocol.greeting(transport)
            socket = http.newWebSocket(request, Events())
        }
        timers.schedule({ synchronized(lock) { !ready && !over }.let { if (it) fail(SpeechException("Live transcription didn't start")) } },
            setupTimeoutMs, TimeUnit.MILLISECONDS)
    }

    override fun feed(pcm: ByteArray, offset: Int, length: Int) {
        synchronized(lock) {
            if (over || finishRequested) return
            val bytes = resampler?.let { Pcm.toBytes(it.process(Pcm.toShorts(pcm, offset, length))) } ?: pcm.copyOfRange(offset, offset + length)
            packet.write(bytes)
            while (packet.size() >= packetBytes) {
                val all = packet.toByteArray()
                deliver(all.copyOfRange(0, packetBytes))
                packet.reset()
                packet.write(all, packetBytes, all.size - packetBytes)
            }
        }
    }

    override fun finish() {
        synchronized(lock) {
            if (over || finishRequested) return
            finishRequested = true
            if (packet.size() > 0) {
                deliver(packet.toByteArray())
                packet.reset()
            }
            if (ready) sendEnd()
        }
        timers.schedule({ fail(SpeechException("Live transcription didn't finish")) }, finishTimeoutMs, TimeUnit.MILLISECONDS)
    }

    override fun cancel() {
        val ws = synchronized(lock) {
            if (over) return
            over = true
            socket
        }
        ws?.cancel()
        timers.shutdownNow()
    }

    /** Under [lock]. */
    private fun deliver(bytes: ByteArray) {
        if (ready) sendAudio(bytes) else waiting.add(bytes)
    }

    /** Under [lock]. */
    private fun sendAudio(bytes: ByteArray) {
        val ws = socket ?: return
        val message = RealtimeProtocol.audioMessage(transport, bytes)
        if (message == null) ws.send(bytes.toByteString()) else ws.send(message.toString())
        if (transport == StreamingTransport.OPENAI) {
            pendingBytes += bytes.size
            if (RealtimeProtocol.commitsPeriodically(transport, config.model) && pendingBytes >= RealtimeProtocol.OPENAI_COMMIT_BYTES) {
                commits++
                pendingBytes = 0
                ws.send(RealtimeProtocol.commit().toString())
            }
        }
    }

    /** Under [lock]. */
    private fun sendEnd() {
        if (ended) return
        val ws = socket ?: return
        RealtimeProtocol.end(transport, pendingBytes).forEach { ws.send(it.toString()) }
        if (transport == StreamingTransport.OPENAI) commits++
        ended = true
    }

    /** Under [lock]: audio can flow. */
    private fun becomeReady() {
        ready = true
        expecting = null
        waiting.forEach(::sendAudio)
        waiting.clear()
        if (finishRequested) sendEnd()
    }

    private fun onEvent(event: JSONObject) {
        var partial: String? = null
        var final: String? = null
        try {
            synchronized(lock) {
                if (over) return
                val expected = expecting
                if (!ready && expected != null) {
                    val type = event.optString("type")
                    if (type != expected) throw SpeechException("Live transcription setup failed")
                    if (expected != RealtimeProtocol.SESSION_UPDATED) {
                        val update = RealtimeProtocol.sessionUpdate(transport, config.model, config.terms)
                        if (update != null) {
                            socket?.send(update.toString())
                            expecting = RealtimeProtocol.SESSION_UPDATED
                            return
                        }
                    }
                    becomeReady()
                    return
                }
                transcript.consume(event)
                partial = transcript.text
                val done = if (transport == StreamingTransport.OPENAI) ended && transcript.completed.size >= commits else transcript.terminal
                if (done) {
                    if (!ended) throw SpeechException("Live transcription ended early")
                    over = true
                    final = transcript.text.trim()
                }
            }
        } catch (e: SpeechException) {
            fail(e)
            return
        }
        final?.let {
            socket?.close(1000, null)
            timers.shutdownNow()
            listener.onFinal(it)
            return
        }
        partial?.let(listener::onPartial)
    }

    private fun fail(error: Exception) {
        val ws = synchronized(lock) {
            if (over) return
            over = true
            socket
        }
        ws?.cancel()
        timers.shutdownNow()
        listener.onError(error)
    }

    private inner class Events : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            synchronized(lock) { if (!over && expecting == null && !ready) becomeReady() }
        }

        override fun onMessage(webSocket: WebSocket, text: String) = handle(text)

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handle(bytes.utf8())

        private fun handle(text: String) {
            val event = try { JSONObject(text) } catch (e: Exception) {
                fail(SpeechException("Live transcription sent an unreadable event"))
                return
            }
            onEvent(event)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            fail(SpeechException("Live transcription closed ($code)"))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            fail(SpeechException("Live transcription failed: ${response?.code ?: t.javaClass.simpleName}", response?.code))
        }
    }
}
