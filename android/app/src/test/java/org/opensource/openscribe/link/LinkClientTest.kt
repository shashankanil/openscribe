package org.opensource.openscribe.link

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.opensource.openscribe.speech.SpeechConfig
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Two in-memory frame transports joined back to back, standing in for the relay. */
class MemoryTransport private constructor(
    private val inbox: LinkedBlockingQueue<Any>,
    private val outbox: LinkedBlockingQueue<Any>,
) : FrameTransport {
    @Volatile private var closed = false
    override var readTimeoutMs: Int = 0

    override fun readFrame(): ByteArray {
        val event = if (readTimeoutMs > 0) {
            inbox.poll(readTimeoutMs.toLong(), TimeUnit.MILLISECONDS) ?: throw SocketTimeoutException()
        } else inbox.take()
        if (event === CLOSED) {
            inbox.offer(CLOSED)
            throw EOFException()
        }
        return event as ByteArray
    }

    override fun writeFrame(payload: ByteArray) {
        if (closed) throw IOException("closed")
        outbox.offer(payload.copyOf())
    }

    override fun close() {
        if (closed) return
        closed = true
        inbox.offer(CLOSED)
        outbox.offer(CLOSED)
    }

    companion object {
        private val CLOSED = Any()

        fun pair(): Pair<MemoryTransport, MemoryTransport> {
            val a = LinkedBlockingQueue<Any>()
            val b = LinkedBlockingQueue<Any>()
            return MemoryTransport(a, b) to MemoryTransport(b, a)
        }
    }
}

/** Runs the real client against a minimal fake Mac that speaks the protocol from the server side. */
class LinkClientTest {
    private val secret = LinkProtocol.randomBytes(32)
    private val server = ServerSocket(0, 5, InetAddress.getLoopbackAddress())
    private val pairing = PairingLink("MAC-1", "Fake Mac", "DEV-1", secret, listOf("127.0.0.1"), server.localPort)
    private var client: LinkClient? = null

    @After fun tearDown() {
        client?.stop()
        server.close()
    }

    private class FakeMac(val transport: FrameTransport, secret: ByteArray, macId: String, refuse: String? = null) {
        val hello: JSONObject = LinkMessages.parse(transport.readFrame())!!
        lateinit var auth: JSONObject
        private lateinit var send: LinkCipher
        private lateinit var recv: LinkCipher

        init {
            if (refuse != null) {
                write(JSONObject().put("t", "error").put("code", refuse).toString().toByteArray())
                transport.close()
            } else {
                val serverNonce = LinkProtocol.randomBytes(16)
                write(JSONObject().put("t", "welcome").put("v", 1).put("mac", macId)
                    .put("nonce", Base64Url.encode(serverNonce)).toString().toByteArray())
                val keys = LinkProtocol.sessionKeys(secret, Base64Url.decode(hello.getString("nonce"))!!, serverNonce)
                recv = LinkCipher(keys.clientToServer)
                send = LinkCipher(keys.serverToClient)
                auth = receive()!!
                sendMessage(JSONObject().put("t", "ready").put("name", "Fake Mac Pro").put("clipboard", true))
            }
        }

        private fun write(payload: ByteArray) {
            transport.writeFrame(payload)
            transport.flush()
        }

        fun sendMessage(message: JSONObject) = write(send.seal(LinkProtocol.messagePlaintext(message)))

        /** The next message; audio frames are counted and skipped. */
        var audioBytes = 0
        fun receive(): JSONObject? {
            while (true) {
                val plain = recv.open(transport.readFrame())
                if (plain[0] == LinkProtocol.KIND_AUDIO) { audioBytes += plain.size - 1; continue }
                return LinkMessages.parse(plain, 1)
            }
        }
    }

    private class Recorder : LinkListener {
        val states = LinkedBlockingQueue<LinkState>()
        val clips = LinkedBlockingQueue<String>()
        val talk = LinkedBlockingQueue<TalkState>()
        val images = LinkedBlockingQueue<ImageClip>()
        /** Cloud configs received; a clear is recorded as an empty URL. */
        val clouds = LinkedBlockingQueue<CloudConfig>()
        val connected = CountDownLatch(1)
        override fun onState(state: LinkState) {
            states.add(state)
            if (state.phase == LinkPhase.CONNECTED) connected.countDown()
        }
        override fun onClip(id: String, text: String) { clips.add(text) }
        override fun onTalkState(state: TalkState) { talk.add(state) }
        override fun onImageClip(clip: ImageClip) { images.add(clip) }
        override fun onCloud(config: CloudConfig?) { clouds.add(config ?: CloudConfig("", "")) }
        /** Speech settings received; a clear is recorded as an empty provider. */
        val speech = LinkedBlockingQueue<SpeechConfig>()
        override fun onSpeech(config: SpeechConfig?) { speech.add(config ?: SpeechConfig("", "", "", "", null, emptyList())) }
    }

    private fun startClient(listener: LinkListener, pingMs: Long = 15_000) = LinkClient(
        pairing, "Test phone", "0.1.0", PairingHostsResolver(), listener, pingIntervalMs = pingMs,
    ).also { client = it; it.start() }

    @Test fun handshakeClipboardAndTalk() {
        val recorder = Recorder()
        val c = startClient(recorder)
        server.soTimeout = 5_000
        val mac = FakeMac(TcpFrameTransport(server.accept()), secret, "MAC-1")
        assertEquals("hello", mac.hello.getString("t"))
        assertEquals(1, mac.hello.getInt("v"))
        assertEquals("DEV-1", mac.hello.getString("device"))
        assertEquals(16, Base64Url.decode(mac.hello.getString("nonce"))!!.size)
        assertEquals("auth", mac.auth.getString("t"))
        assertEquals("Test phone", mac.auth.getString("name"))
        assertEquals("0.1.0", mac.auth.getString("app"))
        assertTrue(recorder.connected.await(5, TimeUnit.SECONDS))
        assertEquals("Fake Mac Pro", c.macName)

        // Mac -> phone clip is delivered and acked.
        mac.sendMessage(LinkMessages.clip("c1", "from mac"))
        assertEquals("from mac", recorder.clips.poll(5, TimeUnit.SECONDS))
        val ack = mac.receive()!!
        assertEquals("clip_ack", ack.getString("t"))
        assertEquals("c1", ack.getString("id"))

        // Phone -> Mac clip.
        assertEquals(LinkClient.ClipResult.SENT, c.sendClip("from phone"))
        val clip = mac.receive()!!
        assertEquals("clip", clip.getString("t"))
        assertEquals("from phone", clip.getString("text"))

        // Talk: start, 3 audio frames, end; then the Mac reports a result.
        val id = c.talkStart()!!
        repeat(3) { c.sendAudio(ByteArray(LinkProtocol.AUDIO_FRAME_BYTES)) }
        c.talkEnd(id)
        val start = mac.receive()!!
        assertEquals("talk_start", start.getString("t"))
        assertEquals(id, start.getString("id"))
        val end = mac.receive()!!
        assertEquals("talk_end", end.getString("t"))
        assertEquals(3 * LinkProtocol.AUDIO_FRAME_BYTES, mac.audioBytes)
        mac.sendMessage(JSONObject().put("t", "talk_state").put("id", id).put("state", "done").put("text", "hello world"))
        val state = recorder.talk.poll(5, TimeUnit.SECONDS)!!
        assertEquals("done", state.state)
        assertEquals("hello world", state.text)
    }

    @Test fun speechSettingsAndTextTalks() {
        val recorder = Recorder()
        val c = startClient(recorder)
        server.soTimeout = 5_000
        val mac = FakeMac(TcpFrameTransport(server.accept()), secret, "MAC-1")
        assertTrue(recorder.connected.await(5, TimeUnit.SECONDS))

        mac.sendMessage(JSONObject("""{"t":"speech","provider":"openAI","url":"https://api.openai.com/v1","model":"gpt-4o-mini-transcribe",
            "key":"sk-1","streaming":"openAI","terms":["OpenScribe"]}"""))
        val config = recorder.speech.poll(5, TimeUnit.SECONDS)!!
        assertEquals("openAI", config.provider)
        assertEquals("sk-1", config.key)
        mac.sendMessage(JSONObject().put("t", "speech"))
        assertEquals("", recorder.speech.poll(5, TimeUnit.SECONDS)!!.provider)

        val id = c.talkStart(textMode = true)!!
        c.talkPartial(id, "hello")
        c.talkText(id, "hello world")
        val start = mac.receive()!!
        assertEquals("talk_start", start.getString("t"))
        assertEquals("text", start.getString("mode"))
        assertFalse(start.has("rate"))
        assertEquals("hello", mac.receive()!!.getString("text"))
        val text = mac.receive()!!
        assertEquals("talk_text", text.getString("t"))
        assertEquals(id, text.getString("id"))
        assertEquals("hello world", text.getString("text"))
        assertEquals(null, c.currentTalkId)
    }

    @Test fun sendsPingsAndReconnectsAfterDrop() {
        val recorder = Recorder()
        startClient(recorder, pingMs = 200)
        server.soTimeout = 5_000
        val mac = FakeMac(TcpFrameTransport(server.accept()), secret, "MAC-1")
        assertEquals("ping", mac.receive()!!.getString("t"))
        mac.transport.close()
        // The client comes back on its own.
        val again = FakeMac(TcpFrameTransport(server.accept()), secret, "MAC-1")
        assertEquals("auth", again.auth.getString("t"))
    }

    @Test fun reportsUnpaired() {
        val recorder = Recorder()
        startClient(recorder)
        server.soTimeout = 5_000
        FakeMac(TcpFrameTransport(server.accept()), secret, "MAC-1", refuse = "unpaired")
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            val s = recorder.states.poll(1, TimeUnit.SECONDS) ?: continue
            if (s.phase == LinkPhase.UNPAIRED) return
        }
        throw AssertionError("never reported unpaired")
    }

    @Test fun resolverEndpointsAreTriedInOrder() {
        // A dead endpoint first, then the real one.
        val dead = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).let { val p = it.localPort; it.close(); p }
        val resolver = object : EndpointResolver {
            override fun resolve(pairing: PairingLink) = listOf(
                InetSocketAddress("127.0.0.1", dead), InetSocketAddress("127.0.0.1", server.localPort),
            )
        }
        val recorder = Recorder()
        client = LinkClient(pairing, "Test phone", "0.1.0", resolver, recorder).also { it.start() }
        server.soTimeout = 5_000
        FakeMac(TcpFrameTransport(server.accept()), secret, "MAC-1")
        assertTrue(recorder.connected.await(5, TimeUnit.SECONDS))
    }

    /** A relay that hands the client one end of an in-memory pipe and the test the other. */
    private class MemoryRelay(private val available: Boolean = true) : RelayDialer {
        val macEnds = LinkedBlockingQueue<MemoryTransport>()
        val dials = AtomicInteger()
        override fun label() = if (available) "OpenScribe Cloud (test)" else null
        override fun dial(): FrameTransport {
            dials.incrementAndGet()
            val (phone, mac) = MemoryTransport.pair()
            macEnds.add(mac)
            return phone
        }
    }

    private val noLan = object : EndpointResolver {
        override fun resolve(pairing: PairingLink) = emptyList<InetSocketAddress>()
    }

    @Test fun sessionRunsOverInMemoryTransport() {
        val recorder = Recorder()
        val relay = MemoryRelay()
        val c = LinkClient(pairing, "Test phone", "0.1.0", noLan, recorder, relay = relay).also { client = it; it.start() }
        val mac = FakeMac(relay.macEnds.poll(5, TimeUnit.SECONDS)!!, secret, "MAC-1")
        assertEquals("DEV-1", mac.hello.getString("device"))
        assertEquals("auth", mac.auth.getString("t"))
        assertTrue(recorder.connected.await(5, TimeUnit.SECONDS))
        assertEquals(LinkVia.CLOUD, c.state.via)
        assertEquals("OpenScribe Cloud (test)", c.state.endpoint)

        // Text clips both ways, as on the LAN.
        mac.sendMessage(LinkMessages.clip("t1", "over the relay"))
        assertEquals("over the relay", recorder.clips.poll(5, TimeUnit.SECONDS))
        assertEquals("t1", mac.receive()!!.getString("id"))
        assertEquals(LinkClient.ClipResult.SENT, c.sendClip("from phone"))
        assertEquals("from phone", mac.receive()!!.getString("text"))

        // Cloud access arrives and is withdrawn.
        mac.sendMessage(JSONObject().put("t", "cloud").put("url", "https://cloud.example").put("token", "oslp_abc"))
        assertEquals(CloudConfig("https://cloud.example", "oslp_abc"), recorder.clouds.poll(5, TimeUnit.SECONDS))
        mac.sendMessage(JSONObject().put("t", "cloud"))
        assertEquals("", recorder.clouds.poll(5, TimeUnit.SECONDS)!!.url)

        // An image from the Mac is handed over, and acked only when the app says so.
        val key = BlobCipher.newKey()
        mac.sendMessage(LinkMessages.imageClip("i1", "image/png", "blob-1", key, 1234))
        val image = recorder.images.poll(5, TimeUnit.SECONDS)!!
        assertEquals(ImageClip("i1", "image/png", "blob-1", key, 1234), image)
        c.ackClip("i1")
        val ack = mac.receive()!!
        assertEquals("clip_ack", ack.getString("t"))
        assertEquals("i1", ack.getString("id"))

        // An image to the Mac.
        assertEquals(LinkClient.ClipResult.SENT, c.sendImageClip("i2", "image/jpeg", "blob-2", key, 99))
        val sent = mac.receive()!!
        assertEquals("image", sent.getString("kind"))
        assertEquals("blob-2", sent.getString("blob"))
        assertEquals(Base64Url.encode(key), sent.getString("key"))

        // The relay dropping (the Mac left) ends the session, and the client dials again.
        mac.transport.close()
        val again = FakeMac(relay.macEnds.poll(5, TimeUnit.SECONDS)!!, secret, "MAC-1")
        assertEquals("auth", again.auth.getString("t"))
    }

    @Test fun localNetworkIsTriedBeforeTheRelay() {
        val recorder = Recorder()
        val relay = MemoryRelay()
        client = LinkClient(pairing, "Test phone", "0.1.0", PairingHostsResolver(), recorder, relay = relay).also { it.start() }
        server.soTimeout = 5_000
        FakeMac(TcpFrameTransport(server.accept()), secret, "MAC-1")
        assertTrue(recorder.connected.await(5, TimeUnit.SECONDS))
        assertEquals(LinkVia.LAN, client!!.state.via)
        assertEquals(0, relay.dials.get())
    }

    @Test fun relayIsUsedWhenTheLocalNetworkFails() {
        val dead = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).let { val p = it.localPort; it.close(); p }
        val resolver = object : EndpointResolver {
            override fun resolve(pairing: PairingLink) = listOf(InetSocketAddress("127.0.0.1", dead))
        }
        val recorder = Recorder()
        val relay = MemoryRelay()
        client = LinkClient(pairing, "Test phone", "0.1.0", resolver, recorder, relay = relay).also { it.start() }
        FakeMac(relay.macEnds.poll(5, TimeUnit.SECONDS)!!, secret, "MAC-1")
        assertTrue(recorder.connected.await(5, TimeUnit.SECONDS))
        assertEquals(LinkVia.CLOUD, client!!.state.via)
    }

    @Test fun noRelayWithoutCloudAccess() {
        val recorder = Recorder()
        val relay = MemoryRelay(available = false)
        client = LinkClient(pairing, "Test phone", "0.1.0", noLan, recorder, relay = relay).also { it.start() }
        val deadline = System.currentTimeMillis() + 3_000
        while (System.currentTimeMillis() < deadline) {
            val s = recorder.states.poll(500, TimeUnit.MILLISECONDS) ?: continue
            if (s.lastError == "Mac not found on this network") break
        }
        assertEquals(0, relay.dials.get())
    }
}
