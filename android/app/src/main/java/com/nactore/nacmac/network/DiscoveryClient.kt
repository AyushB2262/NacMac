package com.nactore.nacmac.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket

class DiscoveryClient(
    private val context: Context,
    private val onMacDiscovered: (ip: String, port: Int) -> Unit
) {
    private val TAG = "NacMac-Discovery"
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val primaryServiceType = "_nacmac._tcp."
    private var isDiscovering = false

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(regType: String) {
            Log.d(TAG, "mDNS discovery started: $regType")
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            Log.d(TAG, "mDNS service found: ${serviceInfo.serviceName}")
            if (serviceInfo.serviceType.contains("nacmac")) {
                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        Log.e(TAG, "Resolve failed for service: $errorCode")
                    }

                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        val host = resolved.host.hostAddress ?: return
                        val port = resolved.port
                        Log.d(TAG, "Mac resolved via mDNS: $host:$port")
                        onMacDiscovered(host, port)
                    }
                })
            }
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            Log.d(TAG, "Service lost: ${serviceInfo.serviceName}")
        }

        override fun onDiscoveryStopped(serviceType: String) {
            isDiscovering = false
            Log.d(TAG, "Discovery stopped")
        }

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            isDiscovering = false
            Log.e(TAG, "Start discovery failed: $errorCode")
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Stop discovery failed: $errorCode")
        }
    }

    fun startDiscovery() {
        if (!isDiscovering) {
            try {
                nsdManager.discoverServices(primaryServiceType, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
                isDiscovering = true
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start mDNS: ${e.message}")
            }
        }
    }

    fun stopDiscovery() {
        if (isDiscovering) {
            try {
                nsdManager.stopServiceDiscovery(discoveryListener)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop mDNS: ${e.message}")
            }
            isDiscovering = false
        }
    }

    suspend fun probeDirectIp(ip: String, port: Int): Boolean = withContext(Dispatchers.IO) {
        try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(ip, port), 1500)
                Log.d(TAG, "Direct TCP probe to $ip:$port succeeded!")
                true
            }
        } catch (e: Exception) {
            false
        }
    }
}
