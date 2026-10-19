package chat.xucheri.androidonmac.receiver

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.net.Inet6Address
import java.net.InetAddress

class ProtocolException(message: String) : IOException(message)
class IdentityException(message: String) : IOException(message)

/** All lengths are validated before allocation. A short read is always a failed frame. */
data class WireFrame(val kind: Int, val pts: Long, val flags: Int, val payload: ByteArray) {
    val keyFrame: Boolean get() = flags and 1 != 0
    fun json(): JSONObject {
        if (kind != JSON) throw ProtocolException("控制消息格式不正确")
        return try {
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(payload)).toString()
            JSONObject(text)
        }
        catch (_: Exception) { throw ProtocolException("控制消息无法解析") }
    }
    companion object {
        const val JSON = 1
        const val VIDEO = 2
        const val AUDIO = 3
        const val MAX_BODY = 8 * 1024 * 1024
        const val MAX_JSON = 65536
        fun read(input: InputStream): WireFrame {
            val source = DataInputStream(input)
            val length = source.readInt().toLong() and 0xffffffffL
            if (length !in 10L..MAX_BODY.toLong()) throw ProtocolException("消息长度不正确")
            val kind = source.readUnsignedByte()
            if (kind !in JSON..AUDIO) throw ProtocolException("不支持的消息类型")
            val pts = source.readLong()
            val flags = source.readUnsignedByte()
            if (pts < 0 || flags and 0xfe != 0) throw ProtocolException("消息头不正确")
            val count = length.toInt() - 10
            if (kind == JSON && count > MAX_JSON) throw ProtocolException("控制消息过大")
            val payload = ByteArray(count)
            source.readFully(payload)
            return WireFrame(kind, pts, flags, payload)
        }
        fun writeJSON(output: OutputStream, json: JSONObject) {
            val bytes = json.toString().toByteArray(Charsets.UTF_8)
            if (bytes.size > MAX_JSON) throw ProtocolException("控制消息过大")
            DataOutputStream(output).apply {
                writeInt(bytes.size + 10); writeByte(JSON); writeLong(0); writeByte(0)
                write(bytes); flush()
            }
        }
    }
}

data class Bootstrap(val host: String, val port: Int, val fingerprint: String, val pairToken: String?) {
    fun withoutToken() = copy(pairToken = null)
    companion object {
        fun parse(raw: String): Bootstrap {
            if (raw.toByteArray(Charsets.UTF_8).size > 8192) throw ProtocolException("连接二维码过大")
            val decoded = if (raw.startsWith("aom:")) {
                try { java.util.Base64.getUrlDecoder().decode(raw.substring(4)).toString(Charsets.UTF_8) }
                catch (_: IllegalArgumentException) { throw ProtocolException("USB 连接信息无效") }
            } else raw
            val value = try { JSONObject(decoded) } catch (_: Exception) { throw ProtocolException("请扫描 Mac 显示的连接二维码") }
            if (value.opt("v") !is Number || value.optDouble("v") != 1.0) throw ProtocolException("连接协议版本不兼容")
            val host = value.optString("host").removeSurrounding("[", "]")
            if (!validHost(host)) throw ProtocolException("连接地址无效")
            val port = value.optInt("port", 0)
            if (value.opt("port") !is Number || value.optDouble("port") != port.toDouble() || port !in 1..65535) throw ProtocolException("连接端口无效")
            val pin = value.optString("fingerprint").lowercase()
            if (!pin.matches(Regex("[0-9a-f]{64}"))) throw ProtocolException("证书指纹无效")
            val token = value.optString("pairToken").takeIf { it.isNotEmpty() }
            if (token != null && (token.length !in 16..512 || token.any { it.isWhitespace() || it.code < 32 }))
                throw ProtocolException("配对信息无效")
            return Bootstrap(host, port, pin, token)
        }
        fun validHost(host: String): Boolean {
            if (host.length !in 1..253 || host.startsWith('-')) return false
            if (host.contains(':')) {
                val parts = host.split('%')
                if (parts.size > 2 || (parts.size == 2 && !parts[1].matches(Regex("[A-Za-z0-9_.-]{1,32}")))) return false
                if (!parts[0].all { it in "0123456789abcdefABCDEF:" || it == '.' }) return false
                return runCatching { InetAddress.getByName(parts[0]) is Inet6Address }.getOrDefault(false)
            }
            if (!host.all { it.isLetterOrDigit() && it.code < 128 || it in ".-" }) return false
            if (host.all { it.isDigit() || it == '.' }) {
                val parts = host.split('.')
                return parts.size == 4 && parts.all { it.isNotEmpty() && (it.length == 1 || it[0] != '0') && (it.toIntOrNull() ?: -1) in 0..255 }
            }
            return host.split('.').all { it.length in 1..63 && !it.startsWith('-') && !it.endsWith('-') }
        }
    }
}

object CertificatePin {
    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    fun matches(expected: String, der: ByteArray): Boolean = MessageDigest.isEqual(
        expected.lowercase().toByteArray(Charsets.US_ASCII), sha256(der).toByteArray(Charsets.US_ASCII))
}

/** Retry budget is reset only when a decoded frame actually reaches the Surface. */
class RecoveryPolicy {
    private var attempts = 0
    private var stopped = false
    fun rendered() { attempts = 0 }
    fun stop() { stopped = true }
    fun nextDelayMillis(): Long? = if (stopped || attempts >= 3) null else longArrayOf(1000, 2000, 4000)[attempts++]
}

data class ContentPoint(val x: Double, val y: Double)
object ContentCoordinates {
    fun point(x: Float, y: Float, width: Int, height: Int): ContentPoint? {
        if (width <= 0 || height <= 0 || !x.isFinite() || !y.isFinite() || x < 0 || y < 0 || x > width || y > height) return null
        return ContentPoint((x / width).toDouble().coerceIn(0.0, 1.0), (y / height).toDouble().coerceIn(0.0, 1.0))
    }
}

/** Approval, peer liveness, and first presentation are three independent deadlines. */
class SessionWatchdog(private val connectedAt: Long) {
    enum class Failure { PAIRING_TIMEOUT, CONTROL_TIMEOUT, FIRST_FRAME_TIMEOUT }
    private var lastControlAt = connectedAt
    private var mediaStartedAt: Long? = null
    private var firstRendered = false
    fun controlReceived(now: Long) { lastControlAt = now }
    fun paired(now: Long) { mediaStartedAt = now; lastControlAt = now }
    fun rendered() { firstRendered = true }
    fun expired(now: Long): Failure? {
        val mediaStart = mediaStartedAt ?: return if (now - connectedAt >= 120_000) Failure.PAIRING_TIMEOUT else null
        if (now - lastControlAt >= 8_000) return Failure.CONTROL_TIMEOUT
        if (!firstRendered && now - mediaStart >= 30_000) return Failure.FIRST_FRAME_TIMEOUT
        return null
    }
}


object DiscoveredIdentity {
    /** mDNS names are display data. Only the saved certificate identity selects a peer. */
    fun endpoint(saved: Bootstrap, host: String, port: Int, attributes: Map<String, ByteArray>): Bootstrap? {
        val pin = attributes["fingerprint"]?.toString(Charsets.US_ASCII) ?: return null
        val version = attributes["v"]?.toString(Charsets.US_ASCII) ?: return null
        if (version != "1" || pin != saved.fingerprint || port !in 1..65535 || !Bootstrap.validHost(host)) return null
        if (isUSB(host)) return null
        return saved.copy(host = host, port = port, pairToken = null)
    }
    fun isUSB(host: String): Boolean = host == "127.0.0.1" || host == "::1" || host.equals("localhost", true)
}
