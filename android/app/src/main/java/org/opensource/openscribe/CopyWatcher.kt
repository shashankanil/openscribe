package org.opensource.openscribe

import android.accessibilityservice.AccessibilityService
import android.content.ClipDescription
import android.content.ClipboardManager
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/**
 * Sends what you copy on the phone to the Mac, automatically.
 *
 * Android 10+ lets only the focused app (or the keyboard) read the clipboard, and doesn't tell background apps it
 * changed. So the talk-button accessibility service watches for the moment of a copy: a tap on a button labelled
 * "Copy", Ctrl+C, or the system's "copied" preview appearing. It sees only those event labels, never screen content
 * (`canRetrieveWindowContent` is off). It then shows an invisible 1-pixel window of its own for an instant, which
 * gives OpenScribe focus long enough to read the clipboard, sends it over the encrypted link, and removes the window.
 */
class CopyWatcher(private val service: AccessibilityService) {
    private val main = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null
    private var overlay: View? = null
    private var lastSentSignature: Int? = null

    /** Called for every accessibility event the service receives. */
    fun onEvent(event: AccessibilityEvent) {
        if (looksLikeCopy(event.eventType, event.packageName, event.className, event.text, event.contentDescription)) schedule()
    }

    /** Called for every key event; never consumes it. */
    fun onKey(event: KeyEvent) {
        if (event.action == KeyEvent.ACTION_UP && event.keyCode == KeyEvent.KEYCODE_C && event.isCtrlPressed) schedule()
        if (event.action == KeyEvent.ACTION_UP && event.keyCode == KeyEvent.KEYCODE_COPY) schedule()
    }

    private fun enabled() = LinkHub.prefs.autoSendPhoneCopies && LinkHub.isConnected && !LinkHub.uiVisible.value

    /** Waits a moment so the app has finished writing the clip, and collapses bursts of events into one read. */
    private fun schedule() {
        if (!enabled()) return
        pending?.let(main::removeCallbacks)
        val run = Runnable { readThroughOverlay() }
        pending = run
        main.postDelayed(run, 250)
    }

    private fun readThroughOverlay() {
        pending = null
        if (overlay != null || !enabled()) return
        val windows = service.getSystemService(WindowManager::class.java)
        val view = View(service)
        val params = WindowManager.LayoutParams(
            1, 1,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            // Focusable (so Android lets us read the clipboard) but lets every touch through to the app below.
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSPARENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }
        var done = false
        fun finish() {
            if (done) return
            done = true
            try { windows.removeView(view) } catch (_: Exception) {}
            overlay = null
        }
        view.viewTreeObserver.addOnWindowFocusChangeListener(object : ViewTreeObserver.OnWindowFocusChangeListener {
            override fun onWindowFocusChanged(hasFocus: Boolean) {
                if (!hasFocus) return
                view.viewTreeObserver.removeOnWindowFocusChangeListener(this)
                readAndSend()
                finish()
            }
        })
        try {
            windows.addView(view, params)
            overlay = view
        } catch (e: Exception) {
            android.util.Log.w("OpenScribe", "copy overlay unavailable", e)
            return
        }
        // Never linger, even if focus doesn't arrive (another window may hold it).
        main.postDelayed({ finish() }, 800)
    }

    private fun readAndSend() {
        val clipboard = service.getSystemService(ClipboardManager::class.java)
        val clip = try { clipboard.primaryClip } catch (_: SecurityException) { null } ?: return
        if (clip.itemCount == 0) return
        val description = clip.description
        val decision = decide(description.label?.toString(), isSensitive(description), clip.getItemAt(0).uri != null,
            description.hasMimeType("image/*"))
        val item = clip.getItemAt(0)
        when (decision) {
            Decision.SKIP -> return
            Decision.IMAGE -> {
                val uri = item.uri ?: return
                val signature = uri.hashCode()
                if (signature == lastSentSignature) return
                lastSentSignature = signature
                LinkHub.sendImage(uri, ClipSource.AUTO)
            }
            Decision.TEXT -> {
                val text = item.coerceToText(service)?.toString().orEmpty()
                if (text.isBlank() || LinkHub.isEcho(text) || text.hashCode() == lastSentSignature) return
                lastSentSignature = text.hashCode()
                LinkHub.sendClip(text, ClipSource.AUTO)
            }
        }
    }

    fun release() {
        pending?.let(main::removeCallbacks)
        overlay?.let { try { service.getSystemService(WindowManager::class.java).removeView(it) } catch (_: Exception) {} }
        overlay = null
    }

    enum class Decision { SKIP, TEXT, IMAGE }

    companion object {
        private val copyLabel = Regex(
            "^(copy|copy text|copy link|copy link address|copy to clipboard|copy address|copy code|copy message|copy all|" +
                "kopieren|copier|copiar|copia|copiare|kopiëren|kopiuj|копировать|コピー|复制|複製|복사|कॉपी करें)$",
            RegexOption.IGNORE_CASE,
        )

        /** True for the events that accompany a copy. Pure, so it's unit-tested. */
        fun looksLikeCopy(type: Int, packageName: CharSequence?, className: CharSequence?, text: List<CharSequence>,
                          contentDescription: CharSequence?): Boolean {
            val labels = (text + listOfNotNull(contentDescription)).map { it.toString().trim() }
            return when (type) {
                AccessibilityEvent.TYPE_VIEW_CLICKED -> labels.any { copyLabel.matches(it) }
                // The system's clipboard preview (Android 13+) or a "Copied" toast.
                AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED ->
                    (packageName?.toString() == "com.android.systemui" && className?.toString()?.contains("clipboard", ignoreCase = true) == true) ||
                        labels.any { it.contains("copied", ignoreCase = true) && it.length < 60 }
                else -> false
            }
        }

        /** What to do with the clip: never re-send what came from the Mac, and never send clips marked sensitive. */
        fun decide(label: String?, sensitive: Boolean, hasUri: Boolean, isImage: Boolean): Decision = when {
            label == CLIP_LABEL || sensitive -> Decision.SKIP
            isImage && hasUri -> Decision.IMAGE
            else -> Decision.TEXT
        }

        /** Password managers mark copies sensitive (Android 13+ standard extra, plus the older vendor key). */
        fun isSensitive(description: ClipDescription): Boolean {
            val extras: PersistableBundle = description.extras ?: return false
            return (Build.VERSION.SDK_INT >= 33 && extras.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE)) ||
                extras.getBoolean("android.content.extra.IS_SENSITIVE")
        }
    }
}
