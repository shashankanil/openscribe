package org.opensource.openscribe.link

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import java.net.InetSocketAddress
import java.util.concurrent.Executors

/**
 * Finds the paired Mac with NSD (`_openscribe._tcp`, TXT `id` = the pairing's mac id). [resolve] waits up to
 * [discoveryWaitMs] for a match and then returns it followed by the pairing link's `h` hosts on port `p`, so the
 * phone still connects on networks that block multicast. Holds a Wi-Fi multicast lock only while discovering.
 */
class NsdEndpointResolver(
    context: Context,
    private val discoveryWaitMs: Long = 3_000,
    /** Called when a matching Mac appears, so the client can retry right away instead of sleeping off a backoff. */
    private val onFound: () -> Unit = {},
) : EndpointResolver {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val multicastLock = context.applicationContext.getSystemService(WifiManager::class.java)
        .createMulticastLock("openscribe-discovery").apply { setReferenceCounted(false) }
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "openscribe-nsd").apply { isDaemon = true } }

    private val lock = Object()
    private var macId: String? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    /** Service name to endpoint, for services whose TXT id matched. */
    private val found = LinkedHashMap<String, InetSocketAddress>()
    private val pendingResolves = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private val infoCallbacks = HashMap<String, Any>() // API 34+: NsdManager.ServiceInfoCallback

    override fun resolve(pairing: PairingLink): List<InetSocketAddress> {
        startDiscovery(pairing.macId)
        val deadline = System.currentTimeMillis() + discoveryWaitMs
        val discovered = synchronized(lock) {
            while (found.isEmpty()) {
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) break
                try { lock.wait(left) } catch (_: InterruptedException) { break }
            }
            found.values.toList()
        }
        return discovered + pairing.hosts.map { InetSocketAddress(it, pairing.port) }
    }

    override fun pause() = stopDiscovery()

    override fun close() = stopDiscovery()

    private fun startDiscovery(id: String) {
        synchronized(lock) {
            if (discovery != null && macId == id) return
        }
        stopDiscovery()
        synchronized(lock) {
            macId = id
            found.clear()
            try { multicastLock.acquire() } catch (e: Exception) { Log.w(TAG, "multicast lock", e) }
            val listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {}
                override fun onDiscoveryStopped(serviceType: String) {}
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "discovery failed to start: $errorCode")
                    synchronized(lock) { if (discovery === this) discovery = null }
                }
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
                override fun onServiceFound(info: NsdServiceInfo) = enqueueResolve(info)
                override fun onServiceLost(info: NsdServiceInfo) {
                    synchronized(lock) { found.remove(info.serviceName) }
                    unregisterInfoCallback(info.serviceName)
                }
            }
            discovery = listener
            try {
                nsd.discoverServices(LinkProtocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            } catch (e: Exception) {
                Log.w(TAG, "discoverServices", e)
                discovery = null
            }
        }
    }

    private fun stopDiscovery() {
        val listener: NsdManager.DiscoveryListener?
        val callbacks: List<Any>
        synchronized(lock) {
            listener = discovery
            discovery = null
            pendingResolves.clear()
            callbacks = infoCallbacks.values.toList()
            infoCallbacks.clear()
            lock.notifyAll()
        }
        if (listener != null) try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= 34) callbacks.forEach { cb ->
            try { nsd.unregisterServiceInfoCallback(cb as NsdManager.ServiceInfoCallback) } catch (_: Exception) {}
        }
        if (multicastLock.isHeld) try { multicastLock.release() } catch (_: Exception) {}
    }

    private fun accept(name: String, attributes: Map<String, ByteArray?>, host: java.net.InetAddress?, port: Int) {
        val id = attributes["id"]?.let { String(it, Charsets.UTF_8) }
        if (host == null || port <= 0) return
        val matched = synchronized(lock) {
            if (discovery == null || id == null || id != macId) false else {
                found[name] = InetSocketAddress(host, port)
                lock.notifyAll()
                true
            }
        }
        if (matched) onFound()
    }

    private fun enqueueResolve(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= 34) {
            registerInfoCallback(info)
            return
        }
        synchronized(lock) {
            pendingResolves.addLast(info)
            if (resolving) return
            resolving = true
        }
        resolveNext()
    }

    // Before API 34, NsdManager resolves one service at a time.
    @Suppress("DEPRECATION")
    private fun resolveNext() {
        val next = synchronized(lock) {
            pendingResolves.removeFirstOrNull().also { if (it == null) resolving = false }
        } ?: return
        try {
            nsd.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    resolveNext()
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    accept(info.serviceName, info.attributes, info.host, info.port)
                    resolveNext()
                }
            })
        } catch (e: Exception) {
            Log.w(TAG, "resolveService", e)
            resolveNext()
        }
    }

    private fun registerInfoCallback(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT < 34) return
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
            override fun onServiceUpdated(updated: NsdServiceInfo) {
                val host = updated.hostAddresses.firstOrNull { it is java.net.Inet4Address } ?: updated.hostAddresses.firstOrNull()
                accept(updated.serviceName, updated.attributes, host, updated.port)
            }
            override fun onServiceLost() {
                synchronized(lock) { found.remove(info.serviceName) }
            }
            override fun onServiceInfoCallbackUnregistered() {}
        }
        synchronized(lock) {
            if (discovery == null || infoCallbacks.containsKey(info.serviceName)) return
            infoCallbacks[info.serviceName] = callback
        }
        try {
            nsd.registerServiceInfoCallback(info, executor, callback)
        } catch (e: Exception) {
            Log.w(TAG, "registerServiceInfoCallback", e)
            synchronized(lock) { infoCallbacks.remove(info.serviceName) }
        }
    }

    private fun unregisterInfoCallback(name: String) {
        if (Build.VERSION.SDK_INT < 34) return
        val cb = synchronized(lock) { infoCallbacks.remove(name) } ?: return
        try { nsd.unregisterServiceInfoCallback(cb as NsdManager.ServiceInfoCallback) } catch (_: Exception) {}
    }

    private companion object {
        const val TAG = "OpenScribeNsd"
    }
}
