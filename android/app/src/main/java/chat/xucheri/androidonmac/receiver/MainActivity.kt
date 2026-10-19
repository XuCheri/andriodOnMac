package chat.xucheri.androidonmac.receiver

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.IntentFilter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.pm.ActivityInfo
import android.os.Build
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.view.GestureDetector
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.google.zxing.integration.android.IntentIntegrator
import org.json.JSONObject

/** Native controls around a SurfaceView; foreground surface replacement preserves session identity. */
class MainActivity : Activity(), SurfaceHolder.Callback {
    private object Palette {
        val background = Color.rgb(16, 21, 29)
        val surface = Color.rgb(24, 36, 50)
        val text = Color.rgb(239, 244, 250)
        val secondary = Color.rgb(184, 198, 214)
        val accent = Color.rgb(124, 196, 255)
    }
    private lateinit var store: PairStore
    private lateinit var root: LinearLayout
    private lateinit var header: LinearLayout
    private lateinit var connectionControls: LinearLayout
    private lateinit var status: TextView
    private lateinit var display: FrameLayout
    private lateinit var surface: VideoSurfaceView
    private lateinit var empty: TextView
    private lateinit var fullscreenExit: Button
    private lateinit var controls: LinearLayout
    private lateinit var savedButton: Button
    private lateinit var keyboardButton: Button
    private lateinit var orientationButton: Button
    private lateinit var moreButton: Button
    private lateinit var remoteInput: RemoteInputView
    private var session: ReceiverSession? = null
    private var discovery: LanDiscovery? = null
    private var pending: Bootstrap? = null
    private var surfaceReady = false
    private var foreground = false
    private var videoWidth = 16
    private var videoHeight = 9
    private var muted = false
    private var audioFocus: AudioFocusRequest? = null
    private var lockReceiverRegistered = false
    private val lockReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) endSession("手机已锁屏，共享已停止")
        }
    }
    private var immersive = false
    private var dragging = false
    private var twoFinger = false
    private var lastScrollX = 0f
    private var lastScrollY = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = PairStore(this)
        buildUI()
        acceptIntent(intent)
    }
    override fun onStart() {
        super.onStart(); foreground = true
        if (!lockReceiverRegistered) {
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(lockReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF), Context.RECEIVER_NOT_EXPORTED)
            else registerReceiver(lockReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
            lockReceiverRegistered = true
        }
        startPending()
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); acceptIntent(intent) }
    override fun onStop() {
        Log.i("AOMReceiver", "Activity stopped; ending the user session")
        foreground = false
        if (lockReceiverRegistered) { unregisterReceiver(lockReceiver); lockReceiverRegistered = false }
        endSession("已暂停：返回后请重新连接")
        super.onStop()
    }
    override fun onDestroy() { session?.stop(); session = null; super.onDestroy() }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        updateOrientationButton()
        display.post { fitSurface() }
    }
    private fun buildUI() {
        root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Palette.background) }
        root.setOnApplyWindowInsetsListener { view, insets ->
            val safe = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            view.setPadding(safe.left + dp(12), safe.top + dp(8), safe.right + dp(12), safe.bottom + dp(8)); insets
        }
        setContentView(root)
        header = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        header.addView(label("Mac 画面", 24f).apply { setTypeface(typeface, Typeface.BOLD) })
        status = label("在 Mac 开始共享，再连接这台手机", 14f, Palette.secondary).apply { accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        header.addView(status); root.addView(header)
        connectionControls = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val connectRow = LinearLayout(this)
        connectRow.addView(button("扫描二维码") { scan() }, weighted())
        savedButton = button("连接已配对 Mac") {
            val saved = store.load()
            if (saved == null) status.text = "还没有配对，请先扫码或从 Mac 通过 USB 打开"
            else rediscover(saved.endpoint)
        }
        connectRow.addView(savedButton, weighted()); connectionControls.addView(connectRow)
        val moreRow = LinearLayout(this)
        moreRow.addView(button("USB 连接说明") {
            AlertDialog.Builder(this).setTitle("通过 USB 接收")
                .setMessage("用数据线连接 Mac，开启 Android 开发者选项中的 USB 调试，并允许这台 Mac。\n\n在 Mac 的“Mac → 手机”中选择设备并开始共享，接收端会自动打开。首次连接仍需在 Mac 确认。")
                .setPositiveButton("知道了", null).show()
        }, weighted())
        moreRow.addView(button("连接选项") { connectionOptions() }, weighted()); connectionControls.addView(moreRow)
        root.addView(connectionControls)
        display = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surface = VideoSurfaceView(this).apply {
            holder.addCallback(this@MainActivity)
            contentDescription = "Mac 画面，轻点点击，拖动移动，双指滚动，长按右键"
        }
        display.addView(surface, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        remoteInput = RemoteInputView(this).apply {
            onText = { value ->
                session?.input(JSONObject().put("type", "input").put("action", "text").put("text", value))
            }
            onKey = { key -> sendKey(key) }
        }
        display.addView(remoteInput, FrameLayout.LayoutParams(1, 1))
        empty = label("等待 Mac 画面\n\nUSB 或同一 Wi-Fi 均可连接\n画面仅在本地设备之间传输", 16f, Palette.secondary).apply {
            gravity = Gravity.CENTER; setPadding(dp(24), dp(24), dp(24), dp(24))
            setBackgroundColor(Palette.surface)
        }
        display.addView(empty, FrameLayout.LayoutParams(-1, -1))
        fullscreenExit = button("退出全屏") { toggleFullscreen() }.apply { visibility = View.GONE }
        display.addView(fullscreenExit, FrameLayout.LayoutParams(-2, dp(48), Gravity.TOP or Gravity.END))
        display.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> fitSurface() }
        root.addView(display, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dp(8); bottomMargin = dp(8) })
        buildTouch()
        controls = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val bar = LinearLayout(this)
        keyboardButton = button("键盘") { remoteInput.showKeyboard() }.apply { contentDescription = "打开手机键盘，直接输入到 Mac" }
        orientationButton = button("横屏") { toggleOrientation() }
        moreButton = button("更多") { sessionOptions() }.apply { contentDescription = "共享选项：全屏、声音、快捷键和停止" }
        bar.addView(keyboardButton, weighted()); bar.addView(orientationButton, weighted()); bar.addView(moreButton, weighted())
        controls.addView(bar)
        root.addView(controls)
        updateOrientationButton()
        updateEnabled(false)
    }
    @android.annotation.SuppressLint("ClickableViewAccessibility") // Confirmed taps call performClick from GestureDetector's delayed callback.
    private fun buildTouch() {
        var clickX = -1f
        var clickY = -1f
        surface.activate = { pointer("click", if (clickX >= 0) clickX else surface.width / 2f, if (clickY >= 0) clickY else surface.height / 2f) }
        val detector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent) = true
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean { if (!twoFinger) { clickX = e.x; clickY = e.y; surface.performClick() }; return true }
            override fun onDoubleTap(e: MotionEvent): Boolean { if (!twoFinger) pointer("doubleClick", e.x, e.y); return true }
            override fun onLongPress(e: MotionEvent) { if (!twoFinger && !dragging) pointer("rightClick", e.x, e.y) }
            override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
                if (twoFinger) return true
                if (!dragging && e1 != null) { dragging = true; pointer("down", e1.x, e1.y) }
                pointer("move", e2.x, e2.y); return true
            }
        })
        surface.setOnTouchListener { _, event ->
            if (session == null) return@setOnTouchListener true
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { twoFinger = false; dragging = false }
                MotionEvent.ACTION_POINTER_DOWN -> if (event.pointerCount >= 2) {
                    if (dragging) pointer("up", event.x, event.y)
                    dragging = false; twoFinger = true
                    lastScrollX = (event.getX(0) + event.getX(1)) / 2
                    lastScrollY = (event.getY(0) + event.getY(1)) / 2
                    val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
                    detector.onTouchEvent(cancel); cancel.recycle()
                }
                MotionEvent.ACTION_MOVE -> if (twoFinger && event.pointerCount >= 2) {
                    val x = (event.getX(0) + event.getX(1)) / 2; val y = (event.getY(0) + event.getY(1)) / 2
                    session?.input(JSONObject().put("type", "input").put("action", "scroll")
                        .put("dx", (x - lastScrollX).toDouble()).put("dy", (y - lastScrollY).toDouble()))
                    lastScrollX = x; lastScrollY = y
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) pointer("up", event.x.coerceIn(0f, surface.width.toFloat()), event.y.coerceIn(0f, surface.height.toFloat()))
                    dragging = false
                }
            }
            if (!twoFinger) detector.onTouchEvent(event)
            true
        }
    }
    private fun pointer(action: String, x: Float, y: Float) {
        val point = ContentCoordinates.point(x, y, surface.width, surface.height) ?: return
        session?.input(JSONObject().put("type", "input").put("action", action).put("x", point.x).put("y", point.y))
    }
    private fun sendKey(key: String) { session?.input(JSONObject().put("type", "input").put("action", "key").put("key", key)) }
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (::remoteInput.isInitialized && remoteInput.handleHardwareKey(event)) return true
        return super.dispatchKeyEvent(event)
    }
    private fun toggleOrientation() {
        remoteInput.hideKeyboard()
        requestedOrientation = if (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE)
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
    }
    private fun updateOrientationButton() {
        val next = if (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) "竖屏" else "横屏"
        orientationButton.text = next
        orientationButton.contentDescription = "将接收端切换为$next"
    }
    private fun sessionOptions() {
        remoteInput.hideKeyboard()
        val choices = arrayOf(if (immersive) "退出全屏" else "全屏", if (muted) "开启声音" else "关闭声音", "快捷键", "停止共享")
        AlertDialog.Builder(this).setTitle("共享选项").setItems(choices) { _, index ->
            when (index) {
                0 -> toggleFullscreen()
                1 -> { muted = !muted; session?.setMuted(muted); if (!muted) requestAudioFocus() }
                2 -> showShortcuts()
                3 -> endSession("已停止共享")
            }
        }.show()
    }
    private fun showShortcuts() {
        val shortcuts = listOf("Esc" to "escape", "Tab" to "tab", "回车" to "enter", "退格" to "backspace", "向后删除" to "delete",
            "复制 ⌘C" to "copy", "粘贴 ⌘V" to "paste", "剪切 ⌘X" to "cut", "撤销 ⌘Z" to "undo", "重做 ⇧⌘Z" to "redo", "全选 ⌘A" to "selectAll",
            "←" to "left", "↑" to "up", "↓" to "down", "→" to "right")
        AlertDialog.Builder(this).setTitle("Mac 快捷键").setItems(shortcuts.map { it.first }.toTypedArray()) { _, index ->
            sendKey(shortcuts[index].second)
        }.show()
    }
    private fun scan() {
        endSession("扫描 Mac 的连接二维码")
        IntentIntegrator(this).setDesiredBarcodeFormats(IntentIntegrator.QR_CODE).setPrompt("扫描 Mac 的连接二维码")
            .setBeepEnabled(false).setOrientationLocked(false).initiateScan()
    }
    @Deprecated("Activity result compatibility for the pinned scanner")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val result = IntentIntegrator.parseActivityResult(requestCode, resultCode, data)
        if (result != null) { result.contents?.let { parseAndConnect(it) }; return }
        super.onActivityResult(requestCode, resultCode, data)
    }
    private fun acceptIntent(intent: Intent?) {
        val raw = intent?.getStringExtra("connection") ?: return
        intent.removeExtra("connection")
        parseAndConnect(raw)
    }
    private fun parseAndConnect(raw: String) {
        try { connect(Bootstrap.parse(raw)) }
        catch (_: Exception) { status.text = "连接信息无效，请重新扫描 Mac 的二维码" }
    }
    private fun rediscover(saved: Bootstrap) {
        endSession("正在查找已配对的 Mac…")
        if (DiscoveredIdentity.isUSB(saved.host)) {
            status.text = "USB 连接请在 Mac 选择这台手机并开始共享"
            return
        }
        lateinit var operation: LanDiscovery
        operation = LanDiscovery(this, saved) { endpoint, message ->
            if (discovery !== operation) return@LanDiscovery
            discovery = null
            if (foreground && endpoint != null) connect(endpoint) else status.text = message
        }
        discovery = operation
        operation.start()
    }
    private fun connect(endpoint: Bootstrap) {
        endSession("正在准备连接…")
        pending = endpoint
        startPending()
    }
    private fun startPending() {
        if (!surfaceReady || !foreground) return
        val endpoint = pending ?: return
        pending = null
        lateinit var created: ReceiverSession
        created = ReceiverSession(endpoint, store, surface.holder.surface, object : SessionListener {
            override fun onState(message: String, connected: Boolean, generation: Long) = runOnUiThread {
                if (session !== created || !created.acceptsGeneration(generation)) return@runOnUiThread
                status.text = message; empty.text = message
                empty.visibility = if (connected) View.GONE else View.VISIBLE
                if (connected) requestAudioFocus()
                updateEnabled(connected)
            }
            override fun onSize(width: Int, height: Int, generation: Long) = runOnUiThread {
                if (session !== created || !created.acceptsGeneration(generation)) return@runOnUiThread
                videoWidth = width; videoHeight = height; fitSurface()
            }
            override fun onEnded(message: String) = runOnUiThread {
                if (session !== created) return@runOnUiThread
                session = null; showStopped(message)
            }
        })
        session = created; created.setMuted(muted)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        connectionControls.visibility = View.GONE
        updateEnabled(false)
        created.start()
    }
    private fun endSession(message: String) {
        pending = null
        discovery?.close(); discovery = null
        val previous = session; session = null; previous?.stop()
        if (::status.isInitialized) showStopped(message)
    }
    private fun showStopped(message: String) {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        audioFocus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }
        audioFocus = null
        remoteInput.stop()
        status.text = message; empty.text = "$message\n\n在 Mac 开始共享后连接"
        empty.visibility = View.VISIBLE
        connectionControls.visibility = View.VISIBLE
        if (immersive) toggleFullscreen()
        updateEnabled(false)
    }
    private fun updateEnabled(connected: Boolean) {
        savedButton.isEnabled = store.load() != null
        keyboardButton.isEnabled = connected
        orientationButton.isEnabled = session != null
        moreButton.isEnabled = session != null
        remoteInput.setRemoteEnabled(connected)
        controls.visibility = if (session != null && !immersive) View.VISIBLE else View.GONE
    }
    private fun fitSurface() {
        if (display.width <= 0 || display.height <= 0) return
        val scale = minOf(display.width.toDouble() / videoWidth, display.height.toDouble() / videoHeight)
        val width = (videoWidth * scale).toInt().coerceAtLeast(1)
        val height = (videoHeight * scale).toInt().coerceAtLeast(1)
        val current = surface.layoutParams
        if (current.width != width || current.height != height)
            surface.layoutParams = FrameLayout.LayoutParams(width, height, Gravity.CENTER)
    }
    private fun toggleFullscreen() {
        immersive = !immersive
        header.visibility = if (immersive) View.GONE else View.VISIBLE
        controls.visibility = if (immersive || session == null) View.GONE else View.VISIBLE
        fullscreenExit.visibility = if (immersive) View.VISIBLE else View.GONE
        display.post { fitSurface() }
    }
    private fun requestAudioFocus() {
        if (audioFocus != null || muted) return
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
            .setOnAudioFocusChangeListener { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    audioFocus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }
                    audioFocus = null
                    muted = true; session?.setMuted(true)
                }
            }.build()
        val result = getSystemService(AudioManager::class.java).requestAudioFocus(request)
        if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) audioFocus = request
        else { muted = true; session?.setMuted(true) }
    }
    private fun connectionOptions() {
        AlertDialog.Builder(this).setTitle("连接选项").setItems(arrayOf("粘贴连接信息", "忘记已配对 Mac", "开源许可")) { _, index ->
            if (index == 0) {
                val field = EditText(this).apply { hint = "粘贴 Mac 生成的连接信息"; minLines = 3; maxLines = 5 }
                AlertDialog.Builder(this).setTitle("连接 Mac").setView(field)
                    .setPositiveButton("连接") { _, _ -> parseAndConnect(field.text.toString()); field.text.clear() }
                    .setNegativeButton("取消", null).show()
            } else if (index == 2) {
                val license = runCatching { assets.open("THIRD_PARTY_NOTICES.txt").bufferedReader().use { it.readText() } }.getOrDefault("Kotlin、AndroidX、ZXing：Apache License 2.0")
                AlertDialog.Builder(this).setTitle("开源许可").setMessage(license).setPositiveButton("关闭", null).show()
            } else AlertDialog.Builder(this).setTitle("忘记这台 Mac？").setMessage("下次需要重新扫码并在 Mac 确认。")
                .setPositiveButton("忘记") { _, _ -> endSession("已忘记配对"); store.forget(); updateEnabled(false) }
                .setNegativeButton("取消", null).show()
        }.show()
    }
    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        if (foreground) session?.surfaceAvailable(holder.surface)
        startPending()
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        if (session == null) return
        if (!foreground) { endSession("已暂停：返回后请重新连接"); return }
        // A foreground Surface can be replaced independently of Activity rotation.
        // Do not send the protocol's terminal stop for this recoverable transition.
        Log.i("AOMReceiver", "Foreground Surface replaced; recovering without sending stop")
        session?.surfaceLost()
        status.text = "显示区域正在重建，等待恢复…"
        empty.text = status.text; empty.visibility = View.VISIBLE
        updateEnabled(false)
    }
    @Deprecated("Native back behavior")
    override fun onBackPressed() { if (immersive) toggleFullscreen() else if (session != null) endSession("已停止共享") else super.onBackPressed() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun weighted() = LinearLayout.LayoutParams(0, -2, 1f)
    private fun label(value: String, size: Float, color: Int = Palette.text) = TextView(this).apply { text = value; textSize = size; setTextColor(color); setPadding(dp(4), dp(4), dp(4), dp(4)) }
    private fun button(value: String, action: () -> Unit) = Button(this).apply {
        text = value; isAllCaps = false; minHeight = dp(48); minimumHeight = dp(48); textSize = 14f
        setTextColor(Palette.accent); setOnClickListener { action() }
    }
}
