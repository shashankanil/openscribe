package org.opensource.openscribe.speech

import java.io.ByteArrayOutputStream

/** What a talk needs from the link to the Mac. Every call just queues a message; none block. */
interface TalkLink {
    /** Sends `talk_start` and returns the new talk's id, or null when not connected. */
    fun talkStart(textMode: Boolean): String?
    fun sendAudio(pcm: ByteArray, offset: Int, length: Int)
    fun talkPartial(id: String, text: String)
    fun talkText(id: String, text: String)
    fun talkEnd(id: String)
    fun talkCancel(id: String)
}

/** What the UI hears about a talk. Called on any thread. */
interface PhoneTalkEvents {
    /** Text heard on the phone so far (throttled like the partials sent to the Mac). */
    fun onHeard(text: String) {}
    /** Phone transcription failed and the talk now goes to the Mac as audio, under [newId]. */
    fun onSwitchedToAudio(newId: String) {}
    /** The fallback couldn't start because the link is down. */
    fun onLost() {}
}

/**
 * One press-to-talk. With a transcriber (the Mac shared its speech settings), the phone transcribes:
 * `talk_start` with `mode:"text"`, `talk_partial` at most every [partialIntervalMs], and `talk_text` at the end.
 * The recorded audio is kept (up to [maxBufferBytes]) so that if transcription fails at any point, the talk
 * switches to the audio path: `talk_cancel` for the text talk, then a plain `talk_start`, the buffered audio, live
 * audio from then on, and `talk_end` on release. Without a transcriber it is the audio path from the start.
 *
 * Thread-safe: [feed] runs on the microphone thread, transcriber callbacks on theirs, the rest on the main thread.
 */
class PhoneTalk(
    private val link: TalkLink,
    private val transcriber: ((TranscriberListener) -> Transcriber)?,
    private val events: PhoneTalkEvents,
    /** Runs a block after a delay (the main Handler in the app). */
    private val schedule: (Long, () -> Unit) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val partialIntervalMs: Long = 200,
    private val maxBufferBytes: Int = 16_000 * 2 * 300,
    private val fallbackChunkBytes: Int = 64 * 1024,
) {
    private enum class Mode { TEXT, AUDIO }

    private val lock = Any()
    private var mode = Mode.AUDIO
    private var active: Transcriber? = null
    private var buffer: ByteArrayOutputStream? = null
    private var ended = false
    private var finished = false
    private var cancelled = false
    private var lastPartialAt = Long.MIN_VALUE / 2
    private var pendingPartial: String? = null
    private var partialScheduled = false
    private var lastSentPartial: String? = null

    /** The current talk id: it changes once if the talk falls back to audio. */
    @Volatile var id: String = ""
        private set

    /** Whether the phone is (still) transcribing this talk. */
    val transcribing: Boolean get() = synchronized(lock) { mode == Mode.TEXT }

    /** Sends `talk_start` and starts transcribing. False when not connected. */
    fun start(): Boolean {
        synchronized(lock) {
            val factory = transcriber
            if (factory == null) {
                id = link.talkStart(textMode = false) ?: return false
                mode = Mode.AUDIO
                return true
            }
            id = link.talkStart(textMode = true) ?: return false
            mode = Mode.TEXT
            buffer = ByteArrayOutputStream(16_000 * 2 * 10)
            val created = factory(Listener())
            active = created
            try {
                created.start()
            } catch (e: Exception) {
                fallBack()
            }
            return true
        }
    }

    fun feed(pcm: ByteArray, offset: Int, length: Int) {
        val target = synchronized(lock) {
            if (ended || cancelled) return
            if (mode == Mode.AUDIO) {
                link.sendAudio(pcm, offset, length)
                return
            }
            buffer?.let { if (it.size() + length <= maxBufferBytes) it.write(pcm, offset, length) }
            active
        }
        target?.feed(pcm, offset, length)
    }

    /** Released: the text (or the audio) is complete. */
    fun end() {
        val target = synchronized(lock) {
            if (ended || cancelled) return
            ended = true
            if (mode == Mode.AUDIO) {
                link.talkEnd(id)
                finished = true
                return
            }
            active
        }
        target?.finish()
    }

    fun cancel() {
        val target = synchronized(lock) {
            if (cancelled) return
            cancelled = true
            val wasFinished = finished
            finished = true
            buffer = null
            if (!wasFinished) link.talkCancel(id)
            active.also { active = null }
        }
        target?.cancel()
    }

    /** Under [lock]. */
    private fun fallBack() {
        if (mode != Mode.TEXT || finished) return
        mode = Mode.AUDIO
        active?.cancel()
        active = null
        pendingPartial = null
        link.talkCancel(id)
        val newId = link.talkStart(textMode = false)
        if (newId == null) {
            finished = true
            buffer = null
            events.onLost()
            return
        }
        id = newId
        events.onSwitchedToAudio(newId)
        val audio = buffer?.toByteArray() ?: ByteArray(0)
        buffer = null
        var offset = 0
        while (offset < audio.size) {
            val n = minOf(fallbackChunkBytes, audio.size - offset)
            link.sendAudio(audio, offset, n)
            offset += n
        }
        if (ended) {
            link.talkEnd(newId)
            finished = true
        }
    }

    /** Under [lock]. */
    private fun sendPartial(text: String) {
        if (text == lastSentPartial) return
        lastSentPartial = text
        lastPartialAt = clock()
        link.talkPartial(id, text)
        events.onHeard(text)
    }

    private fun offerPartial(text: String) {
        synchronized(lock) {
            if (mode != Mode.TEXT || finished || cancelled) return
            val wait = lastPartialAt + partialIntervalMs - clock()
            if (wait <= 0 && !partialScheduled) {
                sendPartial(text)
                return
            }
            pendingPartial = text
            if (partialScheduled) return
            partialScheduled = true
            schedule(wait.coerceAtLeast(0)) {
                synchronized(lock) {
                    partialScheduled = false
                    val pending = pendingPartial ?: return@synchronized
                    pendingPartial = null
                    if (mode == Mode.TEXT && !finished && !cancelled) sendPartial(pending)
                }
            }
        }
    }

    private inner class Listener : TranscriberListener {
        /** False once the talk ended, was cancelled, or fell back: later callbacks are ignored. */
        private fun current() = synchronized(lock) { active != null }

        override fun onPartial(text: String) {
            if (current()) offerPartial(text)
        }

        override fun onFinal(text: String) {
            synchronized(lock) {
                if (!current() || mode != Mode.TEXT || finished || cancelled) return
                pendingPartial = null
                link.talkText(id, text)
                finished = true
                buffer = null
                active = null
            }
        }

        override fun onError(error: Exception) {
            synchronized(lock) {
                if (!current() || cancelled) return
                fallBack()
            }
        }
    }
}
