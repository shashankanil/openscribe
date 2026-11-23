package org.opensource.openscribe

import android.view.accessibility.AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED
import android.view.accessibility.AccessibilityEvent.TYPE_VIEW_CLICKED
import android.view.accessibility.AccessibilityEvent.TYPE_VIEW_SCROLLED
import android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CopyWatcherTest {
    private fun copy(type: Int, text: List<String> = emptyList(), pkg: String? = "com.example", cls: String? = null, desc: String? = null) =
        CopyWatcher.looksLikeCopy(type, pkg, cls, text, desc)

    @Test fun copyButtonsAndMenusCount() {
        assertTrue(copy(TYPE_VIEW_CLICKED, listOf("Copy")))
        assertTrue(copy(TYPE_VIEW_CLICKED, desc = "Copy link"))
        assertTrue(copy(TYPE_VIEW_CLICKED, listOf("Kopieren")))
        assertFalse(copy(TYPE_VIEW_CLICKED, listOf("Copy of report.pdf")), "A file name that starts with Copy isn't a copy action")
        assertFalse(copy(TYPE_VIEW_CLICKED, listOf("Send")))
    }

    @Test fun systemCopiedPreviewAndToastsCount() {
        assertTrue(copy(TYPE_WINDOW_STATE_CHANGED, pkg = "com.android.systemui", cls = "com.android.systemui.clipboardoverlay.ClipboardOverlayView"))
        assertTrue(copy(TYPE_NOTIFICATION_STATE_CHANGED, listOf("Copied to clipboard")))
        assertFalse(copy(TYPE_WINDOW_STATE_CHANGED, pkg = "com.android.systemui", cls = "android.widget.FrameLayout"))
        assertFalse(copy(TYPE_VIEW_SCROLLED, listOf("Copy")))
    }

    @Test fun macCopiesAndSensitiveClipsAreNeverSent() {
        assertEquals(CopyWatcher.Decision.SKIP, CopyWatcher.decide(CLIP_LABEL, sensitive = false, hasUri = false, isImage = false))
        assertEquals(CopyWatcher.Decision.SKIP, CopyWatcher.decide("Password", sensitive = true, hasUri = false, isImage = false))
        assertEquals(CopyWatcher.Decision.TEXT, CopyWatcher.decide(null, sensitive = false, hasUri = false, isImage = false))
        assertEquals(CopyWatcher.Decision.IMAGE, CopyWatcher.decide("Image", sensitive = false, hasUri = true, isImage = true))
    }

    private fun assertFalse(value: Boolean, message: String) = org.junit.Assert.assertFalse(message, value)
}
