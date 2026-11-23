package org.opensource.openscribe.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import org.opensource.openscribe.R
import org.opensource.openscribe.link.PairingLink

@Composable
fun PairingScreen(onPaired: (PairingLink) -> Unit, onCancel: (() -> Unit)? = null) {
    val context = LocalContext.current
    var pasted by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    fun accept(text: String) {
        val link = PairingLink.parse(text)
        if (link == null) {
            error = "That isn't an OpenScribe pairing link. On your Mac, open OpenScribe → Phone → Pair a phone."
        } else {
            error = null
            onPaired(link)
        }
    }

    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (onCancel != null) {
                androidx.compose.foundation.layout.Box(Modifier.fillMaxWidth()) {
                    androidx.compose.material3.IconButton(onClick = onCancel) {
                        androidx.compose.material3.Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                    }
                }
            } else {
                Spacer(Modifier.height(32.dp))
            }
            WhisperlightLogo(72.dp)
            Text(if (onCancel != null) "Add another Mac" else "Link OpenScribe to your Mac", style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
            Text(
                "Scan the QR code on your Mac (OpenScribe → Phone → Pair a phone)",
                style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center,
            )
            Button(
                onClick = {
                    val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                    GmsBarcodeScanning.getClient(context, options).startScan()
                        .addOnSuccessListener { barcode -> barcode.rawValue?.let(::accept) }
                        .addOnFailureListener { e ->
                            error = "The scanner couldn't start (${e.message}). Paste the link instead."
                        }
                },
                modifier = Modifier.fillMaxWidth().height(56.dp),
            ) {
                Icon(painterResource(R.drawable.ic_qr), null)
                Spacer(Modifier.size(8.dp))
                Text("Scan QR code")
            }
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            OutlinedTextField(
                value = pasted,
                onValueChange = { pasted = it; error = null },
                label = { Text("Paste pairing link") },
                placeholder = { Text("openscribe://link?…") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = false,
                maxLines = 4,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
            )
            OutlinedButton(onClick = { accept(pasted) }, enabled = pasted.isNotBlank(), modifier = Modifier.fillMaxWidth()) {
                Text("Pair")
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center) }
            Text(
                "Your phone and Mac need to be on the same Wi-Fi. Transcription happens on the Mac; " +
                    "this phone is just a microphone and a clipboard.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}
