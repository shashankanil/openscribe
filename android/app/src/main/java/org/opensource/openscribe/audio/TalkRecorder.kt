package org.opensource.openscribe.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import org.opensource.openscribe.link.LinkProtocol
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Records 16 kHz mono PCM16 with `VOICE_RECOGNITION` (no system AGC or noise suppression), optionally applies
 * [WhisperBoost], and hands out 40 ms frames as little-endian bytes. [onLevel] gets 0..1 for the level ring.
 */
class TalkRecorder(
    private val whisperBoost: Boolean,
    private val onFrame: (ByteArray, Int) -> Unit,
    private val onLevel: (Float) -> Unit,
    private val onError: (String) -> Unit,
) {
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    /** Opens the microphone. Returns false (after [onError]) if it could not. Caller has checked RECORD_AUDIO. */
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        val rate = LinkProtocol.AUDIO_SAMPLE_RATE
        val minBuffer = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuffer <= 0) {
            onError("This phone cannot record 16 kHz audio.")
            return false
        }
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION, rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuffer, LinkProtocol.AUDIO_FRAME_BYTES * 8),
            )
        } catch (e: Exception) {
            onError("Microphone unavailable: ${e.message}")
            return false
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            onError("Microphone unavailable.")
            return false
        }
        try {
            recorder.startRecording()
        } catch (e: Exception) {
            recorder.release()
            onError("Microphone unavailable: ${e.message}")
            return false
        }
        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            recorder.release()
            onError("Another app is using the microphone.")
            return false
        }
        record = recorder
        running = true
        thread = Thread({ loop(recorder) }, "openscribe-mic").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        return true
    }

    /** Stops recording after the frame in progress has been delivered. Blocks briefly (≤ one read). */
    fun stop() {
        running = false
        try { thread?.join(500) } catch (_: InterruptedException) {}
        thread = null
        record?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        record = null
        onLevel(0f)
    }

    private fun loop(recorder: AudioRecord) {
        val samples = ShortArray(LinkProtocol.AUDIO_FRAME_SAMPLES)
        val bytes = ByteBuffer.allocate(LinkProtocol.AUDIO_FRAME_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        val boost = if (whisperBoost) WhisperBoost() else null
        var level = 0f
        var filled = 0
        fun emit(count: Int) {
            if (count == 0) return
            val db = if (boost != null) {
                boost.process(samples, count)
                boost.lastOutputDb
            } else WhisperBoost.rmsDb(samples, count)
            bytes.clear()
            bytes.asShortBuffer().put(samples, 0, count)
            onFrame(bytes.array(), count * 2)
            val target = WhisperBoost.meterLevel(db)
            level = if (target > level) target else level * 0.7f + target * 0.3f
            onLevel(level)
        }
        try {
            while (running) {
                val n = recorder.read(samples, filled, samples.size - filled, AudioRecord.READ_BLOCKING)
                if (n < 0) {
                    Log.w("OpenScribeMic", "read error $n")
                    onError("Microphone stopped (error $n).")
                    break
                }
                filled += n
                if (filled == samples.size) {
                    emit(filled)
                    filled = 0
                }
            }
            emit(filled) // Any partial frame: the protocol accepts audio of any length.
        } catch (e: Exception) {
            onError("Microphone stopped: ${e.message}")
        }
    }
}
