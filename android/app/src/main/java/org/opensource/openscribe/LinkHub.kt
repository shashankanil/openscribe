package org.opensource.openscribe

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Toast
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.opensource.openscribe.audio.TalkRecorder
import org.opensource.openscribe.link.BlobCipher
import org.opensource.openscribe.link.CloudBlobs
import org.opensource.openscribe.link.CloudConfig
import org.opensource.openscribe.link.CloudRelayDialer
import org.opensource.openscribe.link.ImageClip
import org.opensource.openscribe.link.LinkClient
import org.opensource.openscribe.link.LinkListener
import org.opensource.openscribe.link.LinkMessages
import org.opensource.openscribe.link.LinkPhase
import org.opensource.openscribe.link.LinkProtocol
import org.opensource.openscribe.link.LinkState
import org.opensource.openscribe.link.NsdEndpointResolver
import org.opensource.openscribe.link.PairingLink
import org.opensource.openscribe.link.TalkState
import org.opensource.openscribe.speech.PhoneTalk
import org.opensource.openscribe.speech.PhoneTalkEvents
import org.opensource.openscribe.speech.SpeechConfig
import org.opensource.openscribe.speech.TalkLink
import org.opensource.openscribe.speech.Transcribers
import java.io.File
import java.util.concurrent.Executors

/** What the talk area of the home screen shows. */
sealed interface TalkUi {
    data object Idle : TalkUi
    /**
     * Recording on the phone. [macListening] once the Mac has said `recording`; [target] is the Mac app.
     * [heard] is what the phone has transcribed so far, when it transcribes ([phoneTranscribes]).
     */
    data class Recording(
        val id: String,
        val locked: Boolean,
        val startedAt: Long,
        val macListening: Boolean = false,
        val target: String? = null,
        val pasted: Boolean? = null,
        val heard: String? = null,
        val phoneTranscribes: Boolean = false,
    ) : TalkUi
    data class Transcribing(val id: String, val target: String? = null, val pasted: Boolean? = null) : TalkUi
    /** [pasted] false means the Mac only saved it to Notes. */
    data class Done(val text: String, val target: String? = null, val pasted: Boolean? = null) : TalkUi
    data object Discarded : TalkUi
    data class Failed(val message: String) : TalkUi
}

data class ClipPreview(val text: String, val atMillis: Long, val confirmed: Boolean = false, val id: String? = null)

enum class ClipSource { APP, AUTO, SHARE, TILE }

/** One clipboard transfer, newest first in [LinkHub.clips]. Kept in memory only. [image] is set for image clips. */
data class ClipEntry(
    val id: String,
    val text: String,
    val toMac: Boolean,
    val atMillis: Long,
    val confirmed: Boolean,
    val image: File? = null,
)

/** Label on clips OpenScribe writes, so the home screen can tell a Mac copy apart without reading the clipboard. */
const val CLIP_LABEL = "OpenScribe"

/** Shown when an image can't be sent because the Mac hasn't shared OpenScribe Cloud access. */
const val CLOUD_NEEDED_MESSAGE =
    "Images need OpenScribe Cloud. On your Mac, sign in with Google in OpenScribe → Connect AI apps."

/**
 * Process-wide link state shared by [LinkService] (which owns the connection) and the UI. Everything here is
 * touched on the main thread; [LinkClient] callbacks are posted over.
 */
object LinkHub {
    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    lateinit var prefs: AppPrefs
        private set

    /** Every paired Mac. Only [pairing], the active one, is connected. */
    private val _pairings = MutableStateFlow<List<PairingLink>>(emptyList())
    val pairings: StateFlow<List<PairingLink>> = _pairings.asStateFlow()

    private val _pairing = MutableStateFlow<PairingLink?>(null)
    val pairing: StateFlow<PairingLink?> = _pairing.asStateFlow()

    private val _link = MutableStateFlow(LinkState(LinkPhase.STOPPED, ""))
    val link: StateFlow<LinkState> = _link.asStateFlow()

    private val _talk = MutableStateFlow<TalkUi>(TalkUi.Idle)
    val talk: StateFlow<TalkUi> = _talk.asStateFlow()

    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level.asStateFlow()

    private val _lastSent = MutableStateFlow<ClipPreview?>(null)
    val lastSent: StateFlow<ClipPreview?> = _lastSent.asStateFlow()

    private val _lastReceived = MutableStateFlow<ClipPreview?>(null)
    val lastReceived: StateFlow<ClipPreview?> = _lastReceived.asStateFlow()

    private val _clips = MutableStateFlow<List<ClipEntry>>(emptyList())
    val clips: StateFlow<List<ClipEntry>> = _clips.asStateFlow()

    /** OpenScribe Cloud access each paired Mac granted, by mac id. */
    private val _cloud = MutableStateFlow<Map<String, CloudConfig>>(emptyMap())
    val cloud: StateFlow<Map<String, CloudConfig>> = _cloud.asStateFlow()

    /** Cloud access for the active Mac, or null. Thread-safe. */
    val activeCloud: CloudConfig? get() = _pairing.value?.macId?.let { _cloud.value[it] }

    /** Transcription settings each paired Mac shared, by mac id. Never shown or logged: they hold an API key. */
    private val _speech = MutableStateFlow<Map<String, SpeechConfig>>(emptyMap())

    /** Whether the active Mac lets this phone transcribe (and how), for the UI. */
    val activeSpeechMode: Transcribers.Mode get() = Transcribers.mode(_pairing.value?.macId?.let { _speech.value[it] })

    private lateinit var secrets: MacSecrets
    private val http by lazy { CloudBlobs.httpClient() }
    private val speechHttp by lazy { Transcribers.httpClient(http) }
    private val blobs by lazy { CloudBlobs(http) }
    /** Image downloads, uploads and file work, one at a time and off the main thread. */
    private val io = Executors.newSingleThreadExecutor { Thread(it, "openscribe-images").apply { isDaemon = true } }

    private fun record(entry: ClipEntry) {
        _clips.value = (listOf(entry) + _clips.value.filterNot { it.id == entry.id }).take(MAX_CLIPS)
    }

    /** True while an activity of ours is started; [LinkService] holds the microphone FGS type meanwhile. */
    val uiVisible = MutableStateFlow(false)

    /** True while the talk button accessibility service is enabled and running. */
    val talkKeyServiceOn = MutableStateFlow(false)

    /** Set while Settings waits for the user to press the button they want; the service reports presses here. */
    @Volatile var keyLearner: ((TalkKey) -> Unit)? = null

    /** Bumped when the talk button changes, so the service can keep the microphone type for background talking. */
    val talkKeyChanged = MutableStateFlow(0)

    /** Bumped when RECORD_AUDIO is granted, so the service can add the microphone FGS type. */
    val micPermissionChanged = MutableStateFlow(0)

    @Volatile private var client: LinkClient? = null
    private var recorder: TalkRecorder? = null
    private var phoneTalk: PhoneTalk? = null
    private var talkStartedAt = 0L

    /** A clip waiting for the link to come up; [send] runs once it does, unless [deadline] has passed. */
    private class PendingClip(val deadline: Long, val send: () -> Unit)
    private var pendingClip: PendingClip? = null
    /** Clip id to source, for clips whose ack should produce a toast. */
    private val awaitingAck = HashMap<String, ClipSource>()

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        prefs = AppPrefs(app)
        secrets = PairingStore.secrets(app)
        val all = PairingStore.loadAll(app)
        _pairings.value = all
        val paired = all.map { it.macId }.toSet()
        _cloud.value = secrets.cloud().filterKeys { it in paired }
        _speech.value = secrets.speech().filterKeys { it in paired }
        _pairing.value = all.firstOrNull { it.macId == PairingStore.activeMacId(app) } ?: all.firstOrNull()
        _pairing.value?.let { _link.value = LinkState(LinkPhase.STOPPED, it.macName) }
        io.execute {
            try { ImageClips.cleanUp(app, paired) } catch (e: Exception) { android.util.Log.w("OpenScribe", "clip cleanup failed", e) }
        }
    }

    val macName: String get() = _link.value.macName.ifBlank { _pairing.value?.macName ?: "your Mac" }
    val isConnected: Boolean get() = client?.isConnected == true

    // Pairing

    /** Adds a Mac (or refreshes one paired again) and switches to it. */
    fun pair(link: PairingLink) {
        val all = _pairings.value.filterNot { it.macId == link.macId } + link
        PairingStore.saveAll(app, all)
        _pairings.value = all
        activate(link)
    }

    /** Connects to another paired Mac instead of the current one. */
    fun switchTo(macId: String) {
        if (_pairing.value?.macId == macId) return
        _pairings.value.firstOrNull { it.macId == macId }?.let(::activate)
    }

    /** Forgets a Mac. Forgetting the active one switches to another, or back to pairing if none are left. */
    fun forget(macId: String) {
        val all = _pairings.value.filterNot { it.macId == macId }
        PairingStore.saveAll(app, all)
        _pairings.value = all
        // Everything this Mac left on the phone: cloud access, speech settings and cached images.
        setCloud(macId, null)
        setSpeech(macId, null)
        io.execute { ImageClips.forgetMac(app, macId) }
        if (_pairing.value?.macId != macId) return
        val next = all.firstOrNull()
        if (next != null) activate(next)
        else {
            LinkService.stop(app)
            stopClient()
            PairingStore.setActiveMacId(app, null)
            resetSession(null)
        }
    }

    /** Forgets the active Mac. */
    fun unpair() { _pairing.value?.let { forget(it.macId) } }

    private fun activate(link: PairingLink) {
        if (_talk.value is TalkUi.Recording) cancelTalk()
        PairingStore.setActiveMacId(app, link.macId)
        resetSession(link)
        LinkService.start(app)
    }

    /**
     * Talk results and clipboard history belong to one Mac; start fresh when the Mac changes. The last sent and
     * received text are kept, so auto-send never hands one Mac's copy to another.
     */
    private fun resetSession(link: PairingLink?) {
        _clips.value = emptyList()
        _talk.value = TalkUi.Idle
        _link.value = LinkState(LinkPhase.STOPPED, link?.macName.orEmpty())
        _pairing.value = link
    }

    // Connection, driven by LinkService

    fun startClient(context: Context) {
        val pairing = _pairing.value ?: return
        stopClient()
        val listener = Listener()
        val resolver = NsdEndpointResolver(context, onFound = { listener.owner?.kick() })
        val relay = CloudRelayDialer(http, pairing, config = { _cloud.value[pairing.macId] })
        val created = LinkClient(pairing, deviceName(), BuildConfig.VERSION_NAME, resolver, listener, relay = relay, installId = prefs.installId)
        listener.owner = created
        client = created
        created.start()
    }

    fun stopClient() {
        if (_talk.value is TalkUi.Recording) cancelTalk()
        client?.stop()
        client = null
        _link.value = _link.value.copy(phase = LinkPhase.STOPPED)
    }

    /** A network appeared: retry now instead of waiting out the backoff. */
    fun kick() = client?.kick()

    /** The network we were on is gone or replaced: the socket is dead, so drop it rather than wait 45 s. */
    fun networkLost() = client?.reset()

    /** Retry now, restarting the service if the user disconnected it from the notification. */
    fun reconnect() {
        val c = client
        if (c == null) LinkService.start(app) else c.kick()
    }

    private fun deviceName(): String =
        Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: android.os.Build.MODEL

    /** Posts client callbacks to the main thread, dropping any from a client that has since been replaced. */
    private class Listener : LinkListener {
        @Volatile var owner: LinkClient? = null
        private fun post(block: () -> Unit) {
            main.post { if (owner != null && owner === client) block() }
        }
        override fun onState(state: LinkState) = post {
            onLinkState(state)
            // The Mac rejected this phone: its speech settings (and key) are no longer ours to use.
            if (state.phase == LinkPhase.UNPAIRED) owner?.let { setSpeech(it.pairing.macId, null) }
        }
        override fun onClip(id: String, text: String) = post { onClipFromMac(id, text) }
        override fun onImageClip(clip: ImageClip) = post { owner?.let { onImageFromMac(it, clip) } }
        override fun onCloud(config: CloudConfig?) = post { owner?.let { setCloud(it.pairing.macId, config) } }
        override fun onSpeech(config: SpeechConfig?) = post { owner?.let { setSpeech(it.pairing.macId, config) } }
        override fun onClipAck(id: String) = post { onAck(id) }
        override fun onTalkState(state: TalkState) = post { onMacTalkState(state) }
    }

    private fun onLinkState(state: LinkState) {
        _link.value = state
        if (state.phase == LinkPhase.CONNECTED) {
            pendingClip?.let { pending ->
                pendingClip = null
                if (System.currentTimeMillis() < pending.deadline) pending.send()
            }
        } else {
            val talk = _talk.value
            if (talk is TalkUi.Recording) {
                stopRecorder()
                val transcribing = phoneTalk?.transcribing == true
                phoneTalk?.cancel()
                phoneTalk = null
                _talk.value = TalkUi.Failed(
                    if (transcribing) "Connection lost before $macName got the text."
                    else "Connection lost. $macName will transcribe what it heard.",
                )
            } else if (talk is TalkUi.Transcribing) {
                _talk.value = TalkUi.Failed("Connection lost while ${macName} was transcribing.")
            }
        }
    }

    private fun onClipFromMac(id: String, text: String) {
        val clipboard = app.getSystemService(ClipboardManager::class.java)
        try {
            clipboard.setPrimaryClip(ClipData.newPlainText(CLIP_LABEL, text))
        } catch (e: Exception) {
            android.util.Log.w("OpenScribe", "clipboard write failed", e)
        }
        _lastReceived.value = ClipPreview(text, System.currentTimeMillis(), confirmed = true, id = id)
        record(ClipEntry(id, text, toMac = false, atMillis = System.currentTimeMillis(), confirmed = true))
    }

    /** Stores (or with null, clears) the cloud access a Mac granted. */
    private fun setCloud(macId: String, config: CloudConfig?) {
        val current = _cloud.value
        if (current[macId] == config) return
        val updated = if (config == null) current - macId else current + (macId to config)
        _cloud.value = updated
        secrets.saveCloud(updated)
    }

    /** Stores (or with null, clears) the speech settings a Mac shared. */
    private fun setSpeech(macId: String, config: SpeechConfig?) {
        val current = _speech.value
        if (current[macId] == config) return
        val updated = if (config == null) current - macId else current + (macId to config)
        _speech.value = updated
        secrets.saveSpeech(updated)
    }

    /** Downloads, opens and saves an image from the Mac, puts it on the clipboard, then acks it. */
    private fun onImageFromMac(from: LinkClient, clip: ImageClip) {
        val config = _cloud.value[from.pairing.macId]
        if (config == null) {
            toast(CLOUD_NEEDED_MESSAGE, long = true)
            return
        }
        io.execute {
            try {
                val plain = BlobCipher.open(clip.key, blobs.download(config, clip.blob))
                val mime = ImageClips.sniffMime(plain) ?: clip.mime
                val file = ImageClips.save(app, from.pairing.macId, clip.id, mime, plain)
                main.post {
                    try {
                        app.getSystemService(ClipboardManager::class.java).setPrimaryClip(ImageClips.clipData(app, file))
                    } catch (e: Exception) {
                        android.util.Log.w("OpenScribe", "clipboard write failed", e)
                        return@post
                    }
                    if (from === client) {
                        record(ClipEntry(clip.id, imageLabel(plain.size), toMac = false, atMillis = System.currentTimeMillis(), confirmed = true, image = file))
                    }
                    from.ackClip(clip.id)
                }
            } catch (e: Exception) {
                android.util.Log.w("OpenScribe", "image from Mac failed", e)
                toast("Couldn't get the image from ${from.pairing.macName}: ${e.message ?: "unknown error"}")
            }
        }
    }

    private fun imageLabel(bytes: Int): String = "Image · " + when {
        bytes >= 1024 * 1024 -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
        else -> "${(bytes + 1023) / 1024} KB"
    }

    private fun onAck(id: String) {
        _lastSent.value?.takeIf { it.id == id }?.let { _lastSent.value = it.copy(confirmed = true) }
        _clips.value = _clips.value.map { if (it.id == id) it.copy(confirmed = true) else it }
        val source = awaitingAck.remove(id) ?: return
        if (source == ClipSource.SHARE || source == ClipSource.TILE) toast("Sent to $macName")
    }

    private fun onMacTalkState(state: TalkState) {
        val current = _talk.value
        val currentId = when (current) {
            is TalkUi.Recording -> current.id
            is TalkUi.Transcribing -> current.id
            else -> lastTalkId
        }
        if (state.id != currentId) return
        val target = state.target ?: (current as? TalkUi.Recording)?.target ?: (current as? TalkUi.Transcribing)?.target
        val pasted = state.pasted ?: (current as? TalkUi.Recording)?.pasted ?: (current as? TalkUi.Transcribing)?.pasted
        _talk.value = when (state.state) {
            "recording" -> if (current is TalkUi.Recording) current.copy(macListening = true, target = target, pasted = pasted) else current
            "transcribing" -> if (current is TalkUi.Recording) current else TalkUi.Transcribing(state.id, target, pasted)
            "done" -> {
                prefs.talkCount = prefs.talkCount + 1
                if (!uiVisible.value) buzz(Buzz.DONE)
                TalkUi.Done(state.text.orEmpty(), target, pasted)
            }
            "discarded" -> TalkUi.Discarded
            "failed" -> {
                if (!uiVisible.value) buzz(Buzz.ERROR)
                TalkUi.Failed(state.error?.takeIf { it.isNotBlank() } ?: "Transcription failed on $macName.")
            }
            else -> current
        }
    }

    // Clipboard

    /** Reads from the clipboard are the caller's job: Android only allows them while we are in the foreground. */
    fun sendClip(text: String, source: ClipSource) {
        val quiet = source == ClipSource.APP || source == ClipSource.AUTO
        if (text.isEmpty()) {
            if (!quiet) toast("The clipboard is empty")
            return
        }
        if (text.toByteArray(Charsets.UTF_8).size > LinkProtocol.MAX_CLIPBOARD_BYTES) {
            toast("That text is too long to send (256 KB max)")
            return
        }
        val c = client
        if (c == null || !c.isConnected) {
            waitForLink { sendClip(text, source) }
            return
        }
        val id = LinkMessages.newId()
        when (c.sendClip(text, id)) {
            LinkClient.ClipResult.SENT -> {
                _lastSent.value = ClipPreview(text, System.currentTimeMillis(), id = id)
                record(ClipEntry(id, text, toMac = true, atMillis = System.currentTimeMillis(), confirmed = false))
                if (!quiet) {
                    awaitingAck[id] = source
                    main.postDelayed({
                        if (awaitingAck.remove(id) != null) toast("Sent, but $macName didn't confirm")
                    }, ACK_TIMEOUT_MS)
                }
            }
            LinkClient.ClipResult.NOT_CONNECTED -> toast("Couldn't reach $macName")
            LinkClient.ClipResult.TOO_LARGE -> toast("That text is too long to send (256 KB max)")
            LinkClient.ClipResult.EMPTY -> Unit
        }
    }

    /** The service may be starting or reconnecting: run [send] once connected, or give up after a while. */
    private fun waitForLink(send: () -> Unit) {
        val pending = PendingClip(System.currentTimeMillis() + PENDING_MS, send)
        pendingClip = pending
        if (client == null && _pairing.value != null) LinkService.start(app)
        main.postDelayed({
            if (pendingClip === pending) {
                pendingClip = null
                toast("Couldn't reach $macName")
            }
        }, PENDING_MS + 50)
    }

    /**
     * Sends an image to the Mac through OpenScribe Cloud. The bytes are read from [uri] right away (the caller is
     * in the foreground, which Android requires), then [onRead] runs on the main thread so a transparent activity
     * can close. Encrypting, uploading and sending happen off the main thread.
     */
    fun sendImage(uri: Uri, source: ClipSource, onRead: () -> Unit = {}) {
        if (!checkImageReady()) {
            onRead()
            return
        }
        io.execute {
            val bytes = try {
                ImageClips.read(app, uri)
            } catch (e: Exception) {
                toast(e.message ?: "Couldn't read the image")
                null
            }
            main.post(onRead)
            if (bytes != null) uploadImage(bytes, app.contentResolver.getType(uri), source)
        }
    }

    /** Sends a Recent image again. */
    fun resendImage(file: File) {
        if (!checkImageReady()) return
        io.execute {
            val bytes = try { ImageClips.open(app, file) } catch (e: Exception) { null }
            if (bytes == null) toast("That image is no longer on this phone") else uploadImage(bytes, null, ClipSource.APP)
        }
    }

    private fun checkImageReady(): Boolean {
        if (_pairing.value == null) {
            toast("Open OpenScribe and pair with your Mac first")
            return false
        }
        if (activeCloud == null) {
            toast(CLOUD_NEEDED_MESSAGE, long = true)
            return false
        }
        if (client == null) LinkService.start(app)
        return true
    }

    /** On [io]: fit, save, seal, upload, then send the clip message over the link. */
    private fun uploadImage(original: ByteArray, typeHint: String?, source: ClipSource) {
        val macId = _pairing.value?.macId ?: return
        val config = _cloud.value[macId] ?: return toast(CLOUD_NEEDED_MESSAGE, long = true)
        val id = LinkMessages.newId()
        try {
            val sniffed = ImageClips.sniffMime(original) ?: typeHint?.takeIf { it.startsWith("image/") } ?: "image/png"
            val (bytes, mime) = ImageClips.fitForSending(original, sniffed)
            val file = ImageClips.save(app, macId, id, mime, bytes)
            main.post {
                if (_pairing.value?.macId == macId) {
                    record(ClipEntry(id, imageLabel(bytes.size), toMac = true, atMillis = System.currentTimeMillis(), confirmed = false, image = file))
                }
            }
            val key = BlobCipher.newKey()
            val blob = blobs.upload(config, BlobCipher.seal(key, bytes))
            main.post {
                if (_pairing.value?.macId != macId) return@post
                val send = send@{
                    val c = client ?: return@send toast("Couldn't reach $macName")
                    if (c.sendImageClip(id, mime, blob, key, bytes.size) == LinkClient.ClipResult.SENT) {
                        if (source != ClipSource.AUTO) {
                            awaitingAck[id] = source
                            main.postDelayed({
                                if (awaitingAck.remove(id) != null) toast("Sent, but $macName didn't confirm")
                            }, IMAGE_ACK_TIMEOUT_MS)
                        }
                    } else toast("Couldn't reach $macName")
                }
                if (isConnected) send() else waitForLink(send)
            }
        } catch (e: Exception) {
            android.util.Log.w("OpenScribe", "image upload failed", e)
            main.post { _clips.value = _clips.value.filterNot { it.id == id } }
            toast("Couldn't send the image: ${e.message ?: "unknown error"}")
        }
    }

    /** Puts a received or sent image back on this phone's clipboard. */
    fun copyImageToPhone(file: File) {
        try {
            app.getSystemService(ClipboardManager::class.java).setPrimaryClip(ImageClips.clipData(app, file))
            if (android.os.Build.VERSION.SDK_INT < 33) toast("Copied")
        } catch (e: Exception) {
            toast("Couldn't copy")
        }
    }

    /** Whether auto-send should skip [text] because it just came from, or already went to, the Mac. */
    fun isEcho(text: String): Boolean = text == _lastReceived.value?.text || text == _lastSent.value?.text

    /** Puts [text] on this phone's clipboard, labelled so the home screen knows the Mac already has it. */
    fun copyToPhone(text: String) {
        try {
            app.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(CLIP_LABEL, text))
            // Android 13+ shows its own confirmation.
            if (android.os.Build.VERSION.SDK_INT < 33) toast("Copied")
        } catch (e: Exception) {
            toast("Couldn't copy")
        }
    }

    fun toast(message: String, long: Boolean = false) {
        main.post { Toast.makeText(app, message, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show() }
    }

    // Talking

    private var lastTalkId: String? = null

    /**
     * Starts recording. When the Mac shared its speech settings, the phone transcribes while you talk and sends
     * the Mac text ([PhoneTalk]); otherwise, or if that fails, audio streams to the Mac. The caller has
     * RECORD_AUDIO. Returns false if it could not start.
     */
    fun startTalk(): Boolean {
        if (_talk.value is TalkUi.Recording) return true
        val c = client
        if (c == null || !c.isConnected) {
            _talk.value = TalkUi.Failed("Not connected to $macName")
            return false
        }
        val speech = _speech.value[c.pairing.macId]
        lateinit var talk: PhoneTalk
        talk = PhoneTalk(
            link = ClientTalkLink(c),
            transcriber = Transcribers.factory(speech, speechHttp),
            events = object : PhoneTalkEvents {
                override fun onHeard(text: String) = main.post { onHeard(talk, text) }.let {}
                override fun onSwitchedToAudio(newId: String) = main.post { onSwitchedToAudio(talk, newId) }.let {}
                override fun onLost() = main.post {
                    if (phoneTalk === talk && _talk.value !is TalkUi.Failed) _talk.value = TalkUi.Failed("Couldn't reach $macName")
                }.let {}
            },
            schedule = { delay, block -> main.postDelayed(block, delay) },
        )
        if (!talk.start()) {
            _talk.value = TalkUi.Failed("Not connected to $macName")
            return false
        }
        val rec = TalkRecorder(
            whisperBoost = prefs.whisperBoost,
            onFrame = { bytes, length -> talk.feed(bytes, 0, length) },
            onLevel = { _level.value = it },
            onError = { message ->
                main.post {
                    if (phoneTalk === talk && _talk.value is TalkUi.Recording) {
                        stopRecorder()
                        talk.cancel()
                        phoneTalk = null
                        _talk.value = TalkUi.Failed(message)
                    }
                }
            },
        )
        phoneTalk = talk
        lastTalkId = talk.id
        talkStartedAt = System.currentTimeMillis()
        _talk.value = TalkUi.Recording(talk.id, locked = false, startedAt = talkStartedAt, phoneTranscribes = talk.transcribing)
        if (!rec.start()) {
            talk.cancel()
            phoneTalk = null
            if (_talk.value is TalkUi.Recording) _talk.value = TalkUi.Failed("Microphone unavailable")
            return false
        }
        recorder = rec
        return true
    }

    /** Live text from the phone's transcription, for the talk dock. */
    private fun onHeard(talk: PhoneTalk, text: String) {
        if (phoneTalk !== talk) return
        val current = _talk.value
        if (current is TalkUi.Recording && current.id == talk.id) _talk.value = current.copy(heard = text)
    }

    /** Phone transcription failed; the talk carries on as audio to the Mac under a new id. Nothing to show. */
    private fun onSwitchedToAudio(talk: PhoneTalk, newId: String) {
        if (phoneTalk !== talk) return
        lastTalkId = newId
        _talk.value = when (val current = _talk.value) {
            is TalkUi.Recording -> current.copy(id = newId, heard = null, phoneTranscribes = false, macListening = false)
            is TalkUi.Transcribing -> current.copy(id = newId)
            else -> current
        }
    }

    fun lockTalk() {
        val t = _talk.value as? TalkUi.Recording ?: return
        _talk.value = t.copy(locked = true)
    }

    /** Released (or tapped while locked): send for transcription. Very short taps count as a cancel. */
    fun endTalk() {
        val t = _talk.value as? TalkUi.Recording ?: return
        val held = System.currentTimeMillis() - talkStartedAt
        stopRecorder()
        val talk = phoneTalk
        if (held < MIN_TALK_MS) {
            // A brief press that slid off the button: nothing was said, so just drop it.
            talk?.cancel()
            phoneTalk = null
            _talk.value = TalkUi.Idle
            return
        }
        talk?.end()
        _talk.value = TalkUi.Transcribing(talk?.id ?: t.id, t.target, t.pasted)
    }

    fun cancelTalk() {
        if (_talk.value !is TalkUi.Recording) return
        stopRecorder()
        phoneTalk?.cancel()
        phoneTalk = null
        _talk.value = TalkUi.Idle
    }

    /** [PhoneTalk]'s view of the link. */
    private class ClientTalkLink(private val c: LinkClient) : TalkLink {
        override fun talkStart(textMode: Boolean) = c.talkStart(textMode)
        override fun sendAudio(pcm: ByteArray, offset: Int, length: Int) = c.sendAudio(pcm, offset, length)
        override fun talkPartial(id: String, text: String) = c.talkPartial(id, text)
        override fun talkText(id: String, text: String) = c.talkText(id, text)
        override fun talkEnd(id: String) = c.talkEnd(id)
        override fun talkCancel(id: String) = c.talkCancel(id)
    }

    // Hardware talk button (TalkKeyService), usable from any app.

    private var hardwarePressAt = 0L

    /** The talk button went down: start talking, or send if a hands-free dictation is running. */
    fun hardwareTalkDown() {
        val current = _talk.value
        if (current is TalkUi.Recording) {
            hardwarePressAt = 0L
            endTalk()
            buzz(Buzz.SEND)
            return
        }
        if (androidx.core.content.ContextCompat.checkSelfPermission(app, android.Manifest.permission.RECORD_AUDIO) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            toast("Open OpenScribe and allow the microphone to talk with the button")
            return
        }
        hardwarePressAt = System.currentTimeMillis()
        if (startTalk()) buzz(Buzz.START) else buzz(Buzz.ERROR)
    }

    /** The talk button came up: a tap switches to hands-free (press again to send); a hold sends. */
    fun hardwareTalkUp() {
        val pressedAt = hardwarePressAt
        if (pressedAt == 0L) return
        hardwarePressAt = 0L
        if (_talk.value !is TalkUi.Recording) return
        if (System.currentTimeMillis() - pressedAt < TAP_MS) {
            lockTalk()
            buzz(Buzz.LOCK)
        } else {
            endTalk()
            buzz(Buzz.SEND)
        }
    }

    private enum class Buzz { START, LOCK, SEND, DONE, ERROR }

    /** Vibration feedback for talking without looking at the screen. */
    private fun buzz(kind: Buzz) {
        if (!prefs.haptics) return
        val vibrator = (
            if (android.os.Build.VERSION.SDK_INT >= 31) app.getSystemService(android.os.VibratorManager::class.java)?.defaultVibrator
            else @Suppress("DEPRECATION") app.getSystemService(android.os.Vibrator::class.java)
            ) ?: return
        val effect = when (kind) {
            Buzz.START -> android.os.VibrationEffect.EFFECT_CLICK
            Buzz.LOCK -> android.os.VibrationEffect.EFFECT_DOUBLE_CLICK
            Buzz.SEND -> android.os.VibrationEffect.EFFECT_HEAVY_CLICK
            Buzz.DONE -> android.os.VibrationEffect.EFFECT_TICK
            Buzz.ERROR -> android.os.VibrationEffect.EFFECT_DOUBLE_CLICK
        }
        try { vibrator.vibrate(android.os.VibrationEffect.createPredefined(effect)) } catch (_: Exception) {}
    }

    fun clearTalkResult() {
        if (_talk.value !is TalkUi.Recording && _talk.value !is TalkUi.Transcribing) _talk.value = TalkUi.Idle
    }

    private fun stopRecorder() {
        recorder?.stop()
        recorder = null
        _level.value = 0f
    }

    private const val PENDING_MS = 10_000L
    private const val ACK_TIMEOUT_MS = 5_000L
    /** The Mac downloads the image before it acks. */
    private const val IMAGE_ACK_TIMEOUT_MS = 30_000L
    private const val MIN_TALK_MS = 300L
    private const val MAX_CLIPS = 8
    private const val TAP_MS = 280L
}
