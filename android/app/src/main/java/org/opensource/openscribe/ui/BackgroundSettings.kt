package org.opensource.openscribe.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.background
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import org.opensource.openscribe.LinkHub
import org.opensource.openscribe.R
import org.opensource.openscribe.TalkKey

fun Context.ignoresBatteryOptimizations(): Boolean =
    getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

/** Asks Android to leave OpenScribe out of battery optimization, so the link survives the screen being off. */
@SuppressLint("BatteryLife") // Keeping a device link alive is the documented acceptable use.
fun Context.requestBackgroundAllowance() {
    try {
        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
    } catch (_: Exception) {
        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }
}

/** Settings → Talk button: hold a hardware button to talk from any app. */
@Composable
fun TalkButtonCard() {
    val context = LocalContext.current
    val serviceOn by LinkHub.talkKeyServiceOn.collectAsStateWithLifecycle()
    var key by remember { mutableStateOf(LinkHub.prefs.talkKey) }
    var choosing by remember { mutableStateOf(false) }

    Card(Modifier.fillMaxWidth(), border = flowBorder(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(painterResource(R.drawable.ic_mic), null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("Talk button", style = MaterialTheme.typography.titleMedium)
                    Text(
                        when {
                            key != null && serviceOn -> "Hold ${key!!.name} to talk, from any app"
                            key != null -> "${key!!.name}, waiting for access below"
                            else -> "Talk without opening the app"
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Text(
                "Hold the button to talk and let go to send. Tap it once to keep talking hands-free, then press it again to send. " +
                    "Works with the screen on, in any app. When the Mac isn't connected, the button does its usual job.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!serviceOn) {
                HorizontalDivider()
                Text("Step 1 · Allow OpenScribe to notice the button", style = MaterialTheme.typography.labelLarge)
                Text(
                    "Android needs Accessibility access for an app to see a button press while you're in another app. " +
                        "OpenScribe only watches the button you pick. It can't read your screen.\n\n" +
                        "In the list, open “Downloaded apps” (or “Installed apps”) → OpenScribe → turn it on.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                FilledTonalButton(onClick = {
                    context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }) { Text("Open Accessibility settings") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { choosing = true }, enabled = serviceOn) {
                    Text(if (key == null) (if (serviceOn) "Choose a button" else "Step 2 · Choose a button") else "Change button")
                }
                if (key != null) {
                    TextButton(onClick = {
                        LinkHub.prefs.talkKey = null
                        LinkHub.talkKeyChanged.value++
                        key = null
                    }) { Text("Turn off") }
                }
            }
        }
    }

    if (choosing) {
        ChooseKeyDialog(
            onChosen = {
                LinkHub.prefs.talkKey = it
                LinkHub.talkKeyChanged.value++
                key = it
                choosing = false
            },
            onDismiss = { choosing = false },
        )
    }
}

/** Settings → Copies to your Mac: send what's copied on the phone automatically, through the accessibility service. */
@Composable
fun PhoneCopiesCard() {
    val context = LocalContext.current
    val serviceOn by LinkHub.talkKeyServiceOn.collectAsStateWithLifecycle()
    var enabled by remember { mutableStateOf(LinkHub.prefs.autoSendPhoneCopies) }
    Card(Modifier.fillMaxWidth(), border = flowBorder(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(painterResource(R.drawable.ic_arrow_up), null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("Phone copies go to your Mac", style = MaterialTheme.typography.titleMedium)
                    Text(
                        when {
                            enabled && serviceOn -> "On. Copy anything and paste it on your Mac."
                            enabled -> "Needs access below"
                            else -> "Off. Use Send, Share or the tile instead."
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                androidx.compose.material3.Switch(checked = enabled, onCheckedChange = {
                    enabled = it
                    LinkHub.prefs.autoSendPhoneCopies = it
                })
            }
            Text(
                "Android only lets the app on screen read the clipboard. With this on, OpenScribe notices the moment you copy " +
                    "(like a tap on Copy) and reads it for an instant, then sends it over the encrypted link. Passwords and " +
                    "other copies marked sensitive are never sent.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (enabled && !serviceOn) {
                Text(
                    "Turn on OpenScribe in Accessibility: open “Downloaded apps” (or “Installed apps”) → OpenScribe → On. " +
                        "The same switch powers the talk button.",
                    style = MaterialTheme.typography.bodySmall,
                )
                FilledTonalButton(onClick = {
                    context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }) { Text("Open Accessibility settings") }
            }
        }
    }
}

/** Waits for a button press and offers it as the talk button. */
@Composable
private fun ChooseKeyDialog(onChosen: (TalkKey) -> Unit, onDismiss: () -> Unit) {
    var pressed by remember { mutableStateOf<TalkKey?>(null) }
    var waitedLong by remember { mutableStateOf(false) }
    DisposableEffect(Unit) {
        LinkHub.keyLearner = { key -> android.os.Handler(android.os.Looper.getMainLooper()).post { pressed = key } }
        onDispose { LinkHub.keyLearner = null }
    }
    LaunchedEffect(pressed) {
        if (pressed == null) {
            delay(8_000)
            waitedLong = true
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(painterResource(R.drawable.ic_mic), null) },
        title = { Text(if (pressed == null) "Press the button you want to use" else "Use ${pressed!!.name}?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (pressed == null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(12.dp))
                        Text("Waiting for a press… Volume down works well, or try the Essential Key.")
                    }
                    if (waitedLong) {
                        Text(
                            "Nothing yet. Some buttons, like the power button or a key the system has reserved, can't be used by apps. " +
                                "Try a volume button instead.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Got it: ${pressed!!.name}", style = MaterialTheme.typography.titleMedium)
                    }
                    Text(
                        "While the Mac is connected, holding it talks instead of doing its usual job. Press another button to pick that one instead.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = { pressed?.let(onChosen) }, enabled = pressed != null) { Text("Use this button") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Settings → Always on: what keeps the link alive while the app is closed. */
@Composable
fun BackgroundCard() {
    val context = LocalContext.current
    var allowed by remember { mutableStateOf(context.ignoresBatteryOptimizations()) }
    LifecycleResumeEffect(Unit) {
        allowed = context.ignoresBatteryOptimizations()
        onPauseOrDispose {}
    }
    Card(Modifier.fillMaxWidth(), border = flowBorder(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Always on", style = MaterialTheme.typography.titleMedium)
            Text(
                "OpenScribe stays linked in the background with a quiet notification, and reconnects after a restart. " +
                    "It sleeps between messages, so it uses very little battery.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (allowed) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.foundation.layout.Box(
                        Modifier.size(8.dp).clip(androidx.compose.foundation.shape.CircleShape).background(Flow.colors.success),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text("Allowed to run in the background", style = MaterialTheme.typography.bodyMedium)
                }
            } else {
                Text(
                    "Battery optimization may cut the link when the screen is off, so Mac copies wait until you open the app.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                FilledTonalButton(onClick = { context.requestBackgroundAllowance() }) { Text("Allow background use") }
            }
        }
    }
}
