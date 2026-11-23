package org.opensource.openscribe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.opensource.openscribe.link.Base64Url
import org.opensource.openscribe.link.BlobCipher
import org.opensource.openscribe.link.CloudConfig
import org.opensource.openscribe.speech.SpeechConfig
import org.opensource.openscribe.speech.StreamingTransport

class MacSecretsTest {
    private class MemoryStore : StringStore {
        val values = HashMap<String, String>()
        override fun get(key: String) = values[key]
        override fun set(key: String, value: String?) { if (value == null) values.remove(key) else values[key] = value }
    }

    /** AES-GCM with a fixed key, standing in for the Keystore. */
    private object TestBox : SecretBox {
        private val key = ByteArray(32) { 7 }
        override fun seal(plain: String) = Base64Url.encode(BlobCipher.seal(key, plain.toByteArray()))
        override fun open(sealed: String) = String(BlobCipher.open(key, Base64Url.decode(sealed)!!))
    }

    private val speechA = SpeechConfig("openRouter", "https://openrouter.ai/api/v1", "mistralai/voxtral-mini-transcribe", "sk-or-AAA", null, listOf("OpenScribe"))
    private val speechB = SpeechConfig("deepgram", "https://api.deepgram.com/v1", "nova-3", "dg-BBB", StreamingTransport.DEEPGRAM, emptyList())

    @Test fun eachMacKeepsItsOwnSettingsAndForgetWipesOnlyOne() {
        val store = MemoryStore()
        val secrets = MacSecrets(store, TestBox)
        secrets.saveSpeech(mapOf("MAC-A" to speechA))
        secrets.saveSpeech(secrets.speech() + ("MAC-B" to speechB))
        secrets.saveCloud(mapOf("MAC-A" to CloudConfig("https://cloud.example", "oslp_a"), "MAC-B" to CloudConfig("https://cloud.example", "oslp_b")))

        // A fresh reader (as after a restart) sees each Mac's own settings.
        val reread = MacSecrets(store, TestBox)
        assertEquals(speechA, reread.speech()["MAC-A"])
        assertEquals(speechB, reread.speech()["MAC-B"])
        assertEquals("oslp_a", reread.cloud()["MAC-A"]!!.token)

        // Keys are encrypted at rest.
        store.values.values.forEach { stored ->
            assertFalse(stored.contains("sk-or-AAA"))
            assertFalse(stored.contains("dg-BBB"))
            assertFalse(stored.contains("oslp_"))
        }

        reread.forget("MAC-A")
        assertEquals(mapOf("MAC-B" to speechB), reread.speech())
        assertEquals(setOf("MAC-B"), reread.cloud().keys)

        reread.forget("MAC-B")
        assertTrue(reread.speech().isEmpty())
        assertTrue("nothing left behind", store.values.isEmpty())
    }

    @Test fun clipFoldersAndNamesAreStrict() {
        val a = ClipNames.macFolder("MAC-A")
        assertEquals(16, a.length)
        assertFalse(a == ClipNames.macFolder("MAC-B"))
        assertEquals(a, ClipNames.macFolder("MAC-A"))
        val name = ClipNames.fileName("../../etc/passwd", "png")
        assertEquals("etcpasswd.png.enc", name)
        assertTrue(ClipNames.isValid(a, name))
        assertFalse(ClipNames.isValid("..", name))
        assertFalse(ClipNames.isValid(a, "x.png"))
        assertFalse(ClipNames.isValid(a, "../x.png.enc"))
        assertEquals("image/png", ClipNames.mime(name))
        assertEquals("etcpasswd.png", ClipNames.displayName(name))
    }
}
