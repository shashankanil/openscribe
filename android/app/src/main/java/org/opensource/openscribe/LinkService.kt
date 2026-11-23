package org.opensource.openscribe

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import org.opensource.openscribe.link.LinkPhase
import org.opensource.openscribe.link.LinkVia
import org.opensource.openscribe.ui.MainActivity
import org.opensource.openscribe.ui.SendClipActivity

/**
 * Holds the link to the Mac while the phone is paired. Runs as a `connectedDevice` foreground service, and also
 * holds the `microphone` type while our UI is visible or a talk is in progress, so a hands-free (locked) talk
 * keeps recording if the user leaves the app.
 */
class LinkService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var currentTypes = -1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        LinkHub.init(this)
        createChannel(this)
        updateForeground()

        scope.launch {
            LinkHub.pairing.collect { pairing ->
                if (pairing == null) {
                    LinkHub.stopClient()
                    stopSelf()
                } else {
                    LinkHub.startClient(this@LinkService)
                }
            }
        }
        scope.launch {
            val talkKey = combine(LinkHub.talkKeyServiceOn, LinkHub.talkKeyChanged) { on, changed -> on to changed }
            combine(LinkHub.link, LinkHub.talk, LinkHub.uiVisible, LinkHub.micPermissionChanged, talkKey) { link, talk, visible, mic, key ->
                listOf(link, talk, visible, mic, key)
            }
                .distinctUntilChanged()
                .collect { updateForeground() }
        }
        registerNetworkCallback()
        registerScreenReceiver()
    }

    private var screenReceiver: android.content.BroadcastReceiver? = null

    /** Picking up the phone reconnects at once, instead of waiting out a backoff that grew while it slept. */
    private fun registerScreenReceiver() {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) { LinkHub.kick() }
        }
        val filter = android.content.IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        ContextCompat.registerReceiver(this, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        screenReceiver = receiver
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        updateForeground()
        when (intent?.action) {
            ACTION_STOP -> {
                LinkHub.stopClient()
                stopSelf()
                return START_NOT_STICKY
            }
        }
        if (LinkHub.pairing.value == null) stopSelf()
        return START_STICKY
    }

    override fun onDestroy() {
        networkCallback?.let {
            try { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } catch (_: Exception) {}
        }
        screenReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        scope.cancel()
        LinkHub.stopClient()
        super.onDestroy()
    }

    private fun registerNetworkCallback() {
        val callback = object : ConnectivityManager.NetworkCallback() {
            private var last: Network? = null
            override fun onAvailable(network: Network) {
                val previous = last
                last = network
                if (previous == null) LinkHub.kick() else if (previous != network) LinkHub.networkLost()
            }
            override fun onLost(network: Network) {
                if (network == last) {
                    last = null
                    LinkHub.networkLost()
                }
            }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {}
        }
        try {
            getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (e: Exception) {
            Log.w("OpenScribe", "network callback", e)
        }
    }

    private fun updateForeground() {
        // The microphone FGS type exists from Android 11; Android 10 has no while-in-use mic restriction.
        // With a talk button set up, keep the type so the button can start the mic from any app. Android only lets
        // the type be added while our UI is visible, so it's taken then and kept; the mic itself stays off until you talk.
        val talkButtonReady = LinkHub.talkKeyServiceOn.value && LinkHub.prefs.talkKey != null
        val wantMic = Build.VERSION.SDK_INT >= 30 &&
            (LinkHub.uiVisible.value || LinkHub.talk.value is TalkUi.Recording || (talkButtonReady && currentTypes.hasMic())) &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
            (if (wantMic) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
        val notification = buildNotification()
        if (types == currentTypes) {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
            return
        }
        try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, types)
            currentTypes = types
        } catch (e: Exception) {
            // The microphone type can only start while our UI is visible; fall back to the link alone.
            Log.w("OpenScribe", "startForeground($types) failed", e)
            try {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                currentTypes = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            } catch (e2: Exception) {
                Log.e("OpenScribe", "startForeground failed", e2)
                stopSelf()
            }
        }
    }

    private fun buildNotification(): Notification {
        val link = LinkHub.link.value
        val mac = LinkHub.macName
        val title = when (link.phase) {
            LinkPhase.CONNECTED -> if (link.via == LinkVia.CLOUD) "Connected to $mac via cloud" else "Connected to $mac"
            LinkPhase.UNPAIRED -> "$mac removed this phone"
            LinkPhase.VERSION_MISMATCH -> "Update OpenScribe to connect to $mac"
            LinkPhase.STOPPED -> "OpenScribe Phone Link"
            else -> "Looking for $mac…"
        }
        val talk = LinkHub.talk.value
        val key = LinkHub.prefs.talkKey?.takeIf { LinkHub.talkKeyServiceOn.value }
        val text = when {
            talk is TalkUi.Recording && talk.locked -> "Listening hands-free · press ${key?.name ?: "send"} again to send"
            talk is TalkUi.Recording -> "Listening… release to send"
            talk is TalkUi.Transcribing -> "Writing it up on $mac…"
            talk is TalkUi.Done && talk.text.isNotEmpty() -> (if (talk.pasted != false && talk.target != null) "Typed into ${talk.target}: " else "Sent: ") + talk.text
            link.phase == LinkPhase.CONNECTED && key != null -> "Hold ${key.name} to talk · Mac copies land here"
            link.phase == LinkPhase.CONNECTED -> "Copies on your Mac land on this phone's clipboard"
            link.phase == LinkPhase.UNPAIRED -> "Open OpenScribe to pair again"
            else -> "Make sure both are on the same Wi-Fi"
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val sendClip = PendingIntent.getActivity(
            this, 1, Intent(this, SendClipActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 2, Intent(this, LinkService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
            .apply { if (link.phase == LinkPhase.CONNECTED) addAction(0, "Send clipboard", sendClip) }
            .addAction(0, "Disconnect", stop)
            .build()
    }

    private fun Int.hasMic() = this != -1 && (this and ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) != 0

    companion object {
        private const val CHANNEL_ID = "link"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "org.opensource.openscribe.STOP"

        fun createChannel(context: Context) {
            val channel = NotificationChannel(CHANNEL_ID, "Phone Link", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows while OpenScribe is linked to your Mac"
                setShowBadge(false)
            }
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

        /** Starts (or pokes) the service. Call from a visible activity or the tile/share flows. */
        fun start(context: Context) {
            LinkHub.init(context)
            if (LinkHub.pairing.value == null) return
            try {
                ContextCompat.startForegroundService(context, Intent(context, LinkService::class.java))
            } catch (e: Exception) {
                Log.w("OpenScribe", "could not start LinkService", e)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LinkService::class.java))
        }
    }
}
