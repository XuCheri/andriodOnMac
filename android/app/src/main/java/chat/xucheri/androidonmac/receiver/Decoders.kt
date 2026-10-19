package chat.xucheri.androidonmac.receiver

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Surface
import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Codec work never runs on the main/network threads. Queues have a strict size limit. */
class DecoderPipeline(
    private val surface: Surface,
    private val onFirstFrame: () -> Unit,
    private val onVideoSize: (Int, Int) -> Unit,
    private val onNeedKeyframe: () -> Unit,
    private val onFailure: (String) -> Unit
) : AutoCloseable {
    private sealed class Item { data class Config(val json: JSONObject) : Item(); data class Unit(val frame: WireFrame) : Item() }
    private val running = AtomicBoolean(true)
    private val videoQueue = ArrayBlockingQueue<Item>(12)
    private val audioQueue = ArrayBlockingQueue<Item>(24)
    private val needsKeyframe = AtomicBoolean(true)
    private val first = AtomicBoolean(false)
    @Volatile var renderedFrames: Long = 0; private set
    val queueDepth get() = videoQueue.size
    @Volatile private var muted = false
    @Volatile private var track: AudioTrack? = null
    private val videoThread = Thread({ videoLoop() }, "ReceiverVideo").apply { start() }
    private val audioThread = Thread({ audioLoop() }, "ReceiverAudio").apply { start() }

    fun config(json: JSONObject) {
        val queue = if (json.optString("type") == "videoConfig") videoQueue else audioQueue
        queue.clear()
        if (queue === videoQueue) needsKeyframe.set(true)
        queue.offer(Item.Config(json))
    }
    fun accept(frame: WireFrame) {
        if (!running.get()) return
        if (frame.kind == WireFrame.VIDEO) {
            if (needsKeyframe.get() && !frame.keyFrame) return
            if (frame.keyFrame) needsKeyframe.set(false)
            if (!videoQueue.offer(Item.Unit(frame))) {
                // Do not discard configuration; drain queued access units and await a new IDR.
                videoQueue.removeIf { it is Item.Unit }
                needsKeyframe.set(true); onNeedKeyframe()
            }
        } else if (frame.kind == WireFrame.AUDIO) {
            if (!audioQueue.offer(Item.Unit(frame))) audioQueue.removeIf { it is Item.Unit }
        }
    }
    fun setMuted(value: Boolean) { muted = value; runCatching { track?.setVolume(if (value) 0f else 1f) } }
    override fun close() {
        if (!running.getAndSet(false)) return
        videoQueue.clear(); audioQueue.clear(); videoThread.interrupt(); audioThread.interrupt()
    }
    /** Called only by the session worker before attaching a replacement decoder. */
    fun awaitReleased(timeoutMillis: Long): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        return try {
            for (thread in arrayOf(videoThread, audioThread)) {
                val remaining = ((deadline - System.nanoTime()) / 1_000_000).coerceAtLeast(0)
                if (thread.isAlive && remaining > 0) thread.join(remaining)
            }
            !videoThread.isAlive && !audioThread.isAlive
        } catch (_: InterruptedException) { false }
    }
    private fun fail(message: String) { if (running.getAndSet(false)) onFailure(message) }
    private fun release(codec: MediaCodec?) { if (codec != null) { runCatching { codec.stop() }; runCatching { codec.release() } } }
    private fun videoLoop() {
        var codec: MediaCodec? = null
        val info = MediaCodec.BufferInfo()
        try {
            while (running.get()) {
                when (val item = videoQueue.poll(8, TimeUnit.MILLISECONDS)) {
                    is Item.Config -> {
                        release(codec); codec = null
                        val j = item.json
                        if (j.optString("codec") != "h264") throw ProtocolException("Mac 发送的视频编码不受支持")
                        val width = j.getInt("width"); val height = j.getInt("height")
                        if (width !in 16..8192 || height !in 16..8192 || width.toLong() * height > 34_000_000)
                            throw ProtocolException("视频尺寸不受支持")
                        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                            setByteBuffer("csd-0", ByteBuffer.wrap(decodeConfig(j.getString("csd0"))))
                            setByteBuffer("csd-1", ByteBuffer.wrap(decodeConfig(j.getString("csd1"))))
                            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, WireFrame.MAX_BODY)
                        }
                        val candidates = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter {
                            !it.isEncoder && it.supportedTypes.any { mime -> mime.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) }
                        }.sortedByDescending { it.isHardwareAccelerated }
                        val chosen = candidates.firstOrNull { runCatching { it.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).isFormatSupported(format) }.getOrDefault(false) }
                            ?: throw ProtocolException("手机没有兼容的视频解码器")
                        if (chosen.isHardwareAccelerated && chosen.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                                .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                        }
                        codec = MediaCodec.createByCodecName(chosen.name)
                        codec.configure(format, surface, null, 0)
                        codec.setOnFrameRenderedListener({ _, _, _ ->
                            if (running.get()) {
                                renderedFrames++
                                if (first.compareAndSet(false, true)) onFirstFrame()
                            }
                        }, Handler(Looper.getMainLooper()))
                        codec.start(); onVideoSize(width, height)
                    }
                    is Item.Unit -> {
                        val decoder = codec ?: continue
                        var index = decoder.dequeueInputBuffer(0)
                        if (index < 0) { drainVideo(decoder, info); index = decoder.dequeueInputBuffer(8000) }
                        if (index >= 0) {
                            val buffer = decoder.getInputBuffer(index) ?: throw ProtocolException("视频解码缓冲不可用")
                            if (item.frame.payload.size > buffer.capacity()) throw ProtocolException("视频帧超过解码能力")
                            buffer.clear(); buffer.put(item.frame.payload)
                            decoder.queueInputBuffer(index, 0, item.frame.payload.size, item.frame.pts, 0)
                        } else {
                            needsKeyframe.set(true); videoQueue.removeIf { it is Item.Unit }; onNeedKeyframe()
                        }
                    }
                    null -> Unit
                }
                codec?.let { drainVideo(it, info) }
            }
        } catch (_: InterruptedException) { /* session closed */ }
        catch (_: Exception) { fail("视频解码失败，请在 Mac 降低分辨率后重试") }
        finally { release(codec) }
    }
    private fun drainVideo(codec: MediaCodec, info: MediaCodec.BufferInfo) {
        while (running.get()) {
            val index = codec.dequeueOutputBuffer(info, 0)
            if (index >= 0) codec.releaseOutputBuffer(index, true)
            else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val f = codec.outputFormat
                val width = if (f.containsKey("crop-right") && f.containsKey("crop-left")) f.getInteger("crop-right") - f.getInteger("crop-left") + 1 else f.getInteger(MediaFormat.KEY_WIDTH)
                val height = if (f.containsKey("crop-bottom") && f.containsKey("crop-top")) f.getInteger("crop-bottom") - f.getInteger("crop-top") + 1 else f.getInteger(MediaFormat.KEY_HEIGHT)
                onVideoSize(width, height)
            } else break
        }
    }
    private fun audioLoop() {
        var codec: MediaCodec? = null
        val info = MediaCodec.BufferInfo()
        try {
            while (running.get()) {
                when (val item = audioQueue.poll(8, TimeUnit.MILLISECONDS)) {
                    is Item.Config -> {
                        release(codec); codec = null; closeTrack()
                        val j = item.json
                        if (j.optString("codec") != "aac") throw ProtocolException("音频编码不受支持")
                        val rate = j.getInt("sampleRate"); val channels = j.getInt("channels")
                        if (rate !in 8000..96000 || channels !in 1..2) throw ProtocolException("音频参数不受支持")
                        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, channels).apply {
                            setByteBuffer("csd-0", ByteBuffer.wrap(decodeConfig(j.getString("csd"))))
                            setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                        }
                        codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                        codec.configure(format, null, null, 0); codec.start()
                    }
                    is Item.Unit -> {
                        val decoder = codec ?: continue
                        drainAudio(decoder, info)
                        val index = decoder.dequeueInputBuffer(8000)
                        if (index >= 0) {
                            val buffer = decoder.getInputBuffer(index) ?: continue
                            if (item.frame.payload.size > buffer.capacity()) throw ProtocolException("音频帧过大")
                            buffer.clear(); buffer.put(item.frame.payload)
                            decoder.queueInputBuffer(index, 0, item.frame.payload.size, item.frame.pts, 0)
                        }
                    }
                    null -> Unit
                }
                codec?.let { drainAudio(it, info) }
            }
        } catch (_: InterruptedException) { }
        catch (_: Exception) { fail("声音解码失败，请在 Mac 关闭声音后重试") }
        finally { release(codec); closeTrack() }
    }
    private fun drainAudio(codec: MediaCodec, info: MediaCodec.BufferInfo) {
        while (running.get()) {
            val index = codec.dequeueOutputBuffer(info, 0)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                closeTrack()
                val f = codec.outputFormat
                val rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                val encoding = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) f.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                val mask = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
                val min = AudioTrack.getMinBufferSize(rate, mask, encoding)
                if (min <= 0) throw ProtocolException("音频输出不可用")
                track = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                    .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setChannelMask(mask).setEncoding(encoding).build())
                    .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(min * 2)
                    .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY).build().also {
                        it.setVolume(if (muted) 0f else 1f); it.play()
                    }
            } else if (index >= 0) {
                try {
                    val output = codec.getOutputBuffer(index)
                    if (output != null && info.size > 0) {
                        output.position(info.offset); output.limit(info.offset + info.size)
                        val sink = track
                        while (output.hasRemaining() && running.get() && sink != null) {
                            val n = sink.write(output, output.remaining(), AudioTrack.WRITE_NON_BLOCKING)
                            if (n < 0) throw ProtocolException("音频输出失败")
                            if (n == 0) Thread.sleep(3)
                        }
                    }
                } finally { codec.releaseOutputBuffer(index, false) }
            } else break
        }
    }
    private fun closeTrack() { val old = track; track = null; runCatching { old?.pause() }; runCatching { old?.flush() }; runCatching { old?.release() } }
    private fun decodeConfig(value: String): ByteArray {
        if (value.length > 65536) throw ProtocolException("编码配置过大")
        return Base64.decode(value, Base64.DEFAULT).also { if (it.isEmpty()) throw ProtocolException("编码配置为空") }
    }
}
