package org.opensource.openscribe.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

class WhisperBoostTest {
    private val frame = 640

    /** Runs [seconds] of a generated signal through the boost; returns the output of the last second. */
    private fun run(boost: WhisperBoost, seconds: Double, gen: (Int) -> Double): ShortArray {
        val total = (seconds * 16_000).toInt()
        val out = ShortArray(total)
        var n = 0
        while (n < total) {
            val count = minOf(frame, total - n)
            val buf = ShortArray(count) { (gen(n + it) * 32767).toInt().coerceIn(-32768, 32767).toShort() }
            boost.process(buf, count)
            System.arraycopy(buf, 0, out, n, count)
            n += count
        }
        return out.copyOfRange(total - 16_000, total)
    }

    private fun sine(amplitude: Double, hz: Double = 220.0) = { i: Int -> amplitude * sin(2 * PI * hz * i / 16_000) }

    @Test fun quietSineGetsLouder() {
        // About -43 dBFS RMS: a whisper.
        val input = WhisperBoost.rmsDb(ShortArray(16_000) { (sine(0.01)(it) * 32767).toInt().toShort() })
        val out = run(WhisperBoost(), 4.0, sine(0.01))
        val outDb = WhisperBoost.rmsDb(out)
        assertTrue("expected at least +18 dB, got ${outDb - input}", outDb - input >= 18.0)
        assertTrue("gain capped at +24 dB, got ${outDb - input}", outDb - input <= 24.5)
    }

    @Test fun normalSpeechLevelIsNotPushedFarPastTarget() {
        val out = run(WhisperBoost(), 3.0, sine(0.1)) // about -23 dBFS RMS
        val outDb = WhisperBoost.rmsDb(out)
        assertTrue("got $outDb", outDb in -24.0..-17.0)
    }

    @Test fun neverClips() {
        for (amplitude in listOf(0.01, 0.2, 0.7, 1.0)) {
            val boost = WhisperBoost()
            val all = mutableListOf<Short>()
            // Quiet first so the gain is high, then a sudden loud burst: the limiter has to catch it.
            run(boost, 2.0, sine(0.005))
            val burst = run(boost, 1.0, sine(amplitude))
            burst.forEach { all.add(it) }
            val peak = all.maxOf { abs(it.toInt()) }
            assertTrue("amplitude $amplitude peaked at $peak", peak < 32767)
        }
        val square = run(WhisperBoost(), 2.0) { i -> if ((i / 40) % 2 == 0) 1.0 else -1.0 }
        assertTrue(square.all { abs(it.toInt()) < 32767 })
    }

    @Test fun silenceStaysSilent() {
        val out = run(WhisperBoost(), 2.0) { 0.0 }
        assertTrue(out.all { it.toInt() == 0 })
    }

    @Test fun roomHissBelowTheGateIsNotAmplified() {
        val random = Random(42)
        val hiss = { _: Int -> random.nextGaussian() * 0.0005 } // about -66 dBFS
        val boost = WhisperBoost()
        val out = run(boost, 3.0, hiss)
        assertTrue("hiss came out at ${WhisperBoost.rmsDb(out)} dBFS", WhisperBoost.rmsDb(out) < -80.0)
    }

    @Test fun gateReopensForSpeechAfterSilence() {
        val boost = WhisperBoost()
        run(boost, 2.0) { 0.0 }
        val out = run(boost, 1.0, sine(0.01))
        assertTrue(WhisperBoost.rmsDb(out) > -30.0)
    }

    @Test fun meterLevel() {
        assertEquals(0f, WhisperBoost.meterLevel(-120.0))
        assertEquals(1f, WhisperBoost.meterLevel(0.0))
        assertEquals(0.5f, WhisperBoost.meterLevel(-35.0), 1e-6f)
    }
}
