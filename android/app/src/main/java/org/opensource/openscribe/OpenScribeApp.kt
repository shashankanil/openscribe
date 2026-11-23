package org.opensource.openscribe

import android.app.Application

class OpenScribeApp : Application() {
    override fun onCreate() {
        super.onCreate()
        LinkHub.init(this)
        LinkService.createChannel(this)
    }
}
