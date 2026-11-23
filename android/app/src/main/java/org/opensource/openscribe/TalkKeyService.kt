package org.opensource.openscribe

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/** A hardware button chosen as the talk button. Some buttons (like Nothing's Essential Key) have no key code, only a scan code. */
data class TalkKey(val keyCode: Int, val scanCode: Int) {
    fun matches(event: KeyEvent): Boolean =
        if (keyCode == KeyEvent.KEYCODE_UNKNOWN) event.keyCode == KeyEvent.KEYCODE_UNKNOWN && event.scanCode == scanCode
        else event.keyCode == keyCode

    val name: String
        get() = when {
            keyCode == KeyEvent.KEYCODE_VOLUME_DOWN -> "Volume down"
            keyCode == KeyEvent.KEYCODE_VOLUME_UP -> "Volume up"
            scanCode == ESSENTIAL_KEY_SCAN_CODE -> "Essential Key"
            keyCode == KeyEvent.KEYCODE_UNKNOWN -> "Button $scanCode"
            else -> KeyEvent.keyCodeToString(keyCode).removePrefix("KEYCODE_").lowercase().replace('_', ' ')
                .replaceFirstChar { it.uppercase() }
        }

    companion object {
        /** Nothing Phone (3)'s Essential Key reports this scan code (`gpio-keys`, 0xfa). */
        const val ESSENTIAL_KEY_SCAN_CODE = 250
    }
}

/**
 * Turns the chosen hardware button into the talk button, in any app, while the screen is on: hold to talk and
 * release to send, or tap for hands-free and press again to send. It only looks at key presses; it can't read
 * the screen. Other buttons, and the chosen one while the Mac isn't connected, pass through untouched.
 */
class TalkKeyService : AccessibilityService() {
    /** Whether we took the last key down, so we also take its key up. */
    private var holding = false
    private var copies: CopyWatcher? = null

    override fun onServiceConnected() {
        LinkHub.init(this)
        copies = CopyWatcher(this)
        LinkHub.talkKeyServiceOn.value = true
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        LinkHub.talkKeyServiceOn.value = false
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        copies?.release()
        copies = null
        LinkHub.talkKeyServiceOn.value = false
        super.onDestroy()
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        copies?.onKey(event)
        // Choosing a button in Settings: report it, and keep it from doing anything else meanwhile.
        LinkHub.keyLearner?.let { learn ->
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) learn(TalkKey(event.keyCode, event.scanCode))
            return true
        }
        val key = LinkHub.prefs.talkKey ?: return false
        if (!key.matches(event)) return false
        when (event.action) {
            KeyEvent.ACTION_DOWN -> {
                if (event.repeatCount > 0) return holding
                if (!LinkHub.isConnected && LinkHub.talk.value !is TalkUi.Recording) return false // volume works as usual
                holding = true
                LinkHub.hardwareTalkDown()
                return true
            }
            KeyEvent.ACTION_UP -> {
                if (!holding) return false
                holding = false
                LinkHub.hardwareTalkUp()
                return true
            }
        }
        return holding
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event?.let { copies?.onEvent(it) }
    }
    override fun onInterrupt() {}
}
