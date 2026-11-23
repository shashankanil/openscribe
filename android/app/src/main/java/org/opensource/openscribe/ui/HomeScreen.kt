package org.opensource.openscribe.ui

import android.Manifest
import android.app.StatusBarManager
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.drawable.Icon as SystemIcon
import android.os.Build
import android.text.format.DateUtils
import android.view.ViewTreeObserver
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.opensource.openscribe.CLIP_LABEL
import org.opensource.openscribe.ClipEntry
import org.opensource.openscribe.CLOUD_NEEDED_MESSAGE
import org.opensource.openscribe.ClipSource
import org.opensource.openscribe.ImageClips
import org.opensource.openscribe.LinkHub
import org.opensource.openscribe.R
import org.opensource.openscribe.TalkUi
import org.opensource.openscribe.link.LinkPhase
import org.opensource.openscribe.link.LinkState
import org.opensource.openscribe.link.LinkVia
import java.io.File

private fun Context.hasPermission(permission: String) =
    ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED


@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(onOpenSettings: () -> Unit, onAddMac: () -> Unit) {
    val context = LocalContext.current
    val link by LinkHub.link.collectAsStateWithLifecycle()
    val talk by LinkHub.talk.collectAsStateWithLifecycle()
    val level by LinkHub.level.collectAsStateWithLifecycle()
    val clips by LinkHub.clips.collectAsStateWithLifecycle()
    val cloudConfigs by LinkHub.cloud.collectAsStateWithLifecycle()
    val pairing by LinkHub.pairing.collectAsStateWithLifecycle()
    val hasCloud = pairing?.macId?.let { cloudConfigs[it] } != null
    var showMicRationale by remember { mutableStateOf(false) }
    var micDenied by remember { mutableStateOf(false) }
    var notificationsGranted by remember {
        mutableStateOf(Build.VERSION.SDK_INT < 33 || context.hasPermission(Manifest.permission.POST_NOTIFICATIONS))
    }
    var notificationCardDismissed by remember { mutableStateOf(LinkHub.prefs.notificationRationaleDismissed) }
    var switching by remember { mutableStateOf(false) }

    val micLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        micDenied = !granted
        // The service adds the microphone type now that it is allowed.
        if (granted) LinkHub.micPermissionChanged.value++
    }
    val notificationLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        notificationsGranted = granted
        if (!granted) {
            notificationCardDismissed = true
            LinkHub.prefs.notificationRationaleDismissed = true
        }
    }

    val connected = link.phase == LinkPhase.CONNECTED

    Scaffold(
        topBar = {
            TopAppBar(
                title = { ConnectionTitle(link, onClick = { switching = true }) },
                actions = { IconButton(onClick = onOpenSettings) { Icon(Icons.Filled.Settings, "Settings") } },
            )
        },
        bottomBar = {
            TalkDock(
                talk = talk,
                connected = connected,
                level = level,
                micDenied = micDenied,
                onPress = {
                    if (!context.hasPermission(Manifest.permission.RECORD_AUDIO)) {
                        showMicRationale = true
                        false
                    } else LinkHub.startTalk()
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(4.dp))
            ConnectionHelp(link, hasCloud)

            if (!notificationsGranted && !notificationCardDismissed) {
                HintCard(
                    icon = { Icon(Icons.Filled.Info, null) },
                    title = "Stay connected in the background",
                    body = "Allow notifications so OpenScribe can keep a quiet link to ${LinkHub.macName}. Mac copies then reach this phone even when the app is closed.",
                    action = "Allow" to { notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) },
                    onDismiss = {
                        notificationCardDismissed = true
                        LinkHub.prefs.notificationRationaleDismissed = true
                    },
                )
            }

            // One setup card at a time, most important first.
            if (!BatteryHint()) TalkButtonHint(onSetUp = onOpenSettings)

            ClipboardSection(connected = connected, clips = clips, hasCloud = hasCloud)
            Spacer(Modifier.height(8.dp))
        }
    }

    if (switching) {
        MacSwitcherSheet(onAddMac = { switching = false; onAddMac() }, onDismiss = { switching = false })
    }

    if (showMicRationale) {
        AlertDialog(
            onDismissRequest = { showMicRationale = false },
            icon = { Icon(painterResource(R.drawable.ic_mic), null) },
            title = { Text("Talk through your phone") },
            text = {
                Text(
                    "While you talk, OpenScribe streams your voice to ${LinkHub.macName} over your Wi-Fi. The Mac " +
                        "turns it into text and types it. The microphone is only on while the talk button is red."
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showMicRationale = false
                    micLauncher.launch(Manifest.permission.RECORD_AUDIO)
                }) { Text("Allow microphone") }
            },
            dismissButton = { TextButton(onClick = { showMicRationale = false }) { Text("Not now") } },
        )
    }
}

fun readClipboard(context: Context): String =
    context.getSystemService(ClipboardManager::class.java).primaryClip
        ?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()

/** The image on the clipboard, or null if it holds something else. Reading it counts as a paste. */
fun readClipboardImage(context: Context): android.net.Uri? {
    val clip = context.getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 } ?: return null
    val uri = clip.getItemAt(0)?.uri ?: return null
    val isImage = ImageClips.isImage(clip.description) ||
        context.contentResolver.getType(uri)?.startsWith("image/") == true
    return uri.takeIf { isImage }
}

// MARK: Connection

@Composable
private fun ConnectionTitle(link: LinkState, onClick: () -> Unit) {
    val mac = LinkHub.macName
    val (status, color) = when (link.phase) {
        LinkPhase.CONNECTED -> (if (link.via == LinkVia.CLOUD) "Connected via cloud" else "Connected") to Flow.colors.success
        LinkPhase.CONNECTING, LinkPhase.LOOKING -> "Connecting…" to Flow.colors.warning
        LinkPhase.UNPAIRED, LinkPhase.VERSION_MISMATCH -> "Can't connect" to MaterialTheme.colorScheme.error
        LinkPhase.STOPPED -> "Disconnected" to MaterialTheme.colorScheme.outline
    }
    Row(
        Modifier.clip(RoundedCornerShape(12.dp)).clickable(onClickLabel = "Switch Mac", onClick = onClick)
            .padding(vertical = 4.dp, horizontal = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(R.drawable.ic_laptop), null, Modifier.size(26.dp))
        Spacer(Modifier.width(12.dp))
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(mac, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false))
                Icon(Icons.Filled.KeyboardArrowDown, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(color))
                Spacer(Modifier.width(6.dp))
                Text(status, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Explains what to do when the Mac can't be reached. Waits a moment so a normal reconnect doesn't flash it. */
@Composable
private fun ConnectionHelp(link: LinkState, hasCloud: Boolean) {
    val mac = LinkHub.macName
    var settled by remember { mutableStateOf(false) }
    LaunchedEffect(link.phase) {
        settled = false
        delay(2_500)
        settled = true
    }
    val content: Triple<String, String, Pair<String, () -> Unit>>? = when (link.phase) {
        LinkPhase.CONNECTED -> null
        LinkPhase.LOOKING, LinkPhase.CONNECTING -> if (!settled) null else Triple(
            "Looking for $mac",
            if (hasCloud) "Check that the Mac is awake with OpenScribe open and signed in. It connects over OpenScribe " +
                "Cloud when the two aren't on the same Wi-Fi."
            else "Check that the Mac is awake and on the same Wi-Fi as this phone, and that OpenScribe → Phone → " +
                "“Allow phones on this network” is on.",
            "Try again" to { LinkHub.reconnect() },
        )
        LinkPhase.STOPPED -> Triple("Disconnected", "Clipboard sync and talking are paused.", "Connect" to { LinkHub.reconnect() })
        LinkPhase.UNPAIRED -> Triple(
            "$mac doesn't know this phone anymore",
            "It was removed on the Mac. Pair again to keep using it.",
            "Pair again" to { LinkHub.unpair() },
        )
        LinkPhase.VERSION_MISMATCH -> Triple(
            "Update needed",
            "This phone and $mac run different versions of OpenScribe. Update both to the latest version.",
            "Try again" to { LinkHub.reconnect() },
        )
    }
    AnimatedVisibility(content != null, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
        content?.let { (title, body, action) ->
            HintCard(
                icon = { Icon(Icons.Filled.Warning, null, tint = if (link.phase == LinkPhase.UNPAIRED) MaterialTheme.colorScheme.error else Flow.colors.warning) },
                title = title,
                body = body,
                action = action,
                actionIcon = Icons.Filled.Refresh.takeIf { link.phase != LinkPhase.UNPAIRED },
            )
        }
    }
}

@Composable
private fun HintCard(
    icon: @Composable () -> Unit,
    title: String,
    body: String,
    action: Pair<String, () -> Unit>? = null,
    actionIcon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    onDismiss: (() -> Unit)? = null,
) {
    Card(Modifier.fillMaxWidth(), border = flowBorder(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh)) {
        Row(Modifier.padding(start = 16.dp, top = 14.dp, end = 8.dp, bottom = 8.dp)) {
            Box(Modifier.padding(top = 2.dp)) { icon() }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleSmall)
                Spacer(Modifier.height(2.dp))
                Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (action != null) {
                    TextButton(onClick = action.second, Modifier.padding(start = 0.dp)) {
                        if (actionIcon != null) {
                            Icon(actionIcon, null, Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                        }
                        Text(action.first)
                    }
                }
            }
            if (onDismiss != null) IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, "Dismiss") }
        }
    }
}

/** Battery optimization can cut the link while the screen is off; offer to lift it once. */
@Composable
private fun BatteryHint(): Boolean {
    val context = LocalContext.current
    var allowed by remember { mutableStateOf(context.ignoresBatteryOptimizations()) }
    var dismissed by remember { mutableStateOf(LinkHub.prefs.batteryPromptDismissed) }
    LifecycleResumeEffect(Unit) {
        allowed = context.ignoresBatteryOptimizations()
        onPauseOrDispose {}
    }
    if (allowed || dismissed) return false
    HintCard(
        icon = { Icon(Icons.Filled.Info, null, tint = MaterialTheme.colorScheme.primary) },
        title = "Keep it always on",
        body = "Let OpenScribe run in the background so Mac copies reach this phone and the talk button works with the app closed. It sleeps between messages.",
        action = "Allow" to { context.requestBackgroundAllowance() },
        onDismiss = {
            dismissed = true
            LinkHub.prefs.batteryPromptDismissed = true
        },
    )
    return true
}

/** Points people at the hardware talk button until they set it up or dismiss this. */
@Composable
private fun TalkButtonHint(onSetUp: () -> Unit) {
    var dismissed by remember { mutableStateOf(LinkHub.prefs.talkButtonHintDismissed) }
    if (dismissed || LinkHub.prefs.talkKey != null) return
    HintCard(
        icon = { Icon(painterResource(R.drawable.ic_mic), null, tint = MaterialTheme.colorScheme.primary) },
        title = "Talk with a phone button",
        body = "Hold volume down, or try the Essential Key, to dictate from any app without opening OpenScribe.",
        action = "Set up" to onSetUp,
        onDismiss = {
            dismissed = true
            LinkHub.prefs.talkButtonHintDismissed = true
        },
    )
}

// MARK: Clipboard

private enum class PhoneClip { EMPTY, TEXT, FROM_MAC, IMAGE, OTHER }

/**
 * What's on this phone's clipboard, from its description only: reading the content itself would make Android
 * show "OpenScribe pasted from your clipboard" every time the screen opens. Refreshes on focus and on change.
 */
@Composable
private fun rememberPhoneClip(): PhoneClip {
    val context = LocalContext.current
    val view = LocalView.current
    val clipboard = remember { context.getSystemService(ClipboardManager::class.java) }
    fun read(): PhoneClip {
        if (!clipboard.hasPrimaryClip()) return PhoneClip.EMPTY
        val description = clipboard.primaryClipDescription ?: return PhoneClip.EMPTY
        return when {
            description.label == CLIP_LABEL -> PhoneClip.FROM_MAC
            description.hasMimeType("text/*") -> PhoneClip.TEXT
            ImageClips.isImage(description) -> PhoneClip.IMAGE
            else -> PhoneClip.OTHER
        }
    }
    var state by remember { mutableStateOf(read()) }
    DisposableEffect(clipboard, view) {
        val changed = ClipboardManager.OnPrimaryClipChangedListener { state = read() }
        // Android only answers clipboard queries once the window has focus, which comes after onResume.
        val focus = ViewTreeObserver.OnWindowFocusChangeListener { hasFocus -> if (hasFocus) state = read() }
        clipboard.addPrimaryClipChangedListener(changed)
        view.viewTreeObserver.addOnWindowFocusChangeListener(focus)
        onDispose {
            clipboard.removePrimaryClipChangedListener(changed)
            view.viewTreeObserver.removeOnWindowFocusChangeListener(focus)
        }
    }
    LifecycleResumeEffect(Unit) {
        state = read()
        onPauseOrDispose {}
    }
    return state
}

@Composable
private fun ClipboardSection(connected: Boolean, clips: List<ClipEntry>, hasCloud: Boolean) {
    val context = LocalContext.current
    val mac = LinkHub.macName
    val phoneClip = rememberPhoneClip()
    var sentAt by remember { mutableLongStateOf(0L) }
    LaunchedEffect(sentAt) {
        if (sentAt != 0L) {
            delay(4_000)
            sentAt = 0L
        }
    }
    val lastSent = clips.firstOrNull { it.toMac }
    val justSent = sentAt != 0L && lastSent != null && lastSent.atMillis >= sentAt

    SectionTitle("Clipboard")
    Card(Modifier.fillMaxWidth(), border = flowBorder(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Phone → Mac
            val sendsImage = phoneClip == PhoneClip.IMAGE && hasCloud
            val canSend = connected && (phoneClip == PhoneClip.TEXT || sendsImage)
            val buttonColor by animateColorAsState(
                if (justSent) Flow.colors.success else MaterialTheme.colorScheme.primary, label = "send",
            )
            Button(
                onClick = {
                    val image = if (sendsImage) readClipboardImage(context) else null
                    if (image != null) {
                        sentAt = System.currentTimeMillis()
                        LinkHub.sendImage(image, ClipSource.APP)
                    } else {
                        val text = readClipboard(context)
                        if (text.isBlank()) LinkHub.toast("Nothing copied yet")
                        else {
                            sentAt = System.currentTimeMillis()
                            LinkHub.sendClip(text, ClipSource.APP)
                        }
                    }
                },
                enabled = canSend || justSent,
                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
                colors = ButtonDefaults.buttonColors(containerColor = buttonColor, disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest),
            ) {
                AnimatedContent(justSent, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "sendLabel") { sent ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (sent) {
                            Text(if (lastSent?.confirmed == true) "Sent to $mac" else "Sending…")
                        } else {
                            Icon(painterResource(R.drawable.ic_arrow_up), null)
                            Spacer(Modifier.width(8.dp))
                            Text(
                                if (sendsImage) "Send copied image to $mac" else "Send copied text to $mac",
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
            Text(
                when {
                    justSent -> "Paste it on the Mac with ⌘V."
                    !connected -> "Sending works once $mac is connected."
                    phoneClip == PhoneClip.TEXT -> "Sends what you last copied on this phone."
                    phoneClip == PhoneClip.FROM_MAC -> "Your clipboard holds the last copy from $mac, so there's nothing new to send."
                    phoneClip == PhoneClip.IMAGE && hasCloud -> "Sends the image you copied, end-to-end encrypted through OpenScribe Cloud."
                    phoneClip == PhoneClip.IMAGE -> CLOUD_NEEDED_MESSAGE
                    phoneClip == PhoneClip.OTHER -> "Your clipboard holds a file. Only text and images can be sent."
                    else -> "Copy some text in any app, then come back here to send it."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            HorizontalDivider()

            // Mac → phone
            Row(verticalAlignment = Alignment.CenterVertically) {
                DirectionBadge(toMac = false)
                Spacer(Modifier.width(12.dp))
                Text(
                    if (connected && hasCloud) "Copy text or an image on $mac and it's on this phone instantly, ready to paste."
                    else if (connected) "Copy anything on $mac and it's on this phone instantly, ready to paste."
                    else "Copies on $mac arrive here automatically while connected.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }

    TilePrompt()

    if (clips.isNotEmpty()) {
        SectionTitle("Recent")
        val now by produceState(System.currentTimeMillis()) {
            while (true) {
                delay(30_000)
                value = System.currentTimeMillis()
            }
        }
        Card(Modifier.fillMaxWidth(), border = flowBorder(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
            clips.forEachIndexed { index, clip ->
                if (index > 0) HorizontalDivider(Modifier.padding(start = 60.dp))
                ClipRow(clip, mac, now, connected)
            }
        }
        Text(
            "Tap an item to copy it to this phone again.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 4.dp, top = 8.dp),
    )
}

@Composable
private fun DirectionBadge(toMac: Boolean) {
    Box(
        Modifier.size(36.dp).clip(CircleShape)
            .background(if (toMac) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.tertiaryContainer),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(if (toMac) R.drawable.ic_arrow_up else R.drawable.ic_arrow_down),
            if (toMac) "To Mac" else "From Mac",
            Modifier.size(20.dp),
            tint = if (toMac) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onTertiaryContainer,
        )
    }
}

@Composable
private fun ClipRow(clip: ClipEntry, mac: String, now: Long, connected: Boolean) {
    val ago = DateUtils.getRelativeTimeSpanString(clip.atMillis, now, DateUtils.MINUTE_IN_MILLIS).toString()
        .let { if (now - clip.atMillis < DateUtils.MINUTE_IN_MILLIS) "just now" else it }
    val image = clip.image
    val copy = { if (image != null) LinkHub.copyImageToPhone(image) else LinkHub.copyToPhone(clip.text) }
    Row(
        Modifier.fillMaxWidth().clickable(onClick = copy).padding(start = 12.dp, end = 4.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (image != null) ImageThumbnail(image, clip.toMac) else DirectionBadge(clip.toMac)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                clip.text.replace('\n', ' ').trim(),
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                when {
                    !clip.toMac -> "From $mac · $ago"
                    clip.confirmed -> "Sent to $mac · $ago"
                    else -> "Sending to $mac…"
                },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (clip.toMac) {
            IconButton(
                onClick = { if (image != null) LinkHub.resendImage(image) else LinkHub.sendClip(clip.text, ClipSource.APP) },
                enabled = connected,
            ) {
                Icon(painterResource(R.drawable.ic_arrow_up), "Send to $mac again")
            }
        } else {
            IconButton(onClick = copy) {
                Icon(painterResource(R.drawable.ic_copy), "Copy")
            }
        }
    }
}

/** A Recent image, the size of [DirectionBadge], with a small dot in its direction's color. */
@Composable
private fun ImageThumbnail(file: File, toMac: Boolean) {
    val sizePx = with(LocalDensity.current) { 72.dp.roundToPx() }
    val context = LocalContext.current
    val bitmap by produceState<ImageBitmap?>(null, file) {
        value = withContext(Dispatchers.IO) { ImageClips.thumbnail(context, file, sizePx)?.asImageBitmap() }
    }
    val colors = MaterialTheme.colorScheme
    Box(Modifier.size(36.dp)) {
        Box(
            Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)).background(colors.surfaceContainerHighest),
            contentAlignment = Alignment.Center,
        ) {
            bitmap?.let {
                Image(it, if (toMac) "Image sent to Mac" else "Image from Mac", Modifier.size(36.dp), contentScale = ContentScale.Crop)
            }
        }
        Box(
            Modifier.align(Alignment.BottomEnd).size(10.dp).clip(CircleShape).background(colors.surfaceContainer).padding(2.dp)
                .clip(CircleShape).background(if (toMac) colors.primary else colors.tertiary),
        )
    }
}

/** Offers the Send clipboard tile, the quickest way to send from another app. Android 13+ can add it in one tap. */
@Composable
private fun TilePrompt() {
    if (Build.VERSION.SDK_INT < 33) return
    val context = LocalContext.current
    var visible by remember { mutableStateOf(!LinkHub.prefs.tilePromptDone) }
    if (!visible) return
    fun done() {
        LinkHub.prefs.tilePromptDone = true
        visible = false
    }
    HintCard(
        icon = { Icon(painterResource(R.drawable.ic_tile), null, tint = MaterialTheme.colorScheme.primary) },
        title = "Send from any app",
        body = "Add a Send clipboard button to Quick Settings: copy, swipe down, tap. You can also use Share → OpenScribe.",
        action = "Add to Quick Settings" to {
            context.getSystemService(StatusBarManager::class.java).requestAddTileService(
                ComponentName(context, ClipTileService::class.java),
                context.getString(R.string.tile_send_clipboard),
                SystemIcon.createWithResource(context, R.drawable.ic_copy),
                context.mainExecutor,
            ) { result ->
                if (result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                    result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED
                ) done()
            }
        },
        onDismiss = ::done,
    )
}

// MARK: Talk

@Composable
private fun TalkDock(
    talk: TalkUi,
    connected: Boolean,
    level: Float,
    micDenied: Boolean,
    onPress: () -> Boolean,
) {
    val view = LocalView.current
    val haptics = remember { LinkHub.prefs.haptics }
    val recording = talk as? TalkUi.Recording
    val mode = when {
        recording?.locked == true -> TalkMode.LOCKED
        recording != null -> TalkMode.HOLDING
        talk is TalkUi.Transcribing -> TalkMode.BUSY
        !connected -> TalkMode.DISABLED
        else -> TalkMode.IDLE
    }
    // Keep the screen on while the microphone is live, so a long hands-free dictation isn't cut off.
    DisposableEffect(recording != null) {
        view.keepScreenOn = recording != null
        onDispose { view.keepScreenOn = false }
    }
    val elapsed by produceState(0L, recording?.id) {
        val started = recording?.startedAt ?: return@produceState
        while (true) {
            value = System.currentTimeMillis() - started
            delay(200)
        }
    }

    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shadowElevation = 16.dp,
        border = flowBorder(),
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            Modifier.navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            ResultCard(talk)
            TalkStatus(mode, recording, talk, elapsed, micDenied)
            TalkPad(
                mode = mode,
                level = level,
                haptics = haptics,
                onPress = onPress,
                onRelease = { LinkHub.endTalk() },
                onLock = {
                    LinkHub.lockTalk()
                    view.announceForAccessibility("Hands-free. Tap send when you're done.")
                },
                onCancel = { LinkHub.cancelTalk() },
            )
        }
    }
}

@Composable
private fun TalkStatus(mode: TalkMode, recording: TalkUi.Recording?, talk: TalkUi, elapsedMs: Long, micDenied: Boolean) {
    val mac = LinkHub.macName
    val target = recording?.target ?: (talk as? TalkUi.Transcribing)?.target
    val pastes = (recording?.pasted ?: (talk as? TalkUi.Transcribing)?.pasted) != false
    val destination = if (target != null && pastes) "$target on $mac" else mac
    val seconds = elapsedMs / 1000
    val clock = "%d:%02d".format(seconds / 60, seconds % 60)
    val experienced = LinkHub.prefs.talkCount >= 5

    val (title, detail) = when (mode) {
        TalkMode.DISABLED -> "Talk" to "Available once $mac is connected"
        TalkMode.IDLE -> "Hold to talk" to (
            LinkHub.prefs.talkKey?.takeIf { LinkHub.talkKeyServiceOn.value }?.let { "Or hold ${it.name} from any app" }
                ?: if (experienced) "Tap for hands-free" else "Release to send · or tap once for hands-free"
            )
        TalkMode.HOLDING -> clock to "Typing into $destination · release to send"
        TalkMode.LOCKED -> "$clock · hands-free" to "Tap ➤ to send to $destination"
        TalkMode.BUSY -> "Writing it up…" to (if (target != null && pastes) "Then typing into $target" else "On $mac")
    }
    Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (mode == TalkMode.HOLDING || mode == TalkMode.LOCKED) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(MaterialTheme.colorScheme.error))
                Spacer(Modifier.width(8.dp))
            }
            Text(
                title,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = if (mode == TalkMode.HOLDING || mode == TalkMode.LOCKED) FontWeight.Medium else null,
            )
        }
        Text(
            if (micDenied && mode == TalkMode.IDLE) "Microphone access is off. Allow it in Settings → Apps → OpenScribe → Permissions." else detail,
            style = MaterialTheme.typography.bodyMedium,
            color = if (micDenied && mode == TalkMode.IDLE) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )        // What the phone has transcribed so far, newest words visible.
        val heard = recording?.heard?.trim()?.takeIf { it.isNotEmpty() }
        if (heard != null) {
            Text(
                "Hearing: " + heard.takeLast(HEARD_CHARS).let { if (heard.length > HEARD_CHARS) "…" + it.substringAfter(' ') else it },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

/** About two lines of the talk dock. */
private const val HEARD_CHARS = 90

/** The outcome of the last dictation, just above the talk button where the eye already is. */
@Composable
private fun ResultCard(talk: TalkUi) {
    val mac = LinkHub.macName
    val shown = talk is TalkUi.Done || talk is TalkUi.Failed || talk is TalkUi.Discarded
    AnimatedVisibility(shown, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
        // Hold on to the last outcome while the card animates away.
        var last by remember { mutableStateOf(talk) }
        if (shown) last = talk
        val (title, body, isError) = when (val t = last) {
            is TalkUi.Done -> Triple(
                when {
                    t.text.isEmpty() -> "Nothing to type"
                    t.pasted == false -> "Saved to Notes on $mac"
                    t.target != null -> "Typed into ${t.target}"
                    else -> "Typed on $mac"
                },
                t.text.takeIf { it.isNotEmpty() },
                false,
            )
            TalkUi.Discarded -> Triple(
                "Didn't catch that",
                "It was too short or too quiet. Hold the button while you speak, or speak up a little.",
                true,
            )
            is TalkUi.Failed -> Triple("Couldn't send", t.message, true)
            else -> Triple("", null, false)
        }
        Card(
            Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = if (isError) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainerHighest,
            ),
        ) {
            Row(Modifier.padding(start = 14.dp, top = 12.dp, end = 4.dp, bottom = 4.dp)) {
                Box(
                    Modifier.padding(top = 6.dp).size(8.dp).clip(CircleShape)
                        .background(if (isError) MaterialTheme.colorScheme.error else Flow.colors.success),
                )
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        title,
                        style = MaterialTheme.typography.labelLarge,
                        color = if (isError) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurface,
                    )
                    if (body != null) {
                        Text(
                            if (last is TalkUi.Done) "“$body”" else body,
                            style = MaterialTheme.typography.bodyMedium,
                            color = if (isError) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    val done = last as? TalkUi.Done
                    if (done != null && done.text.isNotEmpty()) {
                        FilledTonalButton(
                            onClick = { LinkHub.copyToPhone(done.text) },
                            modifier = Modifier.padding(top = 6.dp, bottom = 6.dp).height(34.dp),
                            contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
                        ) {
                            Icon(painterResource(R.drawable.ic_copy), null, Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Copy to phone", style = MaterialTheme.typography.labelMedium)
                        }
                    } else Spacer(Modifier.height(8.dp))
                }
                IconButton(onClick = { LinkHub.clearTalkResult() }) {
                    Icon(Icons.Filled.Close, "Dismiss", tint = if (isError) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
fun StatusChip(link: LinkState) {
    val mac = LinkHub.macName
    val (label, color) = when (link.phase) {
        LinkPhase.CONNECTED -> (if (link.via == LinkVia.CLOUD) "Connected to $mac via cloud" else "Connected to $mac") to Flow.colors.success
        LinkPhase.CONNECTING -> "Connecting to $mac…" to Flow.colors.warning
        LinkPhase.LOOKING -> "Looking for $mac…" to Flow.colors.warning
        LinkPhase.UNPAIRED -> "$mac removed this phone" to MaterialTheme.colorScheme.error
        LinkPhase.VERSION_MISMATCH -> "Update OpenScribe on this phone and $mac" to MaterialTheme.colorScheme.error
        LinkPhase.STOPPED -> "Disconnected from $mac" to MaterialTheme.colorScheme.outline
    }
    androidx.compose.material3.AssistChip(
        onClick = { LinkHub.reconnect() },
        label = { Text(label, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        leadingIcon = { Box(Modifier.size(10.dp).clip(CircleShape).background(color)) },
    )
}
