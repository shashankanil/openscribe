package org.opensource.openscribe.speech

import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** The realtime builders and reducers against the Mac's StreamingCapability / RealtimeTranscription. */
class RealtimeTest {
    private val terms = listOf("OpenScribe", "Kenpath")

    @Test fun urlsAndAuth() {
        val openAI = RealtimeProtocol.url(StreamingTransport.OPENAI, "gpt-4o-transcribe", terms)
        assertEquals("https://api.openai.com/v1/realtime?intent=transcription", openAI.toString())
        assertEquals("Bearer sk-1", RealtimeProtocol.authorization(StreamingTransport.OPENAI, " sk-1 "))
        assertEquals(24_000, RealtimeProtocol.sampleRate(StreamingTransport.OPENAI))

        val mistral = RealtimeProtocol.url(StreamingTransport.MISTRAL, "voxtral-mini-transcribe-realtime-2602", terms)
        assertEquals("api.mistral.ai", mistral.host)
        assertEquals("/v1/audio/transcriptions/realtime", mistral.encodedPath)
        assertEquals("voxtral-mini-transcribe-realtime-2602", mistral.queryParameter("model"))
        assertEquals("Bearer k", RealtimeProtocol.authorization(StreamingTransport.MISTRAL, "k"))
        assertEquals(16_000, RealtimeProtocol.sampleRate(StreamingTransport.MISTRAL))

        val deepgram = RealtimeProtocol.url(StreamingTransport.DEEPGRAM, "nova-3", terms)
        assertEquals("/v1/listen", deepgram.encodedPath)
        mapOf("model" to "nova-3", "encoding" to "linear16", "sample_rate" to "16000", "channels" to "1",
            "interim_results" to "true", "smart_format" to "true").forEach { (k, v) -> assertEquals(k, v, deepgram.queryParameter(k)) }
        assertEquals(terms, deepgram.queryParameterValues("keyterm"))
        assertEquals(terms, RealtimeProtocol.url(StreamingTransport.DEEPGRAM, "nova-2", terms).queryParameterValues("keywords"))
        assertEquals("Token k", RealtimeProtocol.authorization(StreamingTransport.DEEPGRAM, "k"))
        assertEquals("Token k", RealtimeProtocol.authorization(StreamingTransport.DEEPGRAM, "Token k"))

        val assembly = RealtimeProtocol.url(StreamingTransport.ASSEMBLYAI, "universal-streaming-english", terms)
        assertEquals("streaming.assemblyai.com", assembly.host)
        assertEquals("/v3/ws", assembly.encodedPath)
        mapOf("speech_model" to "universal-streaming-english", "sample_rate" to "16000", "encoding" to "pcm_s16le",
            "format_turns" to "true").forEach { (k, v) -> assertEquals(k, v, assembly.queryParameter(k)) }
        assertEquals(terms, JSONArray(assembly.queryParameter("keyterms_prompt")).let { a -> (0 until a.length()).map(a::getString) })
        assertNull(RealtimeProtocol.url(StreamingTransport.ASSEMBLYAI, "u", emptyList()).queryParameter("keyterms_prompt"))
        assertEquals("k", RealtimeProtocol.authorization(StreamingTransport.ASSEMBLYAI, "k"))
    }

    @Test fun sessionSetupMessages() {
        assertEquals("session.created", RealtimeProtocol.greeting(StreamingTransport.OPENAI))
        assertEquals("session.created", RealtimeProtocol.greeting(StreamingTransport.MISTRAL))
        assertEquals("Begin", RealtimeProtocol.greeting(StreamingTransport.ASSEMBLYAI))
        assertNull(RealtimeProtocol.greeting(StreamingTransport.DEEPGRAM))

        val openAI = RealtimeProtocol.sessionUpdate(StreamingTransport.OPENAI, "gpt-4o-transcribe", terms)!!
        assertEquals("session.update", openAI.getString("type"))
        val session = openAI.getJSONObject("session")
        assertEquals("transcription", session.getString("type"))
        val input = session.getJSONObject("audio").getJSONObject("input")
        assertEquals("audio/pcm", input.getJSONObject("format").getString("type"))
        assertEquals(24000, input.getJSONObject("format").getInt("rate"))
        assertEquals("gpt-4o-transcribe", input.getJSONObject("transcription").getString("model"))
        assertEquals("Glossary: OpenScribe, Kenpath.", input.getJSONObject("transcription").getString("prompt"))
        assertTrue(input.has("turn_detection") && input.isNull("turn_detection"))
        assertFalse(RealtimeProtocol.sessionUpdate(StreamingTransport.OPENAI, "m", emptyList())!!
            .getJSONObject("session").getJSONObject("audio").getJSONObject("input").getJSONObject("transcription").has("prompt"))

        val mistral = RealtimeProtocol.sessionUpdate(StreamingTransport.MISTRAL, "m", terms)!!
        assertEquals(
            normalized("""{"type":"session.update","session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"""),
            normalized(mistral.toString()),
        )
        assertNull(RealtimeProtocol.sessionUpdate(StreamingTransport.DEEPGRAM, "m", terms))
        assertNull(RealtimeProtocol.sessionUpdate(StreamingTransport.ASSEMBLYAI, "m", terms))
    }

    /** Key order in org.json output isn't fixed; compare structurally by re-serialising sorted. */
    private fun normalized(json: String): String {
        fun sort(value: Any?): Any? = when (value) {
            is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") { "\"$it\":" + sort(value.get(it)) }
            is String -> JSONObject.quote(value)
            else -> value.toString()
        }
        return sort(JSONObject(json)) as String
    }

    @Test fun audioFramingAndEnd() {
        val pcm = byteArrayOf(1, 2, 3, 4)
        val b64 = Base64.getEncoder().encodeToString(pcm)
        assertEquals("input_audio_buffer.append", RealtimeProtocol.audioMessage(StreamingTransport.OPENAI, pcm)!!.getString("type"))
        assertEquals(b64, RealtimeProtocol.audioMessage(StreamingTransport.OPENAI, pcm)!!.getString("audio"))
        assertEquals("input_audio.append", RealtimeProtocol.audioMessage(StreamingTransport.MISTRAL, pcm)!!.getString("type"))
        assertNull(RealtimeProtocol.audioMessage(StreamingTransport.DEEPGRAM, pcm))
        assertNull(RealtimeProtocol.audioMessage(StreamingTransport.ASSEMBLYAI, pcm))

        assertTrue(RealtimeProtocol.commitsPeriodically(StreamingTransport.OPENAI, "gpt-4o-mini-transcribe"))
        assertFalse(RealtimeProtocol.commitsPeriodically(StreamingTransport.OPENAI, "gpt-live-transcribe"))
        assertFalse(RealtimeProtocol.commitsPeriodically(StreamingTransport.OPENAI, "gpt-realtime-whisper"))
        assertFalse(RealtimeProtocol.commitsPeriodically(StreamingTransport.MISTRAL, "gpt-4o-mini-transcribe"))

        // A short OpenAI tail is padded to 100 ms before the commit.
        val shortEnd = RealtimeProtocol.end(StreamingTransport.OPENAI, 800)
        assertEquals(2, shortEnd.size)
        assertArrayEquals(ByteArray(4_000), Base64.getDecoder().decode(shortEnd[0].getString("audio")))
        assertEquals("input_audio_buffer.commit", shortEnd[1].getString("type"))
        assertEquals(listOf("input_audio_buffer.commit"), RealtimeProtocol.end(StreamingTransport.OPENAI, 9_600).map { it.getString("type") })
        assertEquals(listOf("input_audio.end"), RealtimeProtocol.end(StreamingTransport.MISTRAL, 0).map { it.getString("type") })
        assertEquals(listOf("CloseStream"), RealtimeProtocol.end(StreamingTransport.DEEPGRAM, 0).map { it.getString("type") })
        assertEquals(listOf("Terminate"), RealtimeProtocol.end(StreamingTransport.ASSEMBLYAI, 0).map { it.getString("type") })
    }

    private fun RealtimeTranscript.feed(vararg events: String) = events.forEach { consume(JSONObject(it)) }

    @Test fun mistralEvents() {
        val t = RealtimeTranscript(StreamingTransport.MISTRAL)
        t.feed("""{"type":"transcription.text.delta","text":"Hello"}""", """{"type":"transcription.text.delta","text":" world"}""")
        assertEquals("Hello world", t.text)
        assertFalse(t.terminal)
        t.feed("""{"type":"transcription.done","text":"Hello, world."}""")
        assertEquals("Hello, world.", t.text)
        assertTrue(t.terminal)
    }

    @Test fun deepgramEvents() {
        val t = RealtimeTranscript(StreamingTransport.DEEPGRAM)
        fun results(start: Double, text: String, final: Boolean) =
            """{"type":"Results","start":$start,"is_final":$final,"channel":{"alternatives":[{"transcript":"$text"}]}}"""
        t.feed(results(0.0, "hel", false))
        assertEquals("hel", t.text)
        t.feed(results(0.0, "hello", true), results(1.5, "wor", false))
        assertEquals("hello wor", t.text)
        t.feed(results(1.5, "world", true), results(0.0, "hello there", true))
        assertEquals("hello there world", t.text)
        t.feed("""{"type":"Metadata"}""")
        assertTrue(t.terminal)
        assertEquals("hello there world", t.text)
    }

    @Test fun assemblyAIEvents() {
        val t = RealtimeTranscript(StreamingTransport.ASSEMBLYAI)
        t.feed("""{"type":"Begin","id":"x"}""")
        t.feed("""{"type":"Turn","turn_order":1,"transcript":"second"}""", """{"type":"Turn","turn_order":0,"transcript":"first"}""")
        assertEquals("first second", t.text)
        t.feed("""{"type":"Turn","turn_order":1,"transcript":"Second."}""")
        assertEquals("first Second.", t.text)
        t.feed("""{"type":"Termination"}""")
        assertTrue(t.terminal)
    }

    @Test fun openAIEvents() {
        val t = RealtimeTranscript(StreamingTransport.OPENAI)
        t.feed(
            """{"type":"input_audio_buffer.committed","item_id":"a"}""",
            """{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"Hel"}""",
            """{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"lo"}""",
            """{"type":"input_audio_buffer.committed","item_id":"b"}""",
            """{"type":"conversation.item.input_audio_transcription.delta","item_id":"b","delta":"wor"}""",
        )
        assertEquals("Hello wor", t.text)
        t.feed("""{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Hello,"}""")
        assertEquals("Hello, wor", t.text)
        assertEquals(setOf("a"), t.completed)
        // Late deltas for a completed item are ignored.
        t.feed("""{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"zzz"}""")
        assertEquals("Hello, wor", t.text)
    }

    @Test fun errorsAreRejections() {
        for ((transport, type) in listOf(
            StreamingTransport.OPENAI to "error", StreamingTransport.DEEPGRAM to "Error",
            StreamingTransport.MISTRAL to "session.failed", StreamingTransport.ASSEMBLYAI to "error",
        )) {
            assertThrows(SpeechException::class.java) { RealtimeTranscript(transport).consume(JSONObject().put("type", type)) }
        }
    }

    /** A fake OpenAI realtime server: setup, appends, commits answered with transcripts. */
    private class FakeOpenAI : WebSocketListener() {
        val received = LinkedBlockingQueue<JSONObject>()
        val headers = LinkedBlockingQueue<String>()
        var audioBytes = 0
        private var item = 0

        override fun onOpen(webSocket: WebSocket, response: Response) {
            webSocket.send("""{"type":"session.created"}""")
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val event = JSONObject(text)
            received.add(event)
            when (event.getString("type")) {
                "session.update" -> webSocket.send("""{"type":"session.updated"}""")
                "input_audio_buffer.append" -> audioBytes += Base64.getDecoder().decode(event.getString("audio")).size
                "input_audio_buffer.commit" -> {
                    val id = "item${item++}"
                    webSocket.send("""{"type":"input_audio_buffer.committed","item_id":"$id"}""")
                    webSocket.send("""{"type":"conversation.item.input_audio_transcription.delta","item_id":"$id","delta":"part"}""")
                    webSocket.send("""{"type":"conversation.item.input_audio_transcription.completed","item_id":"$id","transcript":"Part $item."}""")
                }
            }
        }
    }

    @Test fun streamsToAnOpenAIRealtimeSocket() {
        val server = MockWebServer()
        val fake = FakeOpenAI()
        server.enqueue(MockResponse.Builder().webSocketUpgrade(fake).build())
        server.start()
        try {
            val config = SpeechConfig("openAI", "https://api.openai.com/v1", "gpt-4o-mini-transcribe", "sk-live", StreamingTransport.OPENAI, listOf("OpenScribe"))
            val collector = Collector()
            val streaming = StreamingTranscriber(OkHttpClient(), config, collector, endpoint = server.url("/v1/realtime").toString())
            streaming.start()
            // 2.5 s of 16 kHz audio in 40 ms frames, fed before the socket is even ready.
            val audio = TestAudio.bytes(TestAudio.tone(2_500))
            for (offset in audio.indices step 1_280) streaming.feed(audio, offset, minOf(1_280, audio.size - offset))
            streaming.finish()
            assertEquals("Part 1. Part 2.", collector.await().getOrThrow())
            assertTrue(collector.partials.isNotEmpty())

            val request = server.takeRequest()
            assertEquals("transcription", request.url.queryParameter("intent"))
            assertEquals("Bearer sk-live", request.headers["Authorization"])
            val update = fake.received.poll(1, TimeUnit.SECONDS)!!
            assertEquals("session.update", update.getString("type"))
            assertEquals("Glossary: OpenScribe.", update.getJSONObject("session").getJSONObject("audio").getJSONObject("input")
                .getJSONObject("transcription").getString("prompt"))
            // Resampled to 24 kHz: 2.5 s is 120 000 bytes; one commit after 2 s, one at the end.
            assertTrue("sent ${fake.audioBytes} bytes", fake.audioBytes in 119_000..120_000)
            val types = generateSequence { fake.received.poll() }.map { it.getString("type") }.toList()
            assertEquals(2, types.count { it == "input_audio_buffer.commit" })
        } finally {
            server.close()
        }
    }

    @Test fun aRejectedSocketReportsAnError() {
        val server = MockWebServer()
        server.enqueue(MockResponse.Builder().code(401).build())
        server.start()
        try {
            val config = SpeechConfig("deepgram", "https://api.deepgram.com/v1", "nova-3", "bad", StreamingTransport.DEEPGRAM, emptyList())
            val collector = Collector()
            StreamingTranscriber(OkHttpClient(), config, collector, endpoint = server.url("/v1/listen").toString()).start()
            assertEquals(401, (collector.await().exceptionOrNull() as SpeechException).status)
        } finally {
            server.close()
        }
    }
}
