package org.opensource.openscribe.speech

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AudioTest {
    private fun cut(audio: ByteArray, chunk: Int = audio.size): List<ByteArray> {
        val segments = ArrayList<ByteArray>()
        val cutter = SegmentCutter { segments.add(it) }
        var offset = 0
        while (offset < audio.size) {
            val n = minOf(chunk, audio.size - offset)
            cutter.feed(audio, offset, n)
            offset += n
        }
        cutter.finish()
        return segments
    }

    @Test fun cutsAtPausesOfAboutSixHundredMilliseconds() {
        val audio = TestAudio.bytes(
            TestAudio.tone(1_000), TestAudio.silence(1_000),
            TestAudio.tone(1_500), TestAudio.hiss(900),
            TestAudio.tone(700),
        )
        val segments = cut(audio)
        assertEquals(3, segments.size)
        // Speech plus a 300 ms tail; later segments also start with up to 300 ms of what came before.
        assertEquals(1_300, TestAudio.ms(segments[0]))
        assertEquals(2_100, TestAudio.ms(segments[1]))
        assertEquals(1_000, TestAudio.ms(segments[2]))
    }

    @Test fun shortPausesDoNotCut() {
        val audio = TestAudio.bytes(TestAudio.tone(800), TestAudio.silence(400), TestAudio.tone(800), TestAudio.silence(200))
        val segments = cut(audio)
        assertEquals(1, segments.size)
        assertEquals(2_200, TestAudio.ms(segments[0]))
    }

    @Test fun longSpeechIsCutAtMostEveryEightSeconds() {
        val audio = TestAudio.bytes(TestAudio.tone(20_000))
        val segments = cut(audio)
        assertTrue("${segments.size} segments", segments.size in 3..4)
        segments.forEach { assertTrue(TestAudio.ms(it) in 6_500..8_000 || it === segments.last()) }
        assertEquals(20_000, segments.sumOf { TestAudio.ms(it) })
    }

    @Test fun longSpeechIsCutAtTheQuietestRecentPoint() {
        // A soft 100 ms dip (still speech) at 7.0 s: the 8 s cut lands there rather than mid-word.
        val audio = TestAudio.bytes(TestAudio.tone(7_000), TestAudio.tone(100, amplitude = 1_500), TestAudio.tone(3_000))
        val segments = cut(audio)
        assertEquals(2, segments.size)
        val first = TestAudio.ms(segments[0])
        assertTrue("first segment was $first ms", first in 7_000..7_100)
    }

    @Test fun silenceAndClicksAreNeverUploaded() {
        assertEquals(0, cut(TestAudio.bytes(TestAudio.silence(5_000))).size)
        assertEquals(0, cut(TestAudio.bytes(TestAudio.hiss(5_000))).size)
        // A 40 ms click is too short to be speech.
        assertEquals(0, cut(TestAudio.bytes(TestAudio.silence(500), TestAudio.tone(40), TestAudio.silence(2_000))).size)
    }

    @Test fun chunkSizeDoesNotChangeTheCuts() {
        val audio = TestAudio.bytes(TestAudio.tone(1_000), TestAudio.silence(800), TestAudio.tone(1_200), TestAudio.silence(100))
        val whole = cut(audio)
        val frames = cut(audio, chunk = 1_280)
        val odd = cut(audio, chunk = 1_002)
        assertEquals(whole.size, frames.size)
        whole.indices.forEach {
            assertArrayEquals(whole[it], frames[it])
            assertArrayEquals(whole[it], odd[it])
        }
    }

    @Test fun wavHeaderIsCorrect() {
        val pcm = TestAudio.bytes(TestAudio.tone(250))
        val wav = Wav.encode(pcm)
        assertEquals(44 + pcm.size, wav.size)
        val b = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        fun ascii(at: Int) = String(wav, at, 4, Charsets.US_ASCII)
        assertEquals("RIFF", ascii(0))
        assertEquals(36 + pcm.size, b.getInt(4))
        assertEquals("WAVE", ascii(8))
        assertEquals("fmt ", ascii(12))
        assertEquals(16, b.getInt(16))
        assertEquals(1, b.getShort(20).toInt()) // PCM
        assertEquals(1, b.getShort(22).toInt()) // mono
        assertEquals(16_000, b.getInt(24))
        assertEquals(32_000, b.getInt(28)) // byte rate
        assertEquals(2, b.getShort(32).toInt()) // block align
        assertEquals(16, b.getShort(34).toInt()) // bits
        assertEquals("data", ascii(36))
        assertEquals(pcm.size, b.getInt(40))
        assertArrayEquals(pcm, wav.copyOfRange(44, wav.size))
    }

    @Test fun resamplesSixteenToTwentyFourKilohertz() {
        val input = TestAudio.tone(1_000)
        val resampler = LinearResampler(16_000, 24_000)
        // In 40 ms frames, as the recorder delivers them.
        val out = (0 until input.size step 640).flatMap { resampler.process(input.copyOfRange(it, minOf(it + 640, input.size))).toList() }
        assertTrue("got ${out.size}", out.size in 23_990..24_000)
        // Every second input sample lands exactly on an output sample.
        assertEquals(input[2].toDouble(), out[3].toDouble(), 1.0)
        assertEquals(input[1000].toDouble(), out[1500].toDouble(), 1.0)
    }

    @Test fun joinsSegmentsInOrderWhateverOrderTheyFinish() {
        val texts = OrderedTexts()
        val a = texts.reserve(); val b = texts.reserve(); val c = texts.reserve()
        texts.complete(c, "three")
        assertEquals("", texts.prefix())
        texts.complete(a, " one ")
        assertEquals("one", texts.prefix())
        assertTrue(!texts.isComplete())
        texts.complete(b, "")
        assertEquals("one three", texts.all())
        assertTrue(texts.isComplete())
    }
}
