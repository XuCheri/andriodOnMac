package chat.xucheri.androidonmac.receiver

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address
import java.util.ArrayDeque

/** A bounded discovery operation. Cancelling can never connect a stale result. */
class LanDiscovery(context: Context, private val saved: Bootstrap, private val result: (Bootstrap?, String) -> Unit) : AutoCloseable {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var closed = false
    private var started = false
    private var resolving = false
    private val queue = ArrayDeque<NsdServiceInfo>()
    private val seen = mutableSetOf<String>()
    private val timeout = Runnable { finish(null, "未找到原来的 Mac，请确认已开始共享且处于同一 Wi-Fi，也可重新扫码") }
    private val listener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) { main.post { if (closed) runCatching { manager.stopServiceDiscovery(this) } } }
        override fun onServiceFound(info: NsdServiceInfo) { main.post {
            if (!closed && info.serviceType.trimEnd('.') == TYPE.trimEnd('.') && seen.size < 32 && seen.add(info.serviceName)) {
                queue.add(info); resolveNext()
            }
        } }
        override fun onServiceLost(info: NsdServiceInfo) = Unit
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { main.post { finish(null, "局域网发现暂不可用，请重新扫码连接") } }
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
    }
    fun start() {
        if (closed || started) return
        started = true
        try { manager.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, listener); main.postDelayed(timeout, 8000) }
        catch (_: Exception) { finish(null, "无法发现局域网设备，请重新扫码连接") }
    }
    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (closed || resolving || queue.isEmpty()) return
        resolving = true
        val service = queue.removeFirst()
        try {
            manager.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) { main.post { resolving = false; resolveNext() } }
                override fun onServiceResolved(info: NsdServiceInfo) { main.post {
                    if (closed) return@post
                    resolving = false
                    val hosts = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
                    val host = (hosts.firstOrNull { it is Inet4Address } ?: hosts.firstOrNull())?.hostAddress
                    val endpoint = host?.let { DiscoveredIdentity.endpoint(saved, it, info.port, info.attributes) }
                    if (endpoint != null) finish(endpoint, "") else resolveNext()
                } }
            })
        } catch (_: Exception) { resolving = false; resolveNext() }
    }
    private fun finish(endpoint: Bootstrap?, error: String) {
        if (closed) return
        close(); result(endpoint, error)
    }
    override fun close() {
        if (closed) return
        closed = true; main.removeCallbacks(timeout); queue.clear()
        if (started) runCatching { manager.stopServiceDiscovery(listener) }
    }
    companion object { private const val TYPE = "_aom-display._tcp." }
}
