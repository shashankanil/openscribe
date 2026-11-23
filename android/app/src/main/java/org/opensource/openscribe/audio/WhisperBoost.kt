package org.opensource.openscribe.audio

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlin.math.tanh

/**
 * Makes whispered speech loud enough for the Mac's speech detector without amplifying room hiss.
 *
 * Per frame (40 ms at 16 kHz):
 * - **Noise gate.** Frames whose RMS is below [gateFloorDb] close the gate after a short hold; the gate fades the
 *   output to silence and freezes the adaptive gain, so hiss between words is neither boosted nor kept.
 * - **Adaptive gain** toward [targetDb] RMS, between 0 dB and [maxGainDb]. Gain falls fast (attack) when the
 *   input gets louder and rises slowly (release), and is interpolated across each frame so it never zips.
 * - **Soft limiter.** Linear up to [kneeLevel], then a tanh curve that approaches but never reaches full scale.
 *
 * Pure Kotlin with no Android dependencies, so it is unit tested on the JVM. Not thread-safe.
 */
class WhisperBoost(
    private val sampleRate: Int = 16_000,
    private val targetDb: Double = -20.0,
    private val maxGainDb: Double = 24.0,
    private val initialGainDb: Double = 12.0,
    private val gateFloorDb: Double = -54.0,
    private val attackMs: Double = 60.0,
    private val releaseDbPerSecond: Double = 8.0,
    private val gateHoldMs: Double = 300.0,
    private val gateReleaseMs: Double = 80.0,
    private val kneeLevel: Double = 0.6,
) {
    private var gainDb = initialGainDb
    private var appliedGain = dbToLinear(initialGainDb)
    private var gate = 0.0
    private var holdLeftMs = 0.0

    /** RMS of the last processed output frame in dBFS (-120 for silence). */
    var lastOutputDb: Double = -120.0
        private set

    fun reset() {
        gainDb = initialGainDb
        appliedGain = dbToLinear(initialGainDb)
        gate = 0.0
        holdLeftMs = 0.0
        lastOutputDb = -120.0
    }

    /** Processes [count] samples of [samples] in place. */
    fun process(samples: ShortArray, count: Int = samples.size) {
        if (count <= 0) return
        val frameMs = count * 1000.0 / sampleRate

        var sumSquares = 0.0
        for (i in 0 until count) {
            val x = samples[i] / 32768.0
            sumSquares += x * x
        }
        val inputDb = linearToDb(sqrt(sumSquares / count))

        val open = inputDb >= gateFloorDb
        if (open) {
            holdLeftMs = gateHoldMs
            // Adaptive gain only follows real signal, so it does not creep up during silence.
            val desired = (targetDb - inputDb).coerceIn(0.0, maxGainDb)
            gainDb = if (desired < gainDb) {
                val coefficient = 1.0 - exp(-frameMs / attackMs)
                gainDb + (desired - gainDb) * coefficient
            } else {
                (gainDb + releaseDbPerSecond * frameMs / 1000.0).coerceAtMost(desired)
            }
        } else {
            holdLeftMs -= frameMs
        }
        val gateTarget = if (open || holdLeftMs > 0) 1.0 else 0.0
        val gateStart = gate
        gate = if (gateTarget > gate) 1.0 else gate * exp(-frameMs / gateReleaseMs)
        if (gate < 1e-3 && gateTarget == 0.0) gate = 0.0

        val gainStart = appliedGain
        val gainEnd = dbToLinear(gainDb)
        var outSquares = 0.0
        for (i in 0 until count) {
            val t = (i + 1).toDouble() / count
            val g = (gainStart + (gainEnd - gainStart) * t) * (gateStart + (gate - gateStart) * t)
            val y = softLimit(samples[i] / 32768.0 * g)
            val s = (y * 32767.0).roundToInt().coerceIn(-32767, 32767)
            samples[i] = s.toShort()
            val n = s / 32768.0
            outSquares += n * n
        }
        appliedGain = gainEnd
        lastOutputDb = linearToDb(sqrt(outSquares / count))
    }

    private fun softLimit(x: Double): Double {
        val a = abs(x)
        if (a <= kneeLevel) return x
        val headroom = 1.0 - kneeLevel
        val limited = kneeLevel + headroom * tanh((a - kneeLevel) / headroom)
        // tanh approaches 1, so cap a hair below full scale to keep the "never clips" promise after rounding.
        return (if (x < 0) -limited else limited).coerceIn(-MAX_OUT, MAX_OUT)
    }

    companion object {
        private const val MAX_OUT = 32766.0 / 32767.0

        fun dbToLinear(db: Double) = 10.0.pow(db / 20.0)
        fun linearToDb(level: Double) = if (level <= 1e-6) -120.0 else 20.0 * log10(level)

        /** Maps an RMS level in dBFS to 0..1 for the level ring: -60 dB and below is 0, -10 dB and up is 1. */
        fun meterLevel(db: Double): Float = ((db + 60.0) / 50.0).coerceIn(0.0, 1.0).toFloat()

        fun rmsDb(samples: ShortArray, count: Int = samples.size): Double {
            if (count <= 0) return -120.0
            var sum = 0.0
            for (i in 0 until count) {
                val x = samples[i] / 32768.0
                sum += x * x
            }
            return linearToDb(sqrt(sum / count))
        }
    }
}
