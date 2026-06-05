package com.royp.maccysync.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.royp.maccysync.core.Protocol

// Best-effort Bonjour/mDNS discovery of the Mac, used to refresh its address
// when the LAN IP changes. The QR-provided host is the primary path.
class NsdDiscovery(
  context: Context,
  private val onResolved: (host: String, port: Int) -> Unit
) {
  private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
  private var listener: NsdManager.DiscoveryListener? = null

  fun start() {
    if (listener != null) return
    val discoveryListener = object : NsdManager.DiscoveryListener {
      override fun onDiscoveryStarted(serviceType: String) {}
      override fun onServiceFound(service: NsdServiceInfo) {
        if (service.serviceType.contains("maccysync")) resolve(service)
      }
      override fun onServiceLost(service: NsdServiceInfo) {}
      override fun onDiscoveryStopped(serviceType: String) {}
      override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
      override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
    }
    listener = discoveryListener
    runCatching {
      nsd.discoverServices("${Protocol.BONJOUR_TYPE}.", NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }
  }

  private fun resolve(service: NsdServiceInfo) {
    nsd.resolveService(service, object : NsdManager.ResolveListener {
      override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
      override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
        val host = serviceInfo.host?.hostAddress ?: return
        onResolved(host, serviceInfo.port)
      }
    })
  }

  fun stop() {
    listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
    listener = null
  }
}
