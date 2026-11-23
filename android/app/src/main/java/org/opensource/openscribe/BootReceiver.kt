package org.opensource.openscribe

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Reconnects to the Mac after a reboot or an app update, so Phone Link is always on without opening the app. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> LinkService.start(context)
        }
    }
}
