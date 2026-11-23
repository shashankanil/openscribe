package org.opensource.openscribe.speech

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * File transcription while you talk: [SegmentCutter] cuts the audio at pauses, each segment is uploaded as a
 * 16 kHz WAV as soon as it is cut (up to [maxInFlight] at once), and the texts are joined in order. After each
 * segment the joined text so far goes to [TranscriberListener.onPartial]; after [finish], the last segment is cut
 * and the full text goes to onFinal once every upload is back. A failed upload is retried once when that might
 * help; a second failure ends the talk with onError.
 */
class ChunkedTranscriber(
    private val upload: (ByteArray) -> String,
    private val listener: TranscriberListener,
    private val maxInFlight: Int = 3,
    private val retryDelayMs: Long = 400,
    cutter: ((ByteArray) -> Unit) -> SegmentCutter = { SegmentCutter(onSegment = it) },
) : Transcriber {
    private val lock = Any()
    private val texts = OrderedTexts()
    private val inFlight = AtomicInteger()
    private val segments = cutter(::submit)
    private val executor: ExecutorService = Executors.newFixedThreadPool(maxInFlight) { r ->
        Thread(r, "openscribe-speech-upload").apply { isDaemon = true }
    }
    private var finishing = false
    @Volatile private var over = false
    private var lastPartial = ""

    override fun start() {}

    override fun feed(pcm: ByteArray, offset: Int, length: Int) {
        synchronized(lock) {
            if (over || finishing) return
            segments.feed(pcm, offset, length)
        }
    }

    override fun finish() {
        synchronized(lock) {
            if (over || finishing) return
            finishing = true
            segments.finish()
        }
        maybeDone()
    }

    override fun cancel() {
        over = true
        executor.shutdownNow()
    }

    /** Called by the cutter, under [lock]. */
    private fun submit(pcm: ByteArray) {
        val index = texts.reserve()
        inFlight.incrementAndGet()
        val wav = Wav.encode(pcm)
        try {
            executor.execute { run(index, wav) }
        } catch (e: Exception) {
            inFlight.decrementAndGet()
            fail(SpeechException("Transcription stopped"))
        }
    }

    private fun run(index: Int, wav: ByteArray) {
        val text = try {
            try {
                upload(wav)
            } catch (e: SpeechException) {
                if (!e.retryable || over) throw e
                Thread.sleep(retryDelayMs)
                upload(wav)
            }
        } catch (e: InterruptedException) {
            return
        } catch (e: Exception) {
            inFlight.decrementAndGet()
            fail(e)
            return
        }
        texts.complete(index, text)
        inFlight.decrementAndGet()
        val partial = texts.prefix()
        val send = synchronized(lock) {
            if (over || partial == lastPartial) false else { lastPartial = partial; true }
        }
        if (send) listener.onPartial(partial)
        maybeDone()
    }

    private fun maybeDone() {
        val text = synchronized(lock) {
            if (over || !finishing || inFlight.get() > 0 || !texts.isComplete()) return
            over = true
            texts.all()
        }
        executor.shutdown()
        listener.onFinal(text)
    }

    private fun fail(error: Exception) {
        synchronized(lock) {
            if (over) return
            over = true
        }
        executor.shutdownNow()
        listener.onError(error)
    }
}
