package org.opensource.openscribe.link

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Carries whole frame payloads between the phone and the Mac. A link session (handshake, encryption, pings) runs
 * the same over any transport: TCP on the local network, or the OpenScribe Cloud relay.
 */
interface FrameTransport {
    /**
     * Blocks for the next frame payload. Throws [SocketTimeoutException] after [readTimeoutMs] of silence
     * (0 waits forever), and another [IOException] once the connection is gone.
     */
    fun readFrame(): ByteArray

    /** Queues one frame payload. It may sit in a buffer until [flush]. */
    fun writeFrame(payload: ByteArray)

    fun flush() {}

    var readTimeoutMs: Int

    /** Idempotent, and unblocks a pending [readFrame]. */
    fun close()
}

/** The connection is gone, for a reason worth showing (for example the Mac left the relay). */
class ConnectionLostException(message: String) : IOException(message)

/** The local-network transport: 4-byte big-endian length, then the payload. */
class TcpFrameTransport(private val socket: Socket) : FrameTransport {
    private val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
    private val output = BufferedOutputStream(socket.getOutputStream())

    override var readTimeoutMs: Int
        get() = socket.soTimeout
        set(value) { socket.soTimeout = value }

    override fun readFrame(): ByteArray = LinkProtocol.readFrame(input)

    override fun writeFrame(payload: ByteArray) = output.write(LinkProtocol.frame(payload))

    override fun flush() = output.flush()

    override fun close() {
        try { socket.close() } catch (_: IOException) {}
    }

    companion object {
        fun connect(endpoint: InetSocketAddress, connectTimeoutMs: Int): TcpFrameTransport {
            val socket = Socket()
            try {
                socket.tcpNoDelay = true
                socket.keepAlive = true
                socket.connect(endpoint, connectTimeoutMs)
                return TcpFrameTransport(socket)
            } catch (e: Exception) {
                try { socket.close() } catch (_: IOException) {}
                throw e
            }
        }
    }
}

/**
 * The OpenScribe Cloud relay: a WebSocket to `<url>/api/v1/link/relay/<room>` with the phone token. Each binary
 * message is one frame payload (no length prefix). The Worker reports the Mac with `{"t":"peer","present":…}`;
 * [connect] returns once the Mac is there, and the Mac leaving (or its socket being replaced) ends the transport.
 * Sends the text keepalive `ping` every [pingIntervalMs].
 */
class RelayFrameTransport private constructor() : FrameTransport {
    private val events = LinkedBlockingQueue<Any>()
    private val present = CountDownLatch(1)
    @Volatile private var peerSeen = false
    @Volatile private var failure: String? = null
    @Volatile private var closed = false
    @Volatile private var socket: WebSocket? = null
    private var pinger: ScheduledFuture<*>? = null

    override var readTimeoutMs: Int = 0

    private class Lost(val reason: String)

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            if (text == "pong") return
            val message = try { JSONObject(text) } catch (e: Exception) { return }
            if (message.optString("t") != "peer") return
            val isPresent = message.optBoolean("present", false)
            when {
                isPresent && !peerSeen -> {
                    peerSeen = true
                    present.countDown()
                }
                // A second "present" means the Mac's socket was replaced, so its end of our session is gone.
                isPresent -> lose("The Mac reconnected to OpenScribe Cloud")
                peerSeen -> lose("The Mac left OpenScribe Cloud")
                // Not there yet: keep waiting for it in connect().
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            if (!peerSeen) return
            if (bytes.size > LinkProtocol.MAX_FRAME_LENGTH) {
                lose("frame too large (${bytes.size} bytes)")
                webSocket.cancel()
                return
            }
            events.offer(bytes.toByteArray())
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            fail(if (code == 4000) "Another connection replaced this one" else "OpenScribe Cloud closed the relay ($code)")
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            fail("OpenScribe Cloud closed the relay ($code)")
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val code = response?.code
            fail(
                when (code) {
                    401, 403 -> "OpenScribe Cloud refused this phone ($code)"
                    null -> "OpenScribe Cloud: ${t.message ?: t.javaClass.simpleName}"
                    else -> "OpenScribe Cloud answered $code"
                }
            )
        }
    }

    private fun lose(reason: String) {
        events.offer(Lost(reason))
    }

    private fun fail(reason: String) {
        if (failure == null) failure = reason
        lose(reason)
        present.countDown()
    }

    override fun readFrame(): ByteArray {
        val event = if (readTimeoutMs > 0) {
            events.poll(readTimeoutMs.toLong(), TimeUnit.MILLISECONDS) ?: throw SocketTimeoutException("relay silent")
        } else events.take()
        if (event is Lost) {
            events.offer(event) // Later reads fail the same way.
            throw ConnectionLostException(event.reason)
        }
        return event as ByteArray
    }

    override fun writeFrame(payload: ByteArray) {
        require(payload.size <= LinkProtocol.MAX_FRAME_LENGTH) { "frame too large" }
        val ws = socket ?: throw IOException("relay not open")
        if (closed || !ws.send(payload.toByteString())) throw ConnectionLostException("relay closed")
    }

    override fun close() {
        if (closed) return
        closed = true
        pinger?.cancel(false)
        socket?.close(1000, null)
        lose("closed")
        present.countDown()
    }

    companion object {
        private val scheduler = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "openscribe-relay-ping").apply { isDaemon = true }
        }

        fun relayUrl(config: CloudConfig, room: String) = "${config.baseUrl}/api/v1/link/relay/$room"

        /**
         * Opens the relay socket and waits up to [presenceTimeoutMs] for the Mac to be on the other end.
         * Throws [IOException] if the socket fails or the Mac doesn't show up.
         */
        fun connect(
            http: OkHttpClient,
            config: CloudConfig,
            room: String,
            presenceTimeoutMs: Long,
            pingIntervalMs: Long = 30_000,
        ): RelayFrameTransport {
            val transport = RelayFrameTransport()
            val request = Request.Builder()
                .url(relayUrl(config, room))
                .header("Authorization", "Bearer ${config.token}")
                .build()
            transport.socket = http.newWebSocket(request, transport.listener)
            val arrived = try {
                transport.present.await(presenceTimeoutMs, TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) {
                transport.close()
                throw IOException("interrupted")
            }
            val failure = transport.failure
            if (!arrived || !transport.peerSeen || failure != null || transport.closed) {
                transport.close()
                throw IOException(failure ?: "The Mac isn't connected to OpenScribe Cloud")
            }
            transport.pinger = scheduler.scheduleWithFixedDelay(
                { if (!transport.closed) transport.socket?.send("ping") },
                pingIntervalMs, pingIntervalMs, TimeUnit.MILLISECONDS,
            )
            return transport
        }
    }
}
