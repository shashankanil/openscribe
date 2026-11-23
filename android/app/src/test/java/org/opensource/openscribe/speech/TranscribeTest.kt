package org.opensource.openscribe.speech

import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okio.Buffer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Collects a transcriber's callbacks. */
class Collector : TranscriberListener {
    val partials = LinkedBlockingQueue<String>()
    val result = LinkedBlockingQueue<Result<String>>()
    override fun onPartial(text: String) { partials.add(text) }
    override fun onFinal(text: String) { result.add(Result.success(text)) }
    override fun onError(error: Exception) { result.add(Result.failure(error)) }
    fun await(): Result<String> = result.poll(10, TimeUnit.SECONDS) ?: throw AssertionError("no result")
}

class TranscribeTest {
    private val server = MockWebServer()
    private val http = Transcribers.httpClient(OkHttpClient())

    @Before fun setUp() = server.start()
    @After fun tearDown() = server.close()

    private fun config(provider: String, terms: List<String> = emptyList(), model: String = "whisper-large-v3") =
        SpeechConfig(provider, server.url("/v1/").toString(), model, "sk-test", null, terms)

    // Speech config message

    @Test fun parsesAndClearsTheSpeechMessage() {
        val message = JSONObject("""{"t":"speech","provider":"openRouter","url":"https://openrouter.ai/api/v1",
            "model":"mistralai/voxtral-mini-transcribe","key":" sk-or-1 ","streaming":null,"terms":["OpenScribe"," ","Kenpath","OpenScribe"]}""")
        val config = SpeechConfig.fromJson(message)!!
        assertEquals("openRouter", config.provider)
        assertEquals("https://openrouter.ai/api/v1", config.baseUrl)
        assertEquals("mistralai/voxtral-mini-transcribe", config.model)
        assertEquals("sk-or-1", config.key)
        assertNull(config.streaming)
        assertEquals(listOf("OpenScribe", "Kenpath"), config.terms)
        assertFalse("the key must not be printed", config.toString().contains("sk-or-1"))
        assertEquals(config, SpeechConfig.fromJson(config.toJson()))

        val streaming = SpeechConfig.fromJson(JSONObject(message.toString()).put("provider", "deepgram").put("streaming", "deepgram"))!!
        assertEquals(StreamingTransport.DEEPGRAM, streaming.streaming)

        // {"t":"speech"} and settings the phone can't use all mean "transcription stays on the Mac".
        assertNull(SpeechConfig.fromJson(JSONObject("""{"t":"speech"}""")))
        assertNull(SpeechConfig.fromJson(JSONObject(message.toString()).put("url", "http://192.168.1.2:9000/v1")))
        assertNull(SpeechConfig.fromJson(JSONObject(message.toString()).put("provider", "whisperCpp")))
        assertNull(SpeechConfig.fromJson(JSONObject(message.toString()).put("key", "")))
        assertEquals(Transcribers.Mode.MAC, Transcribers.mode(null))
        assertEquals(Transcribers.Mode.CHUNKED, Transcribers.mode(config))
        assertEquals(Transcribers.Mode.STREAMING, Transcribers.mode(streaming))
        assertEquals(Transcribers.Mode.MAC, Transcribers.mode(config.copy(provider = "assemblyAI")))
    }

    // File requests, as ProviderClient.swift builds them

    @Test fun openAICompatibleMultipartUpload() {
        server.enqueue(MockResponse.Builder().body("""{"text":" hello there "}""").build())
        val wav = Wav.encode(TestAudio.bytes(TestAudio.tone(100)))
        val text = FileTranscriber(http, config("groq", listOf("OpenScribe", "Kenpath"))).transcribe(wav)
        assertEquals("hello there", text)
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/v1/audio/transcriptions", request.url.encodedPath)
        assertEquals("Bearer sk-test", request.headers["Authorization"])
        assertTrue(request.headers["Content-Type"]!!.startsWith("multipart/form-data; boundary="))
        val body = request.body!!.string(Charsets.ISO_8859_1)
        val model = body.indexOf("name=\"model\"\r\n")
        val format = body.indexOf("name=\"response_format\"")
        val prompt = body.indexOf("name=\"prompt\"")
        val file = body.indexOf("name=\"file\"; filename=\"openscribe.wav\"")
        assertTrue(model in 0 until format && format < prompt && prompt < file)
        assertTrue(body.contains("whisper-large-v3\r\n"))
        assertTrue(body.contains("json\r\n"))
        assertTrue(body.contains("Glossary: OpenScribe, Kenpath.\r\n"))
        assertTrue(body.contains("Content-Type: audio/wav"))
        assertTrue(body.contains("RIFF"))
    }

    @Test fun mistralSendsContextBiasAndOpenRouterSendsJsonWithHints() {
        val mistral = FileTranscriber(http, config("mistral", listOf("Open Scribe", "Kenpath,AI")))
        val body = Buffer().also { mistral.request(ByteArray(10)).body!!.writeTo(it) }.readUtf8()
        assertTrue(body.contains("name=\"context_bias\"\r\n"))
        assertTrue(body.contains("Open,Scribe,Kenpath,AI\r\n"))
        assertFalse(body.contains("name=\"prompt\""))

        server.enqueue(MockResponse.Builder().body("""{"text":"voxtral"}""").build())
        val router = FileTranscriber(http, config("openRouter", listOf("OpenScribe"), model = "mistralai/voxtral-mini-transcribe"))
        assertEquals("voxtral", router.transcribe(byteArrayOf(1, 2, 3)))
        val request = server.takeRequest()
        assertEquals("application/json; charset=utf-8", request.headers["Content-Type"])
        assertEquals("https://openscribe.local", request.headers["HTTP-Referer"])
        assertEquals("OpenScribe", request.headers["X-Title"])
        val json = JSONObject(request.body!!.utf8())
        assertEquals("mistralai/voxtral-mini-transcribe", json.getString("model"))
        assertEquals(Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3)), json.getJSONObject("input_audio").getString("data"))
        assertEquals("wav", json.getJSONObject("input_audio").getString("format"))
        val options = json.getJSONObject("provider").getJSONObject("options")
        assertEquals("OpenScribe", options.getJSONObject("mistral").getString("context_bias"))
        assertEquals("Glossary: OpenScribe.", options.getJSONObject("openai").getString("prompt"))
        assertEquals(setOf("mistral", "openai", "groq", "fireworks", "deepinfra", "together"), options.keys().asSequence().toSet())

        // Without hints, OpenRouter gets the plain multipart form.
        val plain = FileTranscriber(http, config("openRouter")).request(ByteArray(4))
        assertTrue(plain.body!!.contentType().toString().startsWith("multipart/form-data"))
    }

    @Test fun deepgramPrerecorded() {
        server.enqueue(MockResponse.Builder().body("""{"results":{"channels":[{"alternatives":[{"transcript":"deep words"}]}]}}""").build())
        val deepgram = FileTranscriber(http, config("deepgram", listOf("OpenScribe", "Kenpath"), model = "nova-3"))
        assertEquals("deep words", deepgram.transcribe(byteArrayOf(0)))
        val request = server.takeRequest()
        assertEquals("/v1/listen", request.url.encodedPath)
        assertEquals("Token sk-test", request.headers["Authorization"])
        assertEquals("audio/wav", request.headers["Content-Type"])
        assertEquals("nova-3", request.url.queryParameter("model"))
        assertEquals("true", request.url.queryParameter("smart_format"))
        assertEquals("true", request.url.queryParameter("punctuate"))
        assertEquals(listOf("OpenScribe", "Kenpath"), request.url.queryParameterValues("keyterm"))
        val nova2 = FileTranscriber(http, config("deepgram", listOf("A1"), model = "nova-2")).request(ByteArray(1))
        assertEquals(listOf("A1"), nova2.url.queryParameterValues("keywords"))
    }

    // Chunked transcription

    @Test fun chunkedUploadsSegmentsWhileTalkingThenSendsTheJoinedText() {
        server.enqueue(MockResponse.Builder().body("""{"text":"first part"}""").build())
        server.enqueue(MockResponse.Builder().body("""{"text":"second part"}""").build())
        val collector = Collector()
        val files = FileTranscriber(http, config("openAI"))
        val chunked = ChunkedTranscriber(files::transcribe, collector)
        chunked.start()
        val audio = TestAudio.bytes(TestAudio.tone(1_000), TestAudio.silence(800), TestAudio.tone(600))
        for (offset in audio.indices step 1_280) chunked.feed(audio, offset, minOf(1_280, audio.size - offset))
        // The first segment went up while "talking".
        assertEquals("first part", collector.partials.poll(10, TimeUnit.SECONDS))
        val first = server.takeRequest()
        assertEquals("/v1/audio/transcriptions", first.url.encodedPath)
        chunked.finish()
        assertEquals("first part second part", collector.await().getOrThrow())
        assertEquals(2, server.requestCount)
    }

    @Test fun chunkedKeepsOrderWhenSegmentsFinishOutOfOrder() {
        val collector = Collector()
        val release = CountDownLatch(1)
        val uploads = java.util.concurrent.atomic.AtomicInteger()
        val chunked = ChunkedTranscriber({ _ ->
            val n = uploads.incrementAndGet()
            // The first upload is slow; the second and third come back before it.
            if (n == 1) release.await(5, TimeUnit.SECONDS)
            "segment $n"
        }, collector)
        val audio = TestAudio.bytes(
            TestAudio.tone(500), TestAudio.silence(700), TestAudio.tone(500), TestAudio.silence(700), TestAudio.tone(500),
        )
        chunked.feed(audio, 0, audio.size)
        chunked.finish()
        Thread.sleep(300)
        assertNull("no partial until the first segment is back", collector.partials.poll())
        release.countDown()
        assertEquals("segment 1 segment 2 segment 3", collector.await().getOrThrow())
    }

    @Test fun chunkedRetriesOnceThenReportsTheError() {
        server.enqueue(MockResponse.Builder().code(503).build())
        server.enqueue(MockResponse.Builder().body("""{"text":"after retry"}""").build())
        server.enqueue(MockResponse.Builder().code(401).build())
        val collector = Collector()
        val chunked = ChunkedTranscriber(FileTranscriber(http, config("openAI"))::transcribe, collector, maxInFlight = 1, retryDelayMs = 10)
        val audio = TestAudio.bytes(TestAudio.tone(500), TestAudio.silence(700), TestAudio.tone(500))
        chunked.feed(audio, 0, audio.size)
        chunked.finish()
        val error = collector.await().exceptionOrNull() as SpeechException
        assertEquals(401, error.status)
        assertEquals(3, server.requestCount)
    }
}
