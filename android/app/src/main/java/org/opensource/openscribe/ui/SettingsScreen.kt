package org.opensource.openscribe.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.opensource.openscribe.BuildConfig
import org.opensource.openscribe.LinkHub
import org.opensource.openscribe.link.LinkPhase

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val link by LinkHub.link.collectAsStateWithLifecycle()
    val pairing by LinkHub.pairing.collectAsStateWithLifecycle()
    val cloud by LinkHub.cloud.collectAsStateWithLifecycle()
    var boost by remember { mutableStateOf(LinkHub.prefs.whisperBoost) }
    var haptics by remember { mutableStateOf(LinkHub.prefs.haptics) }
    var autoSend by remember { mutableStateOf(LinkHub.prefs.autoSendOnOpen) }
    var confirmUnpair by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PhoneCopiesCard()
            TalkButtonCard()
            BackgroundCard()

            Card(Modifier.fillMaxWidth(), border = flowBorder(), colors = androidx.compose.material3.CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Mac", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(LinkHub.macName, style = MaterialTheme.typography.titleMedium)
                    StatusChip(link)
                    link.endpoint?.let { Detail("Address", it) }
                    if (link.phase != LinkPhase.CONNECTED) link.lastError?.let { Detail("Last error", it) }
                    pairing?.let {
                        if (it.hosts.isNotEmpty()) Detail("Fallback addresses", it.hosts.joinToString(", ") + " : " + it.port)
                        Detail(
                            "OpenScribe Cloud",
                            if (cloud[it.macId] != null) "On. Images and connecting from other networks work."
                            else "Off. Sign in with Google on the Mac (OpenScribe → Connect AI apps) to send images and connect from other networks.",
                        )
                    }
                }
            }

            Card(Modifier.fillMaxWidth(), border = flowBorder(), colors = androidx.compose.material3.CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
                Column(Modifier.padding(vertical = 8.dp)) {
                    Toggle(
                        "Whisper boost",
                        "Raises quiet speech so whispers reach the Mac, without boosting background hiss.",
                        boost,
                    ) { boost = it; LinkHub.prefs.whisperBoost = it }
                    Toggle("Haptics", "Vibrate when you press, lock, release or cancel the talk button.", haptics) {
                        haptics = it; LinkHub.prefs.haptics = it
                    }
                    Toggle(
                        "Auto-send clipboard",
                        "Send the clipboard to the Mac whenever you open OpenScribe.",
                        autoSend,
                    ) { autoSend = it; LinkHub.prefs.autoSendOnOpen = it }
                }
            }

            OutlinedButton(
                onClick = { confirmUnpair = true },
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) { Text("Forget ${LinkHub.macName}") }

            Text(
                "OpenScribe ${BuildConfig.VERSION_NAME}. Audio and clipboard text travel only over your local network, " +
                    "encrypted with a key made when you paired.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }

    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text("Forget ${LinkHub.macName}?") },
            text = { Text("This phone stops connecting to it. Other paired Macs stay. To finish, also remove the phone on that Mac (OpenScribe → Phone).") },
            confirmButton = {
                TextButton(onClick = {
                    confirmUnpair = false
                    LinkHub.unpair()
                    onBack()
                }) { Text("Forget") }
            },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Detail(label: String, value: String) {
    Text("$label: $value", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun Toggle(title: String, detail: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
