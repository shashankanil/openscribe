package org.opensource.openscribe.speech

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin

/** Synthetic 16 kHz PCM16 for the tests: a 220 Hz tone stands in for speech. */
object TestAudio {
    const val RATE = 16_000

    fun tone(ms: Int, amplitude: Int = 8_000): ShortArray =
        ShortArray(RATE * ms / 1000) { (amplitude * sin(2 * PI * 220 * it / RATE)).toInt().toShort() }

    fun silence(ms: Int): ShortArray = ShortArray(RATE * ms / 1000)

    /** Very quiet hiss, well under the speech threshold. */
    fun hiss(ms: Int, seed: Int = 1): ShortArray {
        val random = java.util.Random(seed.toLong())
        return ShortArray(RATE * ms / 1000) { (random.nextGaussian() * 20).toInt().toShort() }
    }

    fun bytes(vararg parts: ShortArray): ByteArray {
        val total = parts.sumOf { it.size }
        val out = ByteBuffer.allocate(total * 2).order(ByteOrder.LITTLE_ENDIAN)
        parts.forEach { part -> part.forEach { out.putShort(it) } }
        return out.array()
    }

    fun ms(bytes: ByteArray) = bytes.size / 2 * 1000 / RATE
}
