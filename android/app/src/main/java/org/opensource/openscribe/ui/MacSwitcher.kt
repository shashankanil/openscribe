package org.opensource.openscribe.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.opensource.openscribe.LinkHub
import org.opensource.openscribe.R
import org.opensource.openscribe.link.LinkPhase
import org.opensource.openscribe.link.LinkVia
import org.opensource.openscribe.link.PairingLink

/** Lists paired Macs. One is active (connected) at a time; tap another to switch to it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MacSwitcherSheet(onAddMac: () -> Unit, onDismiss: () -> Unit) {
    val pairings by LinkHub.pairings.collectAsStateWithLifecycle()
    val active by LinkHub.pairing.collectAsStateWithLifecycle()
    val link by LinkHub.link.collectAsStateWithLifecycle()
    var forgetting by remember { mutableStateOf<PairingLink?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.navigationBarsPadding().padding(horizontal = 16.dp).padding(bottom = 16.dp)) {
            Text("Your Macs", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(start = 4.dp))
            Text(
                "OpenScribe connects to one Mac at a time. Tap a Mac to switch to it.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 4.dp, top = 2.dp, bottom = 12.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                pairings.forEach { mac ->
                    val isActive = mac.macId == active?.macId
                    MacRow(
                        mac = mac,
                        active = isActive,
                        status = if (!isActive) "Tap to switch" else when (link.phase) {
                            LinkPhase.CONNECTED -> if (link.via == LinkVia.CLOUD) "Connected via cloud" else "Connected"
                            LinkPhase.CONNECTING, LinkPhase.LOOKING -> "Connecting…"
                            LinkPhase.UNPAIRED -> "Removed this phone"
                            LinkPhase.VERSION_MISMATCH -> "Needs an update"
                            LinkPhase.STOPPED -> "Disconnected"
                        },
                        connected = isActive && link.phase == LinkPhase.CONNECTED,
                        onClick = {
                            LinkHub.switchTo(mac.macId)
                            onDismiss()
                        },
                        onForget = { forgetting = mac },
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            OutlinedButton(onClick = onAddMac, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                Icon(Icons.Filled.Add, null)
                Spacer(Modifier.width(8.dp))
                Text("Add another Mac")
            }
        }
    }

    forgetting?.let { mac ->
        AlertDialog(
            onDismissRequest = { forgetting = null },
            title = { Text("Forget ${mac.macName}?") },
            text = { Text("This phone stops connecting to it. To finish, also remove the phone on that Mac (OpenScribe → Phone).") },
            confirmButton = {
                TextButton(onClick = {
                    LinkHub.forget(mac.macId)
                    forgetting = null
                    if (LinkHub.pairings.value.isEmpty()) onDismiss()
                }) { Text("Forget") }
            },
            dismissButton = { TextButton(onClick = { forgetting = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun MacRow(
    mac: PairingLink,
    active: Boolean,
    status: String,
    connected: Boolean,
    onClick: () -> Unit,
    onForget: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = if (active) colors.primaryContainer else colors.surfaceContainerHigh,
        border = BorderStroke(if (active) 1.5.dp else 1.dp, if (active) colors.primary else Flow.colors.line),
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).clickable(onClick = onClick),
    ) {
        Row(Modifier.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(R.drawable.ic_laptop), null, tint = if (active) colors.onPrimaryContainer else colors.onSurfaceVariant)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(mac.macName, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (active) {
                        Box(Modifier.size(7.dp).clip(CircleShape).background(if (connected) Flow.colors.success else Flow.colors.warning))
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(status, style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
                }
            }
            TextButton(onClick = onForget) { Text("Forget", color = colors.onSurfaceVariant) }
        }
    }
}
