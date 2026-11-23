package org.opensource.openscribe.speech

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.sqrt

/** A RIFF/WAVE file around 16-bit PCM, the format every file endpoint accepts. */
object Wav {
    const val HEADER_BYTES = 44

    fun encode(pcm: ByteArray, offset: Int = 0, length: Int = pcm.size - offset, sampleRate: Int = 16_000, channels: Int = 1): ByteArray {
        val bitsPerSample = 16
        val blockAlign = channels * bitsPerSample / 8
        val out = ByteBuffer.allocate(HEADER_BYTES + length).order(ByteOrder.LITTLE_ENDIAN)
        out.put("RIFF".toByteArray(Charsets.US_ASCII))
        out.putInt(36 + length)
        out.put("WAVE".toByteArray(Charsets.US_ASCII))
        out.put("fmt ".toByteArray(Charsets.US_ASCII))
        out.putInt(16) // PCM fmt chunk size
        out.putShort(1) // PCM
        out.putShort(channels.toShort())
        out.putInt(sampleRate)
        out.putInt(sampleRate * blockAlign)
        out.putShort(blockAlign.toShort())
        out.putShort(bitsPerSample.toShort())
        out.put("data".toByteArray(Charsets.US_ASCII))
        out.putInt(length)
        out.put(pcm, offset, length)
        return out.array()
    }
}

internal object Pcm {
    fun toShorts(bytes: ByteArray, offset: Int, length: Int): ShortArray {
        val out = ShortArray(length / 2)
        ByteBuffer.wrap(bytes, offset, out.size * 2).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(out)
        return out
    }

    fun toBytes(samples: ShortArray, offset: Int = 0, count: Int = samples.size - offset): ByteArray {
        val out = ByteBuffer.allocate(count * 2).order(ByteOrder.LITTLE_ENDIAN)
        out.asShortBuffer().put(samples, offset, count)
        return out.array()
    }

    fun rmsDb(samples: ShortArray, offset: Int, count: Int): Double {
        if (count <= 0) return -120.0
        var sum = 0.0
        for (i in offset until offset + count) {
            val x = samples[i] / 32768.0
            sum += x * x
        }
        val rms = sqrt(sum / count)
        return if (rms <= 1e-6) -120.0 else 20.0 * log10(rms)
    }
}

/**
 * Streaming linear-interpolation resampler for mono PCM16 (16 kHz → 24 kHz for OpenAI's realtime API). Keeps the
 * last input sample between calls, so frame boundaries don't click.
 */
class LinearResampler(private val inRate: Int, private val outRate: Int) {
    private val step = inRate.toDouble() / outRate
    private var carry: Short? = null
    /** Position of the next output sample in the extended block (index 0 is [carry] when there is one). */
    private var position = 0.0

    fun process(input: ShortArray): ShortArray {
        if (inRate == outRate) return input.copyOf()
        if (input.isEmpty()) return ShortArray(0)
        val extended = carry?.let { shortArrayOf(it) + input } ?: input
        val last = extended.size - 1
        val out = ShortArray(((last - position) / step).toInt() + 2)
        var count = 0
        while (position < last) {
            val i = position.toInt()
            val frac = position - i
            out[count++] = (extended[i] + (extended[i + 1] - extended[i]) * frac).toInt().coerceIn(-32768, 32767).toShort()
            position += step
        }
        position -= last
        carry = extended[last]
        return out.copyOf(count)
    }
}

/**
 * Cuts a recording into speech segments at natural pauses for file transcription: a cut after [silenceMs] of
 * silence following speech, or at the quietest point of the last [searchMs] once a segment reaches [maxMs].
 * Leading silence is trimmed to [prerollMs]; trailing silence to [tailMs]. Segments with less than [minSpeechMs]
 * of speech (a click, a breath) are dropped, so silence is never uploaded. Energy-based, on 20 ms windows: a
 * window is speech when its RMS is [marginDb] above a tracked noise floor (and at least [minThresholdDb]).
 * Not thread-safe.
 */
class SegmentCutter(
    private val sampleRate: Int = 16_000,
    private val silenceMs: Int = 600,
    private val maxMs: Int = 8_000,
    private val searchMs: Int = 1_500,
    private val prerollMs: Int = 300,
    private val tailMs: Int = 300,
    private val minSpeechMs: Int = 120,
    private val minThresholdDb: Double = -50.0,
    private val maxThresholdDb: Double = -30.0,
    private val marginDb: Double = 12.0,
    private val onSegment: (ByteArray) -> Unit,
) {
    private val window = sampleRate / 50 // 20 ms
    private val windowMs = 20
    private var samples = ShortArray(sampleRate * 10)
    private var length = 0 // samples in the current segment (whole windows)
    private val energies = ArrayList<Double>()
    private val speech = ArrayList<Boolean>()
    private val pending = ShortArray(window)
    private var pendingCount = 0
    private var noiseFloorDb = -60.0

    fun feed(pcm: ByteArray, offset: Int = 0, count: Int = pcm.size - offset) {
        val input = Pcm.toShorts(pcm, offset, count)
        var i = 0
        while (i < input.size) {
            val n = minOf(window - pendingCount, input.size - i)
            System.arraycopy(input, i, pending, pendingCount, n)
            pendingCount += n
            i += n
            if (pendingCount == window) {
                addWindow(pending, window)
                pendingCount = 0
            }
        }
    }

    /** End of the recording: emits the last segment if it holds speech. */
    fun finish() {
        if (pendingCount > 0) {
            addWindow(pending, pendingCount)
            pendingCount = 0
        }
        if (speechMs(0, speech.size) >= minSpeechMs) emit(trailingCut())
        reset()
    }

    private fun reset() {
        length = 0
        energies.clear()
        speech.clear()
    }

    private fun addWindow(window: ShortArray, count: Int) {
        val db = Pcm.rmsDb(window, 0, count)
        val threshold = (noiseFloorDb + marginDb).coerceIn(minThresholdDb, maxThresholdDb)
        val isSpeech = db >= threshold
        // The floor follows quiet quickly and loud slowly, so steady speech doesn't become "noise".
        noiseFloorDb += (db.coerceAtLeast(-90.0) - noiseFloorDb) * (if (db < noiseFloorDb) 0.3 else 0.005)

        if (length + count > samples.size) samples = samples.copyOf(maxOf(samples.size * 2, length + count))
        System.arraycopy(window, 0, samples, length, count)
        length += count
        energies.add(db)
        speech.add(isSpeech)

        val heardMs = speechMs(0, speech.size)
        val silentRun = trailingSilentWindows()
        when {
            heardMs == 0 -> dropLeading(keepWindows = prerollMs / windowMs)
            silentRun * windowMs >= silenceMs -> {
                if (heardMs >= minSpeechMs) emit(trailingCut()) else dropLeading(keepWindows = prerollMs / windowMs)
                if (speech.none { it }) dropLeading(keepWindows = prerollMs / windowMs)
            }
            speech.size * windowMs >= maxMs -> emit(quietestCut())
        }
    }

    private fun speechMs(from: Int, to: Int): Int = (from until to).count { speech[it] } * windowMs

    private fun trailingSilentWindows(): Int {
        var n = 0
        for (i in speech.indices.reversed()) { if (speech[i]) break; n++ }
        return n
    }

    /** Window count to emit when a pause ends the segment: the speech plus [tailMs] of what followed. */
    private fun trailingCut(): Int = (speech.size - trailingSilentWindows() + tailMs / windowMs).coerceAtMost(speech.size)

    /** Window count to emit at the max length: up to and including the quietest window of the last [searchMs]. */
    private fun quietestCut(): Int {
        val from = (speech.size - searchMs / windowMs).coerceAtLeast(1)
        var best = speech.size - 1
        for (i in from until speech.size) if (energies[i] < energies[best]) best = i
        return best + 1
    }

    /** Emits the first [windows] windows as a segment and keeps the rest for the next one. */
    private fun emit(windows: Int) {
        // Only the very last window can be partial (at finish).
        val sampleCount = if (windows >= energies.size) length else windows * window
        onSegment(Pcm.toBytes(samples, 0, sampleCount))
        removeLeading(windows, sampleCount)
    }

    private fun dropLeading(keepWindows: Int) {
        val drop = energies.size - keepWindows
        if (drop > 0) removeLeading(drop, drop * window)
    }

    private fun removeLeading(windows: Int, sampleCount: Int) {
        System.arraycopy(samples, sampleCount, samples, 0, length - sampleCount)
        length -= sampleCount
        repeat(windows) { energies.removeAt(0); speech.removeAt(0) }
    }
}

/** Texts of segments transcribed in parallel, joined in recording order however they finish. Thread-safe. */
class OrderedTexts {
    private val texts = ArrayList<String?>()

    @Synchronized fun reserve(): Int {
        texts.add(null)
        return texts.size - 1
    }

    @Synchronized fun complete(index: Int, text: String) {
        texts[index] = text.trim()
    }

    /** Segments finished so far, up to the first one still in flight. */
    @Synchronized fun prefix(): String = join(texts.takeWhile { it != null })

    @Synchronized fun isComplete(): Boolean = texts.all { it != null }

    @Synchronized fun all(): String = join(texts)

    private fun join(parts: List<String?>) = parts.filterNotNull().filter { it.isNotEmpty() }.joinToString(" ")
}
