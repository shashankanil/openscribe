package org.opensource.openscribe.ui

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.core.content.IntentCompat
import org.opensource.openscribe.ClipSource
import org.opensource.openscribe.LinkHub
import org.opensource.openscribe.LinkService

private fun Activity.noAnimationFinish() {
    finish()
    if (Build.VERSION.SDK_INT >= 34) {
        overrideActivityTransition(Activity.OVERRIDE_TRANSITION_CLOSE, 0, 0)
    } else {
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}

/** Share → OpenScribe: sends shared text or an image to the Mac's clipboard. */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LinkHub.init(this)
        val send = intent?.takeIf { it.action == Intent.ACTION_SEND }
        val image = send?.takeIf { it.type?.startsWith("image/") == true }?.let(::sharedImage)
        val text = send?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty()
        when {
            LinkHub.pairing.value == null -> LinkHub.toast("Open OpenScribe and pair with your Mac first")
            image != null -> {
                LinkService.start(this)
                // The share grant lasts while this activity is open, so read the image before closing.
                LinkHub.sendImage(image, ClipSource.SHARE, onRead = { noAnimationFinish() })
                return
            }
            text.isEmpty() -> LinkHub.toast("Nothing to send")
            else -> {
                LinkService.start(this)
                LinkHub.sendClip(text, ClipSource.SHARE)
            }
        }
        noAnimationFinish()
    }

    private fun sharedImage(intent: Intent): Uri? =
        IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
            ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
}

/**
 * Opened by the Send clipboard tile and notification action. Transparent and animation-free: it reads the
 * clipboard as soon as it has window focus (the only moment Android allows it), hands the text over, and leaves.
 */
class SendClipActivity : Activity() {
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LinkHub.init(this)
        if (LinkHub.pairing.value == null) {
            LinkHub.toast("Open OpenScribe and pair with your Mac first")
            done = true
            noAnimationFinish()
        } else {
            LinkService.start(this)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val image = readClipboardImage(this)
        if (image != null) {
            // Read the image while this activity has focus, then close.
            LinkHub.sendImage(image, ClipSource.TILE, onRead = { noAnimationFinish() })
            return
        }
        val text = readClipboard(this)
        if (text.isEmpty()) LinkHub.toast("The clipboard is empty") else LinkHub.sendClip(text, ClipSource.TILE)
        noAnimationFinish()
    }
}

/** Quick Settings tile: Send clipboard to the Mac. */
class ClipTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        LinkHub.init(this)
        qsTile?.apply {
            state = if (LinkHub.pairing.value != null) Tile.STATE_INACTIVE else Tile.STATE_UNAVAILABLE
            subtitle = LinkHub.pairing.value?.let { "to ${LinkHub.macName}" }
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val launch = {
            val intent = Intent(this, SendClipActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
            } else {
                @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
                startActivityAndCollapse(intent)
            }
        }
        if (isLocked) unlockAndRun { launch() } else launch()
    }
}
