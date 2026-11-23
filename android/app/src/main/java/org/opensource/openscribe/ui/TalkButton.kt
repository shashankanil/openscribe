package org.opensource.openscribe.ui

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import org.opensource.openscribe.R
import kotlin.math.abs
import kotlin.math.roundToInt

enum class Haptic { PRESS, RELEASE, LOCK, CANCEL }

fun View.haptic(kind: Haptic, enabled: Boolean) {
    if (!enabled) return
    val constant = when (kind) {
        Haptic.PRESS -> HapticFeedbackConstants.VIRTUAL_KEY
        Haptic.RELEASE -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.KEYBOARD_TAP
        Haptic.LOCK -> HapticFeedbackConstants.LONG_PRESS
        Haptic.CANCEL -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
    }
    performHapticFeedback(constant)
}

enum class TalkMode { DISABLED, IDLE, HOLDING, LOCKED, BUSY }

/** A press shorter than this, without sliding, is a tap: it starts hands-free instead of failing. */
private const val TAP_MS = 280L

/**
 * The talk control. Hold to talk and release to send, or tap to talk hands-free and tap ➤ to send.
 * While holding, the button follows the finger: slide up to lock hands-free, slide left to cancel.
 */
@Composable
fun TalkPad(
    mode: TalkMode,
    level: Float,
    haptics: Boolean,
    onPress: () -> Boolean,
    onRelease: () -> Unit,
    onLock: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val view = LocalView.current
    val density = LocalDensity.current
    val touchSlop = LocalViewConfiguration.current.touchSlop
    val lockPx = with(density) { 84.dp.toPx() }
    val cancelPx = with(density) { 104.dp.toPx() }
    val currentMode by rememberUpdatedState(mode)
    val press by rememberUpdatedState(onPress)
    val release by rememberUpdatedState(onRelease)
    val lock by rememberUpdatedState(onLock)
    val cancel by rememberUpdatedState(onCancel)
    val hapticsOn by rememberUpdatedState(haptics)
    var dragX by remember { mutableFloatStateOf(0f) }
    var dragY by remember { mutableFloatStateOf(0f) }
    var pressed by remember { mutableStateOf(false) }

    val recording = mode == TalkMode.HOLDING || mode == TalkMode.LOCKED
    val ring by animateFloatAsState(if (recording) level else 0f, tween(90), label = "level")
    val scale by animateFloatAsState(
        when {
            mode == TalkMode.HOLDING -> 1.12f
            pressed -> 0.94f
            else -> 1f
        },
        spring(dampingRatio = 0.55f), label = "scale",
    )
    val follow by animateFloatAsState(if (mode == TalkMode.HOLDING) 1f else 0f, label = "follow")
    val colors = MaterialTheme.colorScheme
    val buttonColor = when (mode) {
        TalkMode.DISABLED -> colors.surfaceVariant
        TalkMode.BUSY -> colors.secondaryContainer
        TalkMode.HOLDING, TalkMode.LOCKED -> colors.error
        TalkMode.IDLE -> colors.primary
    }
    val contentColor = when (mode) {
        TalkMode.DISABLED -> colors.onSurfaceVariant
        TalkMode.BUSY -> colors.onSecondaryContainer
        TalkMode.HOLDING, TalkMode.LOCKED -> colors.onError
        TalkMode.IDLE -> colors.onPrimary
    }
    val lockProgress = (-dragY / lockPx).coerceIn(0f, 1f)
    val cancelProgress = (-dragX / cancelPx).coerceIn(0f, 1f)

    // Compact at rest; grows while holding to make room for the lock target above the button.
    val height by animateDpAsState(if (mode == TalkMode.HOLDING) 232.dp else 172.dp, label = "height")
    Box(modifier.fillMaxWidth().height(height)) {
        // Slide up to lock: a pill above the button that fills as the finger approaches.
        AnimatedVisibility(
            visible = mode == TalkMode.HOLDING,
            enter = fadeIn() + scaleIn(initialScale = 0.6f),
            exit = fadeOut() + scaleOut(targetScale = 0.6f),
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 4.dp),
        ) {
            Column(
                Modifier.offset { IntOffset(0, (lockProgress * -10).roundToInt()) }
                    .clip(RoundedCornerShape(24.dp))
                    .background(colors.surfaceContainerHighest.copy(alpha = 0.7f + 0.3f * lockProgress))
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(
                    Icons.Filled.Lock, null, Modifier.size(20.dp),
                    tint = if (lockProgress > 0.95f) colors.primary else colors.onSurfaceVariant,
                )
                Icon(painterResource(R.drawable.ic_arrow_up), null, Modifier.size(14.dp).alpha(0.6f), tint = colors.onSurfaceVariant)
            }
        }

    Box(Modifier.fillMaxWidth().height(172.dp).align(Alignment.BottomCenter), contentAlignment = Alignment.Center) {
        // Live level rings.
        Canvas(Modifier.size(172.dp)) {
            val base = 64.dp.toPx()
            val color = if (recording) colors.error else colors.primary
            if (recording) {
                drawCircle(color.copy(alpha = 0.10f + 0.20f * ring), radius = base + 10.dp.toPx() + ring * 46.dp.toPx())
            }
            drawCircle(
                color.copy(alpha = if (recording) 0.5f else if (mode == TalkMode.IDLE) 0.22f else 0.08f),
                radius = base + 8.dp.toPx() + ring * 24.dp.toPx(),
                style = Stroke(width = 2.dp.toPx() + ring * 4.dp.toPx()),
            )
        }

        // Slide left to cancel.
        AnimatedVisibility(
            visible = mode == TalkMode.HOLDING,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.CenterStart).padding(start = 8.dp),
        ) {
            Row(
                Modifier.offset { IntOffset((dragX * 0.35f).roundToInt(), 0) }.alpha(1f - 0.4f * lockProgress),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.KeyboardArrowLeft, null, tint = if (cancelProgress > 0.6f) colors.error else colors.onSurfaceVariant)
                Text(
                    "Cancel",
                    style = MaterialTheme.typography.labelLarge,
                    color = if (cancelProgress > 0.6f) colors.error else colors.onSurfaceVariant,
                )
            }
        }

        // Hands-free: an explicit cancel next to the send button.
        AnimatedVisibility(
            visible = mode == TalkMode.LOCKED,
            enter = fadeIn() + scaleIn(),
            exit = fadeOut() + scaleOut(),
            modifier = Modifier.align(Alignment.Center).offset(x = (-118).dp),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                FilledTonalIconButton(
                    onClick = { view.haptic(Haptic.CANCEL, hapticsOn); cancel() },
                    modifier = Modifier.size(56.dp),
                    colors = IconButtonDefaults.filledTonalIconButtonColors(),
                ) { Icon(Icons.Filled.Close, "Cancel") }
                Spacer(Modifier.height(4.dp))
                Text("Cancel", style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
            }
        }

        Box(
            Modifier
                .offset {
                    IntOffset(
                        (dragX.coerceAtMost(0f) * 0.5f * follow).roundToInt(),
                        (dragY.coerceAtMost(0f) * 0.5f * follow).roundToInt(),
                    )
                }
                .size(128.dp).scale(scale).clip(CircleShape).background(buttonColor)
                .semantics {
                    role = Role.Button
                    contentDescription = when (mode) {
                        TalkMode.LOCKED -> "Send to Mac"
                        TalkMode.HOLDING -> "Recording. Release to send"
                        TalkMode.BUSY -> "Transcribing on the Mac"
                        TalkMode.DISABLED -> "Talk, unavailable until connected"
                        TalkMode.IDLE -> "Talk. Hold to talk, or double tap for hands-free"
                    }
                    // Accessibility services tap; a tap starts hands-free, and a tap while hands-free sends.
                    onClick {
                        when (currentMode) {
                            TalkMode.IDLE -> if (press()) lock()
                            TalkMode.LOCKED, TalkMode.HOLDING -> release()
                            else -> Unit
                        }
                        true
                    }
                }
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        val startMode = currentMode
                        if (startMode == TalkMode.DISABLED || startMode == TalkMode.BUSY) {
                            waitForUpOrCancellation()
                            return@awaitEachGesture
                        }
                        if (startMode == TalkMode.LOCKED || startMode == TalkMode.HOLDING) {
                            pressed = true
                            val up = waitForUpOrCancellation()
                            pressed = false
                            if (up != null) {
                                view.haptic(Haptic.RELEASE, hapticsOn)
                                release()
                            }
                            return@awaitEachGesture
                        }
                        // Start right away so the first syllable isn't lost; decide hold or tap on release.
                        view.haptic(Haptic.PRESS, hapticsOn)
                        if (!press()) {
                            waitForUpOrCancellation()
                            return@awaitEachGesture
                        }
                        down.consume()
                        val downAt = down.uptimeMillis
                        var moved = false
                        var outcome = 0 // 0 release, 1 lock, 2 cancel, 3 tap
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            val delta = change.position - down.position
                            if (abs(delta.x) > touchSlop || abs(delta.y) > touchSlop) moved = true
                            if (!change.pressed) {
                                change.consume()
                                if (!moved && change.uptimeMillis - downAt < TAP_MS) outcome = 3
                                break
                            }
                            dragX = delta.x
                            dragY = delta.y
                            change.consume()
                            if (delta.y < -lockPx) { outcome = 1; break }
                            if (delta.x < -cancelPx) { outcome = 2; break }
                        }
                        dragX = 0f
                        dragY = 0f
                        when (outcome) {
                            1, 3 -> { view.haptic(Haptic.LOCK, hapticsOn); lock() }
                            2 -> { view.haptic(Haptic.CANCEL, hapticsOn); cancel() }
                            else -> { view.haptic(Haptic.RELEASE, hapticsOn); release() }
                        }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            when (mode) {
                TalkMode.LOCKED -> Icon(Icons.AutoMirrored.Filled.Send, null, Modifier.size(46.dp).offset(x = 3.dp), tint = contentColor)
                TalkMode.BUSY -> CircularProgressIndicator(Modifier.size(44.dp), color = contentColor, strokeWidth = 3.dp)
                else -> Icon(painterResource(R.drawable.ic_mic), null, Modifier.size(52.dp), tint = contentColor)
            }
        }
    }
    }
}
