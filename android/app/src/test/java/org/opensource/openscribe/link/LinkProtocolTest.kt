package org.opensource.openscribe.link

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException

/** Every test vector in docs/PHONE-LINK.md, shared with Tests/OpenScribeTests/PhoneLinkProtocolTests.swift. */
class LinkProtocolTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private val secret = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    private val clientNonce = hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
    private val serverNonce = hex("b0b1b2b3b4b5b6b7b8b9babbbcbdbebf")
    private val keys = LinkProtocol.sessionKeys(secret, clientNonce, serverNonce)

    private val c2sPlain0 = hex("017b226e616d65223a22546573742070686f6e65222c2274223a2261757468227d")
    private val c2sSealed0 = hex("130a6599aacb5a2112c773c03028fb014c39d3289266edd3165c912a0c1a3a8c37a7ffc05cac9e93d4ff4dbdf5626fb830")
    private val c2sPlain1 = hex("020100ff7f")
    private val c2sSealed1 = hex("9b06155de0a93a3f92c811102f32a12e76c964c754")
    private val s2cPlain0 = hex("017b226e616d65223a2254657374204d6163222c2274223a227265616479227d")
    private val s2cSealed0 = hex("ae4f24953ac956e25b733ca49a608eb9ac704713e8495e604f14afd8146d7142901306fecae8f98b42b4d5d2f7bc6f94")

    private val link = "openscribe://link?v=1&mac=M1&name=Test%20Mac&device=D1&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&h=192.168.1.5,10.0.0.2&p=47689"

    @Test fun clientToServerKey() =
        assertEquals("03348d6f70f8ac9aa1cabad86367f4513517ea375d87f445506a9f72adcf897a", keys.clientToServer.hex())

    @Test fun serverToClientKey() =
        assertEquals("c26ac681a4d44217865e142797c7bec66db24e28eb283edb1734c3ae494e044a", keys.serverToClient.hex())

    @Test fun hkdfRfc5869Case1() {
        // RFC 5869 appendix A.1, to pin the HKDF itself independently of the spec vectors.
        val okm = LinkProtocol.hkdfSha256(
            hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), hex("000102030405060708090a0b0c"),
            hex("f0f1f2f3f4f5f6f7f8f9"), 42,
        )
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", okm.hex())
    }

    @Test fun sealsClientFrames() {
        val cipher = LinkCipher(keys.clientToServer)
        assertEquals(c2sSealed0.hex(), cipher.seal(c2sPlain0).hex())
        assertEquals(c2sSealed1.hex(), cipher.seal(c2sPlain1).hex())
        assertEquals(2L, cipher.counter)
    }

    @Test fun sealsServerFrame() =
        assertEquals(s2cSealed0.hex(), LinkCipher(keys.serverToClient).seal(s2cPlain0).hex())

    @Test fun opensVectorFrames() {
        val c2s = LinkCipher(keys.clientToServer)
        assertArrayEquals(c2sPlain0, c2s.open(c2sSealed0))
        assertArrayEquals(c2sPlain1, c2s.open(c2sSealed1))
        assertArrayEquals(s2cPlain0, LinkCipher(keys.serverToClient).open(s2cSealed0))
    }

    @Test fun authPlaintextMatchesVectorMessage() {
        val message = LinkMessages.parse(c2sPlain0, 1)!!
        assertEquals("auth", message.getString("t"))
        assertEquals("Test phone", message.getString("name"))
        assertEquals("ready", LinkMessages.parse(s2cPlain0, 1)!!.getString("t"))
    }

    @Test fun tamperedFrameFailsToOpen() {
        val tampered = c2sSealed0.copyOf().also { it[3] = (it[3].toInt() xor 1).toByte() }
        val cipher = LinkCipher(keys.clientToServer)
        assertThrows(LinkProtocolException::class.java) { cipher.open(tampered) }
        assertEquals(0L, cipher.counter)
        val tamperedTag = c2sSealed0.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 0x80).toByte() }
        assertThrows(LinkProtocolException::class.java) { cipher.open(tamperedTag) }
        assertThrows(LinkProtocolException::class.java) { cipher.open(ByteArray(8)) }
    }

    @Test fun outOfOrderFrameFailsToOpen() {
        assertThrows(LinkProtocolException::class.java) { LinkCipher(keys.clientToServer).open(c2sSealed1) }
        // A replayed frame fails too.
        val cipher = LinkCipher(keys.clientToServer)
        cipher.open(c2sSealed0)
        assertThrows(LinkProtocolException::class.java) { cipher.open(c2sSealed0) }
        // And a frame for the other direction.
        assertThrows(LinkProtocolException::class.java) { LinkCipher(keys.clientToServer).open(s2cSealed0) }
    }

    @Test fun base64Url() {
        assertEquals("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", Base64Url.encode(secret))
        assertArrayEquals(secret, Base64Url.decode("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        assertEquals("-_8", Base64Url.encode(byteArrayOf(0xfb.toByte(), 0xff.toByte())))
        assertArrayEquals(byteArrayOf(0xfb.toByte(), 0xff.toByte()), Base64Url.decode("-_8="))
        assertNull(Base64Url.decode("not base64!"))
    }

    @Test fun parsesPairingLink() {
        val pairing = PairingLink.parse(link)!!
        assertEquals("M1", pairing.macId)
        assertEquals("Test Mac", pairing.macName)
        assertEquals("D1", pairing.deviceId)
        assertArrayEquals(secret, pairing.secret)
        assertEquals(listOf("192.168.1.5", "10.0.0.2"), pairing.hosts)
        assertEquals(47689, pairing.port)
    }

    @Test fun pairingLinkRoundTrip() {
        val pairing = PairingLink.parse(link)!!
        assertEquals(link, pairing.toUri())
        assertEquals(pairing, PairingLink.parse(pairing.toUri()))
        val odd = pairing.copy(macName = "Ana's MacBook+Pro & co = 1 ☕", hosts = emptyList())
        assertEquals(odd, PairingLink.parse(odd.toUri()))
    }

    @Test fun rejectsBadPairingLinks() {
        assertNull(PairingLink.parse("https://example.com"))
        assertNull(PairingLink.parse(link.replace("v=1", "v=2")))
        assertNull(PairingLink.parse(link.replace("&p=47689", "")))
        assertNull(PairingLink.parse(link.replace("Hh8", "")))
        assertNull(PairingLink.parse(link.replace("device=D1&", "")))
    }

    @Test fun framing() {
        val out = ByteArrayOutputStream()
        LinkProtocol.writeFrame(out, byteArrayOf(1, 2, 3))
        LinkProtocol.writeFrame(out, ByteArray(0))
        assertEquals("00000003010203" + "00000000", out.toByteArray().hex())
        val input = ByteArrayInputStream(out.toByteArray())
        assertArrayEquals(byteArrayOf(1, 2, 3), LinkProtocol.readFrame(input))
        assertArrayEquals(ByteArray(0), LinkProtocol.readFrame(input))
        assertThrows(EOFException::class.java) { LinkProtocol.readFrame(input) }
    }

    @Test fun rejectsOversizeFrames() {
        val header = hex("00100001") // 1 MiB + 1
        assertThrows(LinkProtocolException::class.java) { LinkProtocol.readFrame(ByteArrayInputStream(header)) }
        val exact = ByteArrayOutputStream().apply { write(hex("00100000")); write(ByteArray(1 shl 20)) }.toByteArray()
        assertEquals(1 shl 20, LinkProtocol.readFrame(ByteArrayInputStream(exact)).size)
    }

    @Test fun messagesIgnoreUnknownFields() {
        val msg = LinkMessages.parse("""{"t":"clip","id":"x","text":"hi","future":{"a":1}}""".toByteArray())!!
        assertEquals("hi", msg.getString("text"))
        assertNull(LinkMessages.parse("not json".toByteArray()))
        assertNull(LinkMessages.parse("""{"id":"x"}""".toByteArray()))
    }

    @Test fun talkStartFields() {
        val msg = LinkMessages.talkStart("abc")
        assertEquals("talk_start", msg.getString("t"))
        assertEquals(16000, msg.getInt("rate"))
        assertEquals(1, msg.getInt("channels"))
        assertEquals("pcm_s16le", msg.getString("format"))
    }

    // OpenScribe Cloud

    @Test fun relayRoomVector() = assertEquals("14da9ca9ec019835c941f773b307b562", LinkProtocol.relayRoom(secret))

    private val blobKey = hex("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f")
    private val blobNonce = hex("606162636465666768696a6b")
    private val blobPlain = "OpenScribe image".toByteArray(Charsets.UTF_8)
    private val blob = hex("606162636465666768696a6be3586c6b54f7e2cf6be4595f68e73b6e85f8f610058025c8643d673817bb9316")

    @Test fun sealsBlobVector() = assertEquals(blob.hex(), BlobCipher.seal(blobKey, blobPlain, blobNonce).hex())

    @Test fun opensBlobVector() = assertArrayEquals(blobPlain, BlobCipher.open(blobKey, blob))

    @Test fun blobRoundTripUsesFreshNonces() {
        val key = BlobCipher.newKey()
        val a = BlobCipher.seal(key, blobPlain)
        val b = BlobCipher.seal(key, blobPlain)
        assertEquals(blobPlain.size + BlobCipher.OVERHEAD, a.size)
        assertNotEquals(a.copyOf(12).hex(), b.copyOf(12).hex())
        assertArrayEquals(blobPlain, BlobCipher.open(key, a))
    }

    @Test fun tamperedBlobFailsToOpen() {
        val tampered = blob.copyOf().also { it[14] = (it[14].toInt() xor 1).toByte() }
        assertThrows(LinkProtocolException::class.java) { BlobCipher.open(blobKey, tampered) }
        val wrongNonce = blob.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertThrows(LinkProtocolException::class.java) { BlobCipher.open(blobKey, wrongNonce) }
        assertThrows(LinkProtocolException::class.java) { BlobCipher.open(BlobCipher.newKey(), blob) }
        assertThrows(LinkProtocolException::class.java) { BlobCipher.open(blobKey, ByteArray(20)) }
    }

    @Test fun imageClipMessageMatchesSpec() {
        val message = LinkMessages.imageClip("c1", "image/png", "b1", blobKey, 16)
        assertEquals("clip", message.getString("t"))
        assertEquals("image", message.getString("kind"))
        assertEquals("image/png", message.getString("mime"))
        assertEquals("b1", message.getString("blob"))
        assertEquals("QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8", message.getString("key"))
        assertEquals(16, message.getInt("size"))
    }

    @Test fun cloudConfigNeedsHttpsAndToken() {
        fun parse(json: String) = CloudConfig.fromJson(org.json.JSONObject(json))
        assertEquals(CloudConfig("https://cloud.example", "oslp_x"), parse("""{"t":"cloud","url":"https://cloud.example","token":"oslp_x"}"""))
        assertNull(parse("""{"t":"cloud","url":"http://cloud.example","token":"oslp_x"}"""))
        assertNull(parse("""{"t":"cloud","url":"https://cloud.example"}"""))
        assertNull(parse("""{"t":"cloud"}"""))
        assertEquals("https://cloud.example", CloudConfig("https://cloud.example/", "t").baseUrl)
        assertEquals(false, CloudConfig("https://cloud.example", "oslp_secret").toString().contains("oslp_secret"))
    }
}
