package chat.xucheri.androidonmac.receiver

import android.os.Build
import android.os.SystemClock
import android.view.Surface
import org.json.JSONObject
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

interface SessionListener {
    fun onState(message: String, connected: Boolean, generation: Long)
    fun onSize(width: Int, height: Int, generation: Long)
    fun onEnded(message: String)
}

/** One instance owns one explicit user session; no callback can migrate to another identity. */
class ReceiverSession(
    private val endpoint: Bootstrap,
    private val store: PairStore,
    surface: Surface,
    private val listener: SessionListener
) {
    private val stopped = AtomicBoolean(false)
    private val policy = RecoveryPolicy()
    private val surfaceLock = Object()
    private val surfaces = SurfaceRecoveryPolicy()
    private var currentSurface: Surface? = surface
    @Volatile private var attempt: Attempt? = null
    @Volatile private var muted = false
    private val worker = Thread({ runSession() }, "ReceiverSession")
    fun start() { worker.start() }
    fun acceptsGeneration(value: Long): Boolean = synchronized(surfaceLock) { !stopped.get() && surfaces.accepts(value) }
    fun surfaceLost() {
        val previous = synchronized(surfaceLock) {
            if (stopped.get()) return
            currentSurface = null
            surfaces.lost(SystemClock.elapsedRealtime())
            surfaceLock.notifyAll()
            attempt
        }
        previous?.loseSurface()
    }
    fun surfaceAvailable(surface: Surface) = synchronized(surfaceLock) {
        if (!stopped.get() && surfaces.available(SystemClock.elapsedRealtime())) currentSurface = surface
        surfaceLock.notifyAll()
    }
    fun input(json: JSONObject) { attempt?.let { if (it.readyForInput) it.send(json) } }
    fun setMuted(value: Boolean) { muted = value; attempt?.decoder?.setMuted(value) }
    @Synchronized fun stop() {
        if (!stopped.compareAndSet(false, true)) return
        synchronized(surfaceLock) { surfaces.stop(); currentSurface = null; surfaceLock.notifyAll() }
        synchronized(policy) { policy.stop() }
        // Best effort stop is written by the owning writer before its sockets close.
        attempt?.stopGracefully()
        worker.interrupt()
    }
    private fun runSession() {
        var error = "连接已结束"
        while (!stopped.get()) {
            val current = try { awaitSurfaceAttempt() }
            catch (_: InterruptedException) { break }
            catch (_: SurfaceTimeout) { error = "显示区域未能及时恢复，请在 Mac 重新开始共享"; break }
            try {
                listener.onState("正在连接 Mac…", false, current.generation)
                current.run()
                error = "Mac 已结束共享"
                break
            } catch (e: Exception) {
                error = when (e) {
                    is SurfaceLost -> "显示区域正在重建，等待恢复…"
                    is DecoderFailure -> e.message ?: "画面解码中断，请重试"
                    is IdentityException -> e.message ?: "连接身份无法验证，请重新配对"
                    is RemoteStop -> e.message ?: "Mac 已结束共享"
                    is ProtocolException -> e.message ?: "两端协议不兼容"
                    else -> "连接中断，请检查 Mac 共享状态和 USB／Wi-Fi"
                }
                if (stopped.get() || e is IdentityException || e is RemoteStop || e is ProtocolException) break
            } finally {
                synchronized(surfaceLock) {
                    surfaces.finishAttempt(current.generation)
                    if (attempt === current) attempt = null
                }
                current.close()
            }
            if (!current.awaitDecoderRelease()) { error = "旧画面未能及时释放，请重新打开接收端"; break }
            val delay = synchronized(policy) { policy.nextDelayMillis() } ?: break
            val generation = synchronized(surfaceLock) { surfaces.generation }
            listener.onState("连接中断，${delay / 1000} 秒后重试…", false, generation)
            try { Thread.sleep(delay) } catch (_: InterruptedException) { break }
        }
        if (!stopped.getAndSet(true)) listener.onEnded(error)
    }
    private fun awaitSurfaceAttempt(): Attempt = synchronized(surfaceLock) {
        while (!stopped.get()) {
            val now = SystemClock.elapsedRealtime()
            when (surfaces.state(now)) {
                SurfaceRecoveryPolicy.State.STOPPED -> throw InterruptedException()
                SurfaceRecoveryPolicy.State.EXPIRED -> throw SurfaceTimeout()
                SurfaceRecoveryPolicy.State.WAITING -> surfaceLock.wait(surfaces.remainingMillis(now))
                SurfaceRecoveryPolicy.State.READY -> {
                    val target = currentSurface
                    if (target == null || !target.isValid) {
                        currentSurface = null; surfaces.lost(now)
                    } else {
                        val generation = surfaces.beginAttempt(now) ?: continue
                        return@synchronized Attempt(target, generation).also { attempt = it }
                    }
                }
            }
        }
        throw InterruptedException()
    }
    private class RemoteStop(message: String) : IOException(message)
    private class SurfaceLost : IOException("Surface replaced")
    private class SurfaceTimeout : IOException("Surface recovery timed out")
    // A codec may report a destroyed Surface before the main-thread callback arrives.
    // Treat this as a bounded recoverable failure, not a terminal wire-protocol error.
    private class DecoderFailure(message: String) : IOException(message)

    private inner class Attempt(private val surface: Surface, val generation: Long) {
        private val open = AtomicBoolean(true)
        private val outgoing = ArrayBlockingQueue<JSONObject>(128)
        private val sockets = mutableListOf<Socket>()
        @Volatile var decoder: DecoderPipeline? = null
        @Volatile private var retiredDecoder: DecoderPipeline? = null
        @Volatile private var problem: Exception? = null
        @Volatile private var firstFrame = false
        private var watchdog: SessionWatchdog? = null
        val readyForInput get() = open.get() && firstFrame && acceptsGeneration(generation)
        private var writer: Thread? = null
        private var media: Thread? = null
        private var heartbeat: Thread? = null
        fun send(json: JSONObject) {
            if (open.get() && !outgoing.offer(json)) fail(IOException("控制通道繁忙"))
        }
        fun run() {
            val control = connect()
            control.soTimeout = 120_000 // Approval is an explicit user action, not a missing heartbeat.
            synchronized(this) { watchdog = SessionWatchdog(SystemClock.elapsedRealtime()) }
            val saved = store.load()?.takeIf { it.endpoint.fingerprint == endpoint.fingerprint }
            val token = saved?.authToken
            val hello = hello("control")
            if (token != null) hello.put("authToken", token)
            else if (endpoint.pairToken != null) hello.put("pairToken", endpoint.pairToken)
            else throw IdentityException("请在 Mac 重新生成二维码配对")
            val output = control.outputStream
            WireFrame.writeJSON(output, hello)
            writer = Thread({
                try {
                    while (open.get()) {
                        val message = outgoing.poll(200, TimeUnit.MILLISECONDS) ?: continue
                        WireFrame.writeJSON(output, message)
                        if (message.optString("type") == "stop") { close(); break }
                    }
                } catch (_: InterruptedException) { } catch (e: Exception) { fail(e) }
            }, "ReceiverControlWrite").apply { start() }
            heartbeat = Thread({
                try {
                    var statsTime = 0L
                    while (open.get()) {
                        send(JSONObject().put("type", "ping"))
                        val expired = synchronized(this) { watchdog?.expired(SystemClock.elapsedRealtime()) }
                        if (expired != null) throw IOException("连接等待超时")
                        val pipeline = decoder
                        if (pipeline != null && SystemClock.elapsedRealtime() - statsTime >= 1000) {
                            send(JSONObject().put("type", "stats").put("frames", pipeline.renderedFrames).put("queueDepth", pipeline.queueDepth))
                            statsTime = SystemClock.elapsedRealtime()
                        }
                        Thread.sleep(2000)
                    }
                } catch (_: InterruptedException) { } catch (e: Exception) { fail(e) }
            }, "ReceiverHeartbeat").apply { start() }
            listener.onState("等待 Mac 确认并发送画面…", false, generation)
            try {
                while (open.get() && !stopped.get()) {
                    val message = WireFrame.read(control.inputStream).json()
                    synchronized(this) { watchdog?.controlReceived(SystemClock.elapsedRealtime()) }
                    when (message.optString("type")) {
                        "paired" -> {
                            if (media != null) throw ProtocolException("重复的配对响应")
                            val auth = message.optString("authToken")
                            val sessionID = message.optString("sessionID")
                            if (auth.length !in 16..4096 || sessionID.length !in 1..128) throw ProtocolException("配对响应无效")
                            synchronized(this@ReceiverSession) {
                                if (!open.get() || stopped.get()) throw IOException("已停止")
                                store.save(endpoint, auth)
                            }
                            control.soTimeout = 8000
                            synchronized(this) { watchdog?.paired(SystemClock.elapsedRealtime()) }
                            startMedia(auth, sessionID)
                        }
                        "ping" -> send(JSONObject().put("type", "pong"))
                        "pong" -> Unit
                        "stop", "stopped" -> throw RemoteStop("Mac 已停止共享")
                        "error" -> throw RemoteStop(message.optString("message", "Mac 拒绝了连接").take(256))
                        else -> throw ProtocolException("不支持的控制消息")
                    }
                }
                problem?.let { throw it }
            } catch (e: Exception) { throw problem ?: e }
        }
        private fun hello(channel: String) = JSONObject().put("type", "hello").put("protocolVersion", 1)
            .put("channel", channel).put("deviceID", store.deviceID).put("deviceName", "${Build.MANUFACTURER} ${Build.MODEL}".take(128))
        @Synchronized private fun startMedia(auth: String, sessionID: String) {
            if (!open.get() || stopped.get()) throw problem ?: IOException("已停止")
            decoder = DecoderPipeline(surface,
                onFirstFrame = {
                    val accepted = synchronized(surfaceLock) {
                        if (!open.get() || stopped.get() || !surfaces.accepts(generation)) false
                        else {
                            firstFrame = true
                            synchronized(this) { watchdog?.rendered() }
                            synchronized(policy) { policy.rendered() }
                            true
                        }
                    }
                    if (accepted) {
                        send(JSONObject().put("type", "firstFrame"))
                        listener.onState("已连接 · 画面已就绪", true, generation)
                    }
                }, onVideoSize = { w, h -> if (open.get() && !stopped.get()) listener.onSize(w, h, generation) },
                onNeedKeyframe = { send(JSONObject().put("type", "requestKeyFrame")) },
                onFailure = { fail(DecoderFailure(it)) }).also { it.setMuted(muted) }
            media = Thread({
                try {
                    val connection = connect()
                    // Static desktops may emit no video; only control heartbeat determines liveness.
                    // Closing the owning attempt always unblocks this read.
                    connection.soTimeout = 0
                    WireFrame.writeJSON(connection.outputStream, hello("media").put("authToken", auth).put("sessionID", sessionID))
                    while (open.get() && !stopped.get()) {
                        val frame = WireFrame.read(connection.inputStream)
                        if (frame.kind == WireFrame.JSON) {
                            val json = frame.json()
                            when (json.optString("type")) {
                                "videoConfig", "audioConfig" -> decoder?.config(json)
                                "stop", "stopped" -> throw RemoteStop("Mac 已停止共享")
                                "error" -> throw RemoteStop(json.optString("message", "Mac 共享失败").take(256))
                                else -> throw ProtocolException("不支持的媒体配置")
                            }
                        } else decoder?.accept(frame)
                    }
                } catch (e: Exception) { fail(e) }
            }, "ReceiverMedia").apply { start() }
        }
        private fun connect(): SSLSocket {
            val raw = Socket()
            synchronized(sockets) { if (!open.get() || stopped.get()) { raw.close(); throw IOException("已停止") }; sockets.add(raw) }
            raw.tcpNoDelay = true
            raw.connect(InetSocketAddress(endpoint.host, endpoint.port), 5000)
            raw.soTimeout = 8000
            val trust = object : X509TrustManager {
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) { throw java.security.cert.CertificateException("不支持客户端认证") }
                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                    if (chain.isEmpty() || !CertificatePin.matches(endpoint.fingerprint, chain[0].encoded))
                        throw java.security.cert.CertificateException("Mac 证书与配对指纹不符")
                    chain[0].checkValidity()
                }
            }
            val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
            val tls = context.socketFactory.createSocket(raw, endpoint.host, endpoint.port, true) as SSLSocket
            synchronized(sockets) { if (!open.get() || stopped.get()) { tls.close(); throw IOException("已停止") }; sockets.add(tls) }
            tls.enabledProtocols = tls.supportedProtocols.filter { it == "TLSv1.2" || it == "TLSv1.3" }.toTypedArray()
            tls.soTimeout = 8000
            try { tls.startHandshake() } catch (_: SSLHandshakeException) { throw IdentityException("Mac 证书无法验证，请检查时间或重新配对") }
            return tls
        }
        @Synchronized private fun fail(error: Exception) { if (open.get()) { problem = error; close() } }
        fun loseSurface() = fail(SurfaceLost())
        fun awaitDecoderRelease(): Boolean = retiredDecoder?.awaitReleased(2000) ?: true
        fun stopGracefully() {
            outgoing.clear()
            outgoing.offer(JSONObject().put("type", "stop"))
            // Bound cleanup even if a dead peer blocks a TLS write. This closes only this attempt.
            Thread({ try { Thread.sleep(150) } catch (_: InterruptedException) { }; close() }, "ReceiverStop").start()
        }
        @Synchronized fun close() {
            if (!open.getAndSet(false)) return
            retiredDecoder = decoder
            decoder?.close(); decoder = null
            synchronized(sockets) { sockets.forEach { runCatching { it.close() } }; sockets.clear() }
            writer?.interrupt(); media?.interrupt(); heartbeat?.interrupt()
            outgoing.clear()
        }
    }
}
