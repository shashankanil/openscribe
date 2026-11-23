package org.opensource.openscribe.link

import org.json.JSONObject
import org.opensource.openscribe.link.LinkMessages.string
import org.opensource.openscribe.speech.SpeechConfig
import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

enum class LinkPhase { STOPPED, LOOKING, CONNECTING, CONNECTED, UNPAIRED, VERSION_MISMATCH }

/** How the link reaches the Mac: directly on the local network, or through the OpenScribe Cloud relay. */
enum class LinkVia { LAN, CLOUD }

data class LinkState(
    val phase: LinkPhase,
    val macName: String,
    /** `host:port` (or the relay) of the current or last attempted endpoint. */
    val endpoint: String? = null,
    /** Why the last attempt failed, for the settings screen. */
    val lastError: String? = null,
    /** The path in use or being tried. */
    val via: LinkVia? = null,
)

/** [target] is the Mac app the text goes to; [pasted] says whether it is pasted there or only saved. */
data class TalkState(
    val id: String,
    val state: String,
    val text: String?,
    val error: String?,
    val target: String? = null,
    val pasted: Boolean? = null,
)

interface LinkListener {
    fun onState(state: LinkState) {}
    /** The Mac sent text for the clipboard. The client acks it after this returns. */
    fun onClip(id: String, text: String) {}
    /** The Mac sent an image. Not acked here: call [LinkClient.ackClip] once it is on the clipboard. */
    fun onImageClip(clip: ImageClip) {}
    /** The Mac granted (or, with null, withdrew) OpenScribe Cloud access for this pairing. */
    fun onCloud(config: CloudConfig?) {}
    /** The Mac shared its transcription settings, or with null, transcription stays on the Mac. */
    fun onSpeech(config: SpeechConfig?) {}
    fun onClipAck(id: String) {}
    fun onTalkState(state: TalkState) {}
}

/** Where to find the Mac. Blocking; may take a few seconds (NSD), and returns endpoints to try in order. */
interface EndpointResolver {
    fun resolve(pairing: PairingLink): List<InetSocketAddress>
    /** Connected: discovery can stop. */
    fun pause() {}
    fun close() {}
}

/** Endpoints straight from the pairing link's `h` hosts. */
class PairingHostsResolver : EndpointResolver {
    override fun resolve(pairing: PairingLink) = pairing.hosts.map { InetSocketAddress(it, pairing.port) }
}

/**
 * Keeps one authenticated, encrypted connection to the paired Mac: resolve, connect, handshake, then read until
 * the link drops, and reconnect with exponential backoff (1 s doubling to 30 s). Pings every 15 s and drops a
 * link that has been silent for 45 s. Tries the local network first and then, if [relay] has somewhere to go,
 * the OpenScribe Cloud relay. Pure JVM so it can be tested against a fake Mac.
 */
class LinkClient(
    val pairing: PairingLink,
    private val deviceName: String,
    private val appVersion: String,
    private val resolver: EndpointResolver,
    private val listener: LinkListener,
    private val pingIntervalMs: Long = 15_000,
    private val silenceTimeoutMs: Int = 45_000,
    private val connectTimeoutMs: Int = 4_000,
    private val handshakeTimeoutMs: Int = 8_000,
    private val maxBackoffMs: Long = 30_000,
    private val relay: RelayDialer? = null,
    private val installId: String? = null,
) {
    private val lock = Object()
    @Volatile private var running = false
    @Volatile private var kicked = false
    @Volatile private var session: Session? = null
    @Volatile private var thread: Thread? = null
    @Volatile var state = LinkState(LinkPhase.STOPPED, pairing.macName)
        private set
    @Volatile var currentTalkId: String? = null
        private set

    val isConnected get() = session?.ready == true
    val macName get() = state.macName

    fun start() {
        synchronized(lock) {
            if (running) return
            running = true
            thread = Thread(::runLoop, "openscribe-link").apply { isDaemon = true; start() }
        }
    }

    fun stop() {
        synchronized(lock) {
            running = false
            lock.notifyAll()
        }
        session?.close()
        thread?.interrupt()
        resolver.close()
        setState(state.copy(phase = LinkPhase.STOPPED))
    }

    /** The network changed: retry now instead of waiting out the backoff. */
    fun kick() {
        synchronized(lock) {
            kicked = true
            lock.notifyAll()
        }
    }

    /** The network went away or changed: drop the current connection (it is dead) and reconnect now. */
    fun reset() {
        session?.close()
        kick()
    }

    enum class ClipResult { SENT, NOT_CONNECTED, TOO_LARGE, EMPTY }

    fun sendClip(text: String, id: String = LinkMessages.newId()): ClipResult {
        if (text.isEmpty()) return ClipResult.EMPTY
        if (text.toByteArray(Charsets.UTF_8).size > LinkProtocol.MAX_CLIPBOARD_BYTES) return ClipResult.TOO_LARGE
        val s = session?.takeIf { it.ready } ?: return ClipResult.NOT_CONNECTED
        s.send(LinkProtocol.messagePlaintext(LinkMessages.clip(id, text)))
        return ClipResult.SENT
    }

    /** Sends an image clip whose sealed bytes are already uploaded as [blob]. */
    fun sendImageClip(id: String, mime: String, blob: String, key: ByteArray, size: Int): ClipResult {
        val s = session?.takeIf { it.ready } ?: return ClipResult.NOT_CONNECTED
        s.send(LinkProtocol.messagePlaintext(LinkMessages.imageClip(id, mime, blob, key, size)))
        return ClipResult.SENT
    }

    /** Confirms a clip from the Mac (images are acked once they are on the clipboard). */
    fun ackClip(id: String) {
        session?.takeIf { it.ready }?.send(LinkProtocol.messagePlaintext(LinkMessages.clipAck(id)))
    }

    /**
     * Starts a talk and returns its id, or null when not connected. With [textMode] the phone transcribes and
     * sends `talk_partial` / `talk_text` instead of audio.
     */
    fun talkStart(textMode: Boolean = false): String? {
        val s = session?.takeIf { it.ready } ?: return null
        val id = LinkMessages.newId()
        currentTalkId = id
        s.send(LinkProtocol.messagePlaintext(if (textMode) LinkMessages.talkStartText(id) else LinkMessages.talkStart(id)))
        return id
    }

    fun talkPartial(id: String, text: String) {
        session?.takeIf { it.ready }?.send(LinkProtocol.messagePlaintext(LinkMessages.talkPartial(id, text)))
    }

    /** The final text of a text-mode talk (it replaces `talk_end`). */
    fun talkText(id: String, text: String) {
        if (currentTalkId == id) currentTalkId = null
        session?.takeIf { it.ready }?.send(LinkProtocol.messagePlaintext(LinkMessages.talkText(id, text)))
    }

    fun sendAudio(pcm: ByteArray, offset: Int = 0, length: Int = pcm.size) {
        if (currentTalkId == null) return
        session?.takeIf { it.ready }?.send(LinkProtocol.audioPlaintext(pcm, offset, length))
    }

    fun talkEnd(id: String) {
        if (currentTalkId == id) currentTalkId = null
        session?.takeIf { it.ready }?.send(LinkProtocol.messagePlaintext(LinkMessages.talkEnd(id)))
    }

    fun talkCancel(id: String) {
        if (currentTalkId == id) currentTalkId = null
        session?.takeIf { it.ready }?.send(LinkProtocol.messagePlaintext(LinkMessages.talkCancel(id)))
    }

    private fun setState(new: LinkState) {
        if (new == state) return
        state = new
        listener.onState(new)
    }

    private fun runLoop() {
        var backoff = 1_000L
        while (running) {
            setState(state.copy(phase = if (state.phase == LinkPhase.UNPAIRED) LinkPhase.UNPAIRED else LinkPhase.LOOKING))
            kicked = false
            val endpoints = try {
                resolver.resolve(pairing)
            } catch (e: Exception) {
                emptyList()
            }.distinctBy { it.hostString to it.port }
            val routes = endpoints.map { endpoint ->
                Route(LinkVia.LAN, "${endpoint.hostString}:${endpoint.port}") {
                    TcpFrameTransport.connect(endpoint, connectTimeoutMs)
                }
            } + listOfNotNull(relay?.let { r -> r.label()?.let { label -> Route(LinkVia.CLOUD, label, r::dial) } })
            var connected: Session? = null
            var lastError: String? = if (routes.isEmpty()) "Mac not found on this network" else null
            for (route in routes) {
                if (!running) break
                val label = route.label
                if (state.phase != LinkPhase.UNPAIRED) setState(state.copy(phase = LinkPhase.CONNECTING, endpoint = label, via = route.via))
                try {
                    connected = Session.open(route, pairing, deviceName, appVersion, handshakeTimeoutMs, installId)
                    break
                } catch (e: LinkRefusedException) {
                    lastError = e.code
                    if (e.code == "unpaired") {
                        setState(state.copy(phase = LinkPhase.UNPAIRED, endpoint = label, lastError = "unpaired"))
                    } else if (e.code == "version") {
                        setState(state.copy(phase = LinkPhase.VERSION_MISMATCH, endpoint = label, lastError = "version"))
                    }
                } catch (e: Exception) {
                    lastError = "$label: ${e.message ?: e.javaClass.simpleName}"
                }
            }
            if (connected != null && running) {
                backoff = 1_000L
                session = connected
                resolver.pause()
                setState(LinkState(LinkPhase.CONNECTED, connected.macName, connected.endpointLabel, null, connected.via))
                val reason = connected.run(pingIntervalMs, silenceTimeoutMs, ::onMessage)
                session = null
                currentTalkId = null
                if (!running) break
                setState(state.copy(phase = LinkPhase.LOOKING, lastError = reason))
                sleepInterruptibly(500)
                continue
            }
            connected?.close()
            if (!running) break
            if (state.phase == LinkPhase.UNPAIRED || state.phase == LinkPhase.VERSION_MISMATCH) {
                setState(state.copy(lastError = lastError))
                sleepInterruptibly(maxBackoffMs)
            } else {
                setState(state.copy(phase = LinkPhase.LOOKING, lastError = lastError))
                sleepInterruptibly(backoff)
                backoff = if (kicked) 1_000L else (backoff * 2).coerceAtMost(maxBackoffMs)
            }
        }
        session?.close()
        session = null
    }

    private fun sleepInterruptibly(ms: Long) {
        val deadline = System.currentTimeMillis() + ms
        synchronized(lock) {
            while (running && !kicked) {
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) break
                try {
                    lock.wait(left)
                } catch (e: InterruptedException) {
                    return
                }
            }
        }
    }

    private fun onMessage(session: Session, message: JSONObject) {
        when (message.optString("t")) {
            "clip" -> {
                val id = message.string("id") ?: return
                when (message.string("kind") ?: "text") {
                    "text" -> {
                        val text = message.string("text") ?: return
                        listener.onClip(id, text)
                        session.send(LinkProtocol.messagePlaintext(LinkMessages.clipAck(id)))
                    }
                    "image" -> {
                        val blob = message.string("blob")?.takeIf(CloudBlobs::isValidId) ?: return
                        val key = message.string("key")?.let(Base64Url::decode)?.takeIf { it.size == BlobCipher.KEY_LENGTH } ?: return
                        val mime = message.string("mime")?.takeIf { it.startsWith("image/") } ?: "image/png"
                        val size = message.optInt("size", -1)
                        listener.onImageClip(ImageClip(id, mime, blob, key, size))
                    }
                    else -> Unit // A kind this version doesn't know.
                }
            }
            "cloud" -> {
                if (!message.has("url") && !message.has("token")) listener.onCloud(null)
                else CloudConfig.fromJson(message)?.let(listener::onCloud)
            }
            // {"t":"speech"} (no provider) clears it; settings the phone can't use clear it too.
            "speech" -> listener.onSpeech(SpeechConfig.fromJson(message))
            "clip_ack" -> message.string("id")?.let(listener::onClipAck)
            "talk_state" -> {
                val id = message.string("id") ?: return
                val st = message.string("state") ?: return
                val pasted = if (message.has("pasted")) message.optBoolean("pasted") else null
                listener.onTalkState(TalkState(id, st, message.string("text"), message.string("error"), message.string("target"), pasted))
            }
            "ping" -> session.send(LinkProtocol.messagePlaintext(JSONObject().put("t", "pong")))
            else -> Unit // pong, ready repeats, and unknown types
        }
    }

    /** One way to reach the Mac; [dial] opens the transport. */
    private class Route(val via: LinkVia, val label: String, val dial: () -> FrameTransport)

    /** One transport after a successful handshake. */
    private class Session(
        private val transport: FrameTransport,
        private val sendCipher: LinkCipher,
        private val recvCipher: LinkCipher,
        val macName: String,
        val endpointLabel: String,
        val via: LinkVia,
    ) {
        @Volatile var ready = true
        private val queue = LinkedBlockingQueue<ByteArray>(4_000)
        private val stopMarker = ByteArray(0)

        fun send(plaintext: ByteArray) {
            if (!ready) return
            if (!queue.offer(plaintext)) close() // The Mac stopped reading for minutes: give up on this link.
        }

        fun close() {
            ready = false
            queue.offer(stopMarker)
            transport.close()
        }

        /** Reads until the link drops. Returns why it dropped. */
        fun run(pingIntervalMs: Long, silenceTimeoutMs: Int, onMessage: (Session, JSONObject) -> Unit): String {
            val writer = Thread({ writeLoop(pingIntervalMs) }, "openscribe-link-writer").apply { isDaemon = true; start() }
            try {
                transport.readTimeoutMs = silenceTimeoutMs
                while (ready) {
                    val plain = recvCipher.open(transport.readFrame())
                    if (plain.isEmpty()) continue
                    if (plain[0] == LinkProtocol.KIND_MESSAGE) {
                        LinkMessages.parse(plain, 1)?.let { onMessage(this, it) }
                    }
                    // Audio from the Mac is not part of v1: ignore it.
                }
                return "closed"
            } catch (e: SocketTimeoutException) {
                return "Mac stopped responding"
            } catch (e: EOFException) {
                return "Mac closed the connection"
            } catch (e: Exception) {
                return e.message ?: e.javaClass.simpleName
            } finally {
                close()
                writer.interrupt()
            }
        }

        private fun writeLoop(pingIntervalMs: Long) {
            var nextPing = System.currentTimeMillis() + pingIntervalMs
            try {
                while (ready) {
                    val wait = nextPing - System.currentTimeMillis()
                    val item = if (wait > 0) queue.poll(wait, TimeUnit.MILLISECONDS) else null
                    if (item === stopMarker) break
                    val plain = item ?: LinkProtocol.messagePlaintext(LinkMessages.ping()).also {
                        nextPing = System.currentTimeMillis() + pingIntervalMs
                    }
                    transport.writeFrame(sendCipher.seal(plain))
                    if (queue.isEmpty()) transport.flush()
                }
            } catch (_: InterruptedException) {
            } catch (_: IOException) {
            } finally {
                close()
            }
        }

        companion object {
            fun open(
                route: Route,
                pairing: PairingLink,
                deviceName: String,
                appVersion: String,
                handshakeTimeoutMs: Int,
                installId: String? = null,
            ): Session {
                val transport = route.dial()
                try {
                    return handshake(transport, pairing, deviceName, appVersion, handshakeTimeoutMs, route.label, route.via, installId)
                } catch (e: Exception) {
                    transport.close()
                    throw e
                }
            }

            /** Runs the hello / welcome / auth / ready handshake from docs/PHONE-LINK.md over [transport]. */
            fun handshake(
                transport: FrameTransport,
                pairing: PairingLink,
                deviceName: String,
                appVersion: String,
                handshakeTimeoutMs: Int,
                label: String,
                via: LinkVia,
                installId: String? = null,
            ): Session {
                transport.readTimeoutMs = handshakeTimeoutMs
                val clientNonce = LinkProtocol.randomBytes(LinkProtocol.NONCE_LENGTH)
                transport.writeFrame(LinkMessages.hello(pairing.deviceId, clientNonce).toString().toByteArray(Charsets.UTF_8))
                transport.flush()

                val reply = try {
                    LinkMessages.parse(transport.readFrame())
                } catch (e: EOFException) {
                    throw IOException("Mac closed the connection during hello")
                } ?: throw LinkProtocolException("bad welcome")
                when (reply.optString("t")) {
                    "error" -> throw LinkRefusedException(reply.string("code") ?: "error")
                    "welcome" -> Unit
                    else -> throw LinkProtocolException("unexpected ${reply.optString("t")}")
                }
                if (reply.optInt("v", -1) != LinkProtocol.VERSION) throw LinkRefusedException("version")
                if (reply.string("mac") != pairing.macId) throw LinkProtocolException("a different Mac answered")
                val serverNonce = reply.string("nonce")?.let(Base64Url::decode)
                    ?.takeIf { it.size == LinkProtocol.NONCE_LENGTH } ?: throw LinkProtocolException("bad nonce")

                val keys = LinkProtocol.sessionKeys(pairing.secret, clientNonce, serverNonce)
                val sendCipher = LinkCipher(keys.clientToServer)
                val recvCipher = LinkCipher(keys.serverToClient)

                transport.writeFrame(sendCipher.seal(LinkProtocol.messagePlaintext(LinkMessages.auth(deviceName, appVersion, installId))))
                transport.flush()

                val readyFrame = try {
                    transport.readFrame()
                } catch (e: EOFException) {
                    throw IOException("Mac rejected this phone's key. Pair again.")
                }
                val plain = try {
                    recvCipher.open(readyFrame)
                } catch (e: LinkProtocolException) {
                    // A plaintext error after auth means the Mac could not verify us.
                    LinkMessages.parse(readyFrame)?.takeIf { it.optString("t") == "error" }?.let {
                        throw LinkRefusedException(it.string("code") ?: "error")
                    }
                    throw e
                }
                if (plain.isEmpty() || plain[0] != LinkProtocol.KIND_MESSAGE) throw LinkProtocolException("expected ready")
                val ready = LinkMessages.parse(plain, 1)
                if (ready?.optString("t") != "ready") throw LinkProtocolException("expected ready")
                val name = ready.string("name")?.takeIf { it.isNotBlank() } ?: pairing.macName
                return Session(transport, sendCipher, recvCipher, name, label, via)
            }
        }
    }
}
