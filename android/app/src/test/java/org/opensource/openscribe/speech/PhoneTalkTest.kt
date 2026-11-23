package org.opensource.openscribe.speech

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class PhoneTalkTest {
    /** Records what would go to the Mac. */
    private class FakeLink : TalkLink {
        val messages = ArrayList<String>()
        val audio = HashMap<String, ByteArrayOutputStream>()
        var connected = true
        private var next = 0
        override fun talkStart(textMode: Boolean): String? {
            if (!connected) return null
            val id = "t${next++}"
            messages += "start $id" + if (textMode) " text" else ""
            return id
        }
        override fun sendAudio(pcm: ByteArray, offset: Int, length: Int) {
            val id = messages.last { it.startsWith("start") }.split(' ')[1]
            audio.getOrPut(id) { ByteArrayOutputStream() }.write(pcm, offset, length)
        }
        override fun talkPartial(id: String, text: String) { messages += "partial $id $text" }
        override fun talkText(id: String, text: String) { messages += "text $id $text" }
        override fun talkEnd(id: String) { messages += "end $id" }
        override fun talkCancel(id: String) { messages += "cancel $id" }
    }

    /** A transcriber the test drives by hand. */
    private class FakeTranscriber(val listener: TranscriberListener) : Transcriber {
        val fed = ByteArrayOutputStream()
        var finished = false
        var cancelled = false
        override fun start() {}
        override fun feed(pcm: ByteArray, offset: Int, length: Int) { fed.write(pcm, offset, length) }
        override fun finish() { finished = true }
        override fun cancel() { cancelled = true }
    }

    private class Events : PhoneTalkEvents {
        val heard = ArrayList<String>()
        val switched = ArrayList<String>()
        override fun onHeard(text: String) { heard += text }
        override fun onSwitchedToAudio(newId: String) { switched += newId }
    }

    private var now = 0L
    private val scheduled = ArrayList<Pair<Long, () -> Unit>>()
    private fun runScheduled() {
        val due = scheduled.filter { it.first <= now }
        scheduled.removeAll(due)
        due.forEach { it.second() }
    }

    private fun talk(link: FakeLink, events: Events, made: MutableList<FakeTranscriber>?) = PhoneTalk(
        link = link,
        transcriber = made?.let { list -> { listener: TranscriberListener -> FakeTranscriber(listener).also { list += it } } },
        events = events,
        schedule = { delay, block -> scheduled += (now + delay) to block },
        clock = { now },
    )

    private val frame = ByteArray(1_280) { it.toByte() }

    @Test fun transcribesOnThePhoneAndSendsText() {
        val link = FakeLink(); val events = Events(); val made = ArrayList<FakeTranscriber>()
        val t = talk(link, events, made)
        assertTrue(t.start())
        assertTrue(t.transcribing)
        repeat(3) { t.feed(frame, 0, frame.size) }
        val transcriber = made.single()
        assertEquals(3 * frame.size, transcriber.fed.size())
        assertTrue("no audio goes to the Mac", link.audio.isEmpty())

        // Partials are throttled to one per 200 ms, and the latest one wins.
        transcriber.listener.onPartial("hel")
        now += 50; transcriber.listener.onPartial("hello")
        now += 50; transcriber.listener.onPartial("hello wor")
        assertEquals(listOf("start t0 text", "partial t0 hel"), link.messages)
        now = 200; runScheduled()
        assertEquals("partial t0 hello wor", link.messages.last())
        assertEquals(listOf("hel", "hello wor"), events.heard)

        t.end()
        assertTrue(transcriber.finished)
        transcriber.listener.onFinal("hello world")
        assertEquals("text t0 hello world", link.messages.last())
        // Nothing after the final text.
        transcriber.listener.onPartial("late")
        assertEquals("text t0 hello world", link.messages.last())
    }

    @Test fun fallsBackToAudioWhenTranscriptionFails() {
        val link = FakeLink(); val events = Events(); val made = ArrayList<FakeTranscriber>()
        val t = talk(link, events, made)
        t.start()
        val first = ByteArray(1_280) { 1 }
        val second = ByteArray(1_280) { 2 }
        t.feed(first, 0, first.size)
        t.feed(second, 0, second.size)
        made.single().listener.onError(SpeechException("401", 401))

        // The text talk is cancelled, and a plain one starts with everything recorded so far.
        assertEquals(listOf("start t0 text", "cancel t0", "start t1"), link.messages)
        assertEquals(listOf("t1"), events.switched)
        assertEquals("t1", t.id)
        assertFalse(t.transcribing)
        assertTrue(made.single().cancelled)
        assertArrayEquals(first + second, link.audio["t1"]!!.toByteArray())

        // Live audio follows, then talk_end on release.
        val third = ByteArray(640) { 3 }
        t.feed(third, 0, third.size)
        t.end()
        assertArrayEquals(first + second + third, link.audio["t1"]!!.toByteArray())
        assertEquals("end t1", link.messages.last())
        // A late result from the abandoned transcriber changes nothing.
        made.single().listener.onFinal("too late")
        assertEquals("end t1", link.messages.last())
    }

    @Test fun fallsBackAfterReleaseToo() {
        val link = FakeLink(); val events = Events(); val made = ArrayList<FakeTranscriber>()
        val t = talk(link, events, made)
        t.start()
        t.feed(frame, 0, frame.size)
        t.end()
        made.single().listener.onError(SpeechException("timeout"))
        assertEquals(listOf("start t0 text", "cancel t0", "start t1", "end t1"), link.messages)
        assertArrayEquals(frame, link.audio["t1"]!!.toByteArray())
    }

    @Test fun withoutSpeechSettingsAudioGoesToTheMacAsBefore() {
        val link = FakeLink(); val events = Events()
        val t = talk(link, events, null)
        t.start()
        assertFalse(t.transcribing)
        t.feed(frame, 0, frame.size)
        t.end()
        assertEquals(listOf("start t0", "end t0"), link.messages)
        assertArrayEquals(frame, link.audio["t0"]!!.toByteArray())
    }

    @Test fun cancelStopsTheTranscriber() {
        val link = FakeLink(); val events = Events(); val made = ArrayList<FakeTranscriber>()
        val t = talk(link, events, made)
        t.start()
        t.cancel()
        assertTrue(made.single().cancelled)
        assertEquals(listOf("start t0 text", "cancel t0"), link.messages)
        made.single().listener.onError(SpeechException("x"))
        assertEquals(listOf("start t0 text", "cancel t0"), link.messages)
    }
}
