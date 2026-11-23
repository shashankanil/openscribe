package org.opensource.openscribe.link

import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** The relay transport and blob client against MockWebServer standing in for the OpenScribe Cloud Worker. */
class CloudTest {
    private val server = MockWebServer()
    private val http = CloudBlobs.httpClient()
    private lateinit var config: CloudConfig
    private val secret = ByteArray(32) { it.toByte() }
    private val room = LinkProtocol.relayRoom(secret)

    @Before fun setUp() {
        server.start()
        // The app only accepts https from the Mac; the fake Worker is plain http.
        config = CloudConfig(server.url("/").toString(), "oslp_test")
    }

    @After fun tearDown() {
        server.close()
    }

    /** The Mac's end of the relay, as the Worker would forward it. */
    private class FakeWorker(private val onOpen: (WebSocket) -> Unit) : WebSocketListener() {
        val binary = LinkedBlockingQueue<ByteArray>()
        val text = LinkedBlockingQueue<String>()
        val open = LinkedBlockingQueue<WebSocket>()
        override fun onOpen(webSocket: WebSocket, response: Response) {
            open.add(webSocket)
            onOpen(webSocket)
        }
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) { binary.add(bytes.toByteArray()) }
        override fun onMessage(webSocket: WebSocket, text: String) { this.text.add(text) }
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null) }
    }

    private fun present(value: Boolean) = """{"t":"peer","present":$value}"""

    @Test fun relayWaitsForTheMacThenCarriesFrames() {
        val worker = FakeWorker { ws ->
            ws.send(present(false))
            Thread { Thread.sleep(200); ws.send(present(true)) }.start()
        }
        server.enqueue(MockResponse.Builder().webSocketUpgrade(worker).build())

        val started = System.currentTimeMillis()
        val transport = RelayFrameTransport.connect(http, config, room, presenceTimeoutMs = 5_000)
        assertTrue("returned before the Mac was present", System.currentTimeMillis() - started >= 150)

        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("/api/v1/link/relay/$room", request.url.encodedPath)
        assertEquals("Bearer oslp_test", request.headers["Authorization"])
        assertEquals(32, room.length)

        // Each binary message is one frame payload, with no length prefix.
        val payload = byteArrayOf(1, 2, 3, 4, 5)
        transport.writeFrame(payload)
        assertArrayEquals(payload, worker.binary.poll(5, TimeUnit.SECONDS))
        val ws = worker.open.poll(5, TimeUnit.SECONDS)!!
        ws.send(byteArrayOf(9, 8, 7).toByteString())
        transport.readTimeoutMs = 5_000
        assertArrayEquals(byteArrayOf(9, 8, 7), transport.readFrame())

        // The Worker's pong is not a frame; the Mac leaving ends the transport.
        ws.send("pong")
        ws.send(present(false))
        assertThrows(ConnectionLostException::class.java) { transport.readFrame() }
        assertThrows(ConnectionLostException::class.java) { transport.readFrame() }
        transport.close()
    }

    @Test fun relayFailsWhenTheMacNeverArrives() {
        server.enqueue(MockResponse.Builder().webSocketUpgrade(FakeWorker { it.send(present(false)) }).build())
        val error = assertThrows(IOException::class.java) {
            RelayFrameTransport.connect(http, config, room, presenceTimeoutMs = 500)
        }
        assertEquals("The Mac isn't connected to OpenScribe Cloud", error.message)
    }

    @Test fun relayReportsARefusedToken() {
        server.enqueue(MockResponse.Builder().code(401).build())
        val error = assertThrows(IOException::class.java) {
            RelayFrameTransport.connect(http, config, room, presenceTimeoutMs = 5_000)
        }
        assertTrue(error.message!!, error.message!!.contains("401"))
    }

    @Test fun relaySendsTextPings() {
        val worker = FakeWorker { it.send(present(true)) }
        server.enqueue(MockResponse.Builder().webSocketUpgrade(worker).build())
        val transport = RelayFrameTransport.connect(http, config, room, presenceTimeoutMs = 5_000, pingIntervalMs = 100)
        assertEquals("ping", worker.text.poll(5, TimeUnit.SECONDS))
        transport.close()
    }

    @Test fun relaySilenceTimesOut() {
        server.enqueue(MockResponse.Builder().webSocketUpgrade(FakeWorker { it.send(present(true)) }).build())
        val transport = RelayFrameTransport.connect(http, config, room, presenceTimeoutMs = 5_000)
        transport.readTimeoutMs = 200
        assertThrows(java.net.SocketTimeoutException::class.java) { transport.readFrame() }
        transport.close()
    }

    @Test fun uploadsAndDownloadsSealedBlobs() {
        val blobs = CloudBlobs(http)
        val key = BlobCipher.newKey()
        val image = ByteArray(200_000) { (it * 31).toByte() }
        val sealed = BlobCipher.seal(key, image)

        server.enqueue(MockResponse.Builder().body("""{"id":"3f1c-blob","expiresAt":1700000000000}""").build())
        assertEquals("3f1c-blob", blobs.upload(config, sealed))
        val put = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("PUT", put.method)
        assertEquals("/api/v1/link/blobs", put.url.encodedPath)
        assertEquals("Bearer oslp_test", put.headers["Authorization"])
        assertEquals("application/octet-stream", put.headers["Content-Type"])
        assertArrayEquals(sealed, put.body!!.toByteArray())

        server.enqueue(MockResponse.Builder().body(Buffer().write(sealed)).build())
        val downloaded = blobs.download(config, "3f1c-blob")
        val get = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("GET", get.method)
        assertEquals("/api/v1/link/blobs/3f1c-blob", get.url.encodedPath)
        assertEquals("Bearer oslp_test", get.headers["Authorization"])
        assertArrayEquals(image, BlobCipher.open(key, downloaded))
    }

    @Test fun blobErrorsAreReadable() {
        val blobs = CloudBlobs(http)
        server.enqueue(MockResponse.Builder().code(404).build())
        val expired = assertThrows(CloudException::class.java) { blobs.download(config, "gone") }
        assertEquals(404, expired.status)
        server.enqueue(MockResponse.Builder().code(401).build())
        assertEquals(401, assertThrows(CloudException::class.java) { blobs.upload(config, ByteArray(40)) }.status)
        // A malformed id never reaches the network.
        assertThrows(CloudException::class.java) { blobs.download(config, "../secrets") }
        assertEquals(2, server.requestCount)
        // Neither does a blob over the limit.
        assertThrows(CloudException::class.java) { blobs.upload(config, ByteArray(CloudBlobs.MAX_BLOB + 1)) }
    }

    @Test fun relayUrlJoinsTheBaseUrl() = assertEquals(
        "https://cloud.example/api/v1/link/relay/abc",
        RelayFrameTransport.relayUrl(CloudConfig("https://cloud.example/", "t"), "abc"),
    )
}
