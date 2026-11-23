package org.opensource.openscribe.ui

import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.opensource.openscribe.ClipSource
import org.opensource.openscribe.LinkHub
import org.opensource.openscribe.LinkService
import org.opensource.openscribe.link.PairingLink

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LinkHub.init(this)
        enableEdgeToEdge()
        handleDeepLink(intent)
        setContent {
            OpenScribeTheme {
                val pairing by LinkHub.pairing.collectAsStateWithLifecycle()
                var showSettings by rememberSaveable { mutableStateOf(false) }
                var addingMac by rememberSaveable { mutableStateOf(false) }
                when {
                    pairing == null -> PairingScreen(onPaired = { LinkHub.pair(it) })
                    addingMac -> {
                        BackHandler { addingMac = false }
                        PairingScreen(onPaired = { LinkHub.pair(it); addingMac = false }, onCancel = { addingMac = false })
                    }
                    showSettings -> {
                        BackHandler { showSettings = false }
                        SettingsScreen(onBack = { showSettings = false })
                    }
                    else -> HomeScreen(onOpenSettings = { showSettings = true }, onAddMac = { addingMac = true })
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    override fun onStart() {
        super.onStart()
        LinkHub.uiVisible.value = true
        LinkService.start(this)
    }

    override fun onStop() {
        LinkHub.uiVisible.value = false
        super.onStop()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Android only lets the focused foreground app read the clipboard, so auto-send happens here.
        if (!hasFocus || LinkHub.pairing.value == null || !LinkHub.prefs.autoSendOnOpen) return
        val clip = getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 } ?: return
        // Text OpenScribe put there came from a Mac; sending it on would echo it, or leak it to another Mac.
        if (clip.description.label == org.opensource.openscribe.CLIP_LABEL) return
        // Images are sent only on request: they go through OpenScribe Cloud.
        if (!clip.description.hasMimeType("text/*")) return
        val text = clip.getItemAt(0)?.coerceToText(this)?.toString().orEmpty()
        if (text.isNotEmpty() && !LinkHub.isEcho(text)) LinkHub.sendClip(text, ClipSource.AUTO)
    }

    private fun handleDeepLink(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "openscribe") return
        val link = PairingLink.parse(data.toString())
        if (link == null) {
            LinkHub.toast("That pairing link isn't valid. Make a new one on your Mac.")
        } else {
            LinkHub.pair(link)
            LinkHub.toast("Paired with ${link.macName}")
        }
        setIntent(Intent(intent).setData(null))
    }
}
