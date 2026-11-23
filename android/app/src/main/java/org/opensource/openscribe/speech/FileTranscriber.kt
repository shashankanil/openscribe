package org.opensource.openscribe.speech

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.Base64

/**
 * One WAV file to text through the provider's file endpoint, with the same requests as the Mac's
 * `ProviderClient` (Sources/OpenScribe/ProviderClient.swift):
 * - OpenRouter, OpenAI, Groq, Mistral and custom: multipart `POST {url}/audio/transcriptions` with `model`,
 *   `response_format=json`, the hint field, and `file`. OpenRouter with hint terms sends JSON with `input_audio`
 *   and per-provider options instead, since its multipart form has no hint fields.
 * - Deepgram: prerecorded `POST {url}/listen` with the WAV as the body.
 *
 * AssemblyAI's upload-then-poll API is not used on the phone (see [Transcribers.mode]). Blocking.
 */
class FileTranscriber(private val http: OkHttpClient, private val config: SpeechConfig) {
    fun transcribe(wav: ByteArray): String {
        val request = request(wav)
        val body = try {
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) throw SpeechException("${title()} answered ${response.code}", response.code)
                response.body.string()
            }
        } catch (e: SpeechException) {
            throw e
        } catch (e: IOException) {
            throw SpeechException("Couldn't reach ${title()}: ${e.javaClass.simpleName}")
        }
        return parse(body)
    }

    fun request(wav: ByteArray): Request = when (config.provider) {
        SpeechConfig.DEEPGRAM -> deepgram(wav)
        SpeechConfig.OPEN_ROUTER, SpeechConfig.OPENAI, SpeechConfig.GROQ, SpeechConfig.MISTRAL, SpeechConfig.CUSTOM -> openAICompatible(wav)
        else -> throw SpeechException("${config.provider} file transcription isn't available on the phone")
    }

    fun parse(body: String): String {
        val json = try { JSONObject(body) } catch (e: Exception) { throw SpeechException("${title()} sent an unreadable reply") }
        val text = when (config.provider) {
            SpeechConfig.DEEPGRAM -> json.optJSONObject("results")?.optJSONArray("channels")?.optJSONObject(0)
                ?.optJSONArray("alternatives")?.optJSONObject(0)?.let { if (it.has("transcript") && !it.isNull("transcript")) it.optString("transcript") else null }
            else -> if (json.has("text") && !json.isNull("text")) json.optString("text") else null
        } ?: throw SpeechException("${title()} sent an unreadable reply")
        return text.trim()
    }

    private fun endpoint(path: String) =
        (config.baseUrl + path).toHttpUrlOrNull() ?: throw SpeechException("The transcription address is invalid")

    private fun openAICompatible(wav: ByteArray): Request {
        val url = endpoint("/audio/transcriptions")
        val builder = Request.Builder().url(url).header("Authorization", "Bearer ${config.key}")
        if (config.provider == SpeechConfig.OPEN_ROUTER) {
            builder.header("HTTP-Referer", "https://openscribe.local").header("X-Title", "OpenScribe")
            if (config.terms.isNotEmpty()) return builder.post(openRouterJson(wav).toString().toRequestBody(JSON)).build()
        }
        val hints = sortedMapOf<String, String>()
        if (config.provider == SpeechConfig.MISTRAL) Hints.contextBias(config.terms)?.let { hints["context_bias"] = it }
        else Hints.prompt(config.terms)?.let { hints["prompt"] = it }
        val form = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("model", config.model)
            .addFormDataPart("response_format", "json")
        hints.forEach { (name, value) -> form.addFormDataPart(name, value) }
        form.addFormDataPart("file", "openscribe.wav", wav.toRequestBody(WAV))
        return builder.post(form.build()).build()
    }

    /** OpenRouter routes to a serving provider, and each one takes hints in its own format. */
    fun openRouterJson(wav: ByteArray): JSONObject {
        val options = JSONObject()
        Hints.contextBias(config.terms)?.let { options.put("mistral", JSONObject().put("context_bias", it)) }
        Hints.prompt(config.terms)?.let { prompt ->
            for (provider in listOf("openai", "groq", "fireworks", "deepinfra", "together")) options.put(provider, JSONObject().put("prompt", prompt))
        }
        return JSONObject()
            .put("model", config.model)
            .put("input_audio", JSONObject().put("data", Base64.getEncoder().encodeToString(wav)).put("format", "wav"))
            .put("provider", JSONObject().put("options", options))
    }

    private fun deepgram(wav: ByteArray): Request {
        val url = endpoint("/listen").newBuilder()
            .addQueryParameter("model", config.model)
            .addQueryParameter("smart_format", "true")
            .addQueryParameter("punctuate", "true")
        // Nova-3 takes key terms; older models take keywords.
        val hintName = if (config.model.lowercase().startsWith("nova-3")) "keyterm" else "keywords"
        config.terms.take(50).forEach { url.addQueryParameter(hintName, it) }
        return Request.Builder().url(url.build())
            .header("Authorization", Hints.deepgramAuthorization(config.key))
            .post(wav.toRequestBody(WAV))
            .build()
    }

    private fun title() = when (config.provider) {
        SpeechConfig.OPEN_ROUTER -> "OpenRouter"
        SpeechConfig.OPENAI -> "OpenAI"
        SpeechConfig.GROQ -> "Groq"
        SpeechConfig.DEEPGRAM -> "Deepgram"
        SpeechConfig.ASSEMBLYAI -> "AssemblyAI"
        SpeechConfig.MISTRAL -> "Mistral"
        else -> "The transcription service"
    }

    companion object {
        private val WAV = "audio/wav".toMediaType()
        private val JSON = "application/json".toMediaType()
    }
}

/** The Mac's `SpeechHints` formats (Sources/OpenScribe/SmartDictionary.swift). */
object Hints {
    /** Whisper-style prompt: a short glossary the model treats as preceding context. */
    fun prompt(terms: List<String>): String? = if (terms.isEmpty()) null else "Glossary: " + terms.joinToString(", ") + "."

    /** Mistral's `context_bias`: single words, comma separated. Multi-word terms are sent word by word. */
    fun contextBias(terms: List<String>): String? {
        val seen = HashSet<String>()
        val words = terms.flatMap { term -> term.split(Regex("[\\s,]+")) }
            .filter { it.length > 1 && seen.add(it.lowercase()) }
        return if (words.isEmpty()) null else words.take(100).joinToString(",")
    }

    fun deepgramAuthorization(key: String) = if (key.startsWith("Token ")) key else "Token $key"
}
