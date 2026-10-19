package chat.xucheri.androidonmac.receiver

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** Pure geometry in display pixels; zoom 1 always means aspect-fit. */
class VideoViewport {
    var zoom: Double = 1.0
        private set
    val isZoomed: Boolean get() = zoom > 1.0 + 1e-9
    var baseWidth: Double = 0.0
        private set
    var baseHeight: Double = 0.0
        private set
    var left: Double = 0.0
        private set
    var top: Double = 0.0
        private set

    private var viewWidth = 0.0
    private var viewHeight = 0.0
    private var nativePixelRatio = 1.0
    private var centerX = 0.5
    private var centerY = 0.5
    private val valid: Boolean get() = baseWidth > 0.0 && baseHeight > 0.0
    private val maximumZoom: Double get() = max(4.0, nativePixelRatio)

    fun configure(viewWidth: Int, viewHeight: Int, videoWidth: Int, videoHeight: Int) {
        rememberCenter()
        this.viewWidth = max(0, viewWidth).toDouble()
        this.viewHeight = max(0, viewHeight).toDouble()
        if (viewWidth <= 0 || viewHeight <= 0 || videoWidth <= 0 || videoHeight <= 0) {
            baseWidth = 0.0; baseHeight = 0.0; left = 0.0; top = 0.0
            return // A temporarily missing Surface must not discard its zoom/center.
        }
        val fitScale = min(viewWidth.toDouble() / videoWidth, viewHeight.toDouble() / videoHeight)
        baseWidth = videoWidth * fitScale
        baseHeight = videoHeight * fitScale
        nativePixelRatio = 1.0 / fitScale
        zoom = zoom.coerceIn(1.0, maximumZoom)
        positionAtRememberedCenter()
    }

    fun fit() {
        zoom = 1.0; centerX = 0.5; centerY = 0.5
        positionAtRememberedCenter()
    }

    fun actualPixels() {
        if (!valid) return
        rememberCenter()
        zoom = nativePixelRatio.coerceIn(1.0, maximumZoom)
        positionAtRememberedCenter()
    }

    fun pan(dx: Double, dy: Double) {
        if (!valid || !dx.isFinite() || !dy.isFinite()) return
        left += dx; top += dy
        constrain()
    }

    /** Keep the content under the previous focus under the new focus. */
    fun transform(factor: Double, previousFocusX: Double, previousFocusY: Double, focusX: Double, focusY: Double) {
        if (!valid || !factor.isFinite() || factor <= 0.0 ||
            !previousFocusX.isFinite() || !previousFocusY.isFinite() || !focusX.isFinite() || !focusY.isFinite()) return
        val anchorX = (previousFocusX - left) / (baseWidth * zoom)
        val anchorY = (previousFocusY - top) / (baseHeight * zoom)
        zoom = (zoom * factor).coerceIn(1.0, maximumZoom)
        left = focusX - anchorX * baseWidth * zoom
        top = focusY - anchorY * baseHeight * zoom
        constrain()
    }

    fun point(x: Double, y: Double, clamp: Boolean = false): ContentPoint? {
        if (!valid || !x.isFinite() || !y.isFinite()) return null
        if (!clamp && (x < 0.0 || y < 0.0 || x > viewWidth || y > viewHeight)) return null
        val localX = if (clamp) x.coerceIn(0.0, viewWidth) else x
        val localY = if (clamp) y.coerceIn(0.0, viewHeight) else y
        val normalizedX = (localX - left) / (baseWidth * zoom)
        val normalizedY = (localY - top) / (baseHeight * zoom)
        if (!clamp && (normalizedX < 0.0 || normalizedX > 1.0 || normalizedY < 0.0 || normalizedY > 1.0)) return null
        return ContentPoint(normalizedX.coerceIn(0.0, 1.0), normalizedY.coerceIn(0.0, 1.0))
    }

    private fun positionAtRememberedCenter() {
        if (!valid) { left = 0.0; top = 0.0; return }
        left = viewWidth / 2.0 - centerX * baseWidth * zoom
        top = viewHeight / 2.0 - centerY * baseHeight * zoom
        constrain()
    }

    private fun constrain() {
        val width = baseWidth * zoom
        val height = baseHeight * zoom
        left = if (width <= viewWidth) (viewWidth - width) / 2.0 else left.coerceIn(viewWidth - width, 0.0)
        top = if (height <= viewHeight) (viewHeight - height) / 2.0 else top.coerceIn(viewHeight - height, 0.0)
        rememberCenter()
    }

    private fun rememberCenter() {
        if (!valid) return
        centerX = ((viewWidth / 2.0 - left) / (baseWidth * zoom)).coerceIn(0.0, 1.0)
        centerY = ((viewHeight / 2.0 - top) / (baseHeight * zoom)).coerceIn(0.0, 1.0)
    }
}

/** Locks each two-finger gesture to pinch, local pan, or remote scroll. */
class TwoFingerMotion(slop: Double) {
    enum class Kind { NONE, SCROLL, PAN, PINCH }
    data class Change(val kind: Kind, val dx: Double, val dy: Double, val factor: Double,
                      val previousX: Double, val previousY: Double, val focusX: Double, val focusY: Double)

    private data class Sample(val x1: Double, val y1: Double, val x2: Double, val y2: Double,
                              val x: Double, val y: Double, val span: Double)
    private val threshold = if (slop.isFinite()) max(0.0, slop) else 8.0
    private var initial: Sample? = null
    private var previous: Sample? = null
    private var kind = Kind.NONE
    private var wasZoomed = false

    fun begin(x1: Double, y1: Double, x2: Double, y2: Double, zoomed: Boolean) {
        reset()
        val sample = sample(x1, y1, x2, y2) ?: return
        initial = sample; previous = sample; wasZoomed = zoomed
    }

    fun move(x1: Double, y1: Double, x2: Double, y2: Double): Change {
        val start = initial ?: return noChange()
        val last = previous ?: return noChange()
        val current = sample(x1, y1, x2, y2) ?: return noChange(last)
        val dx = current.x - last.x
        val dy = current.y - last.y
        val scale = current.span / last.span
        if (!dx.isFinite() || !dy.isFinite() || !scale.isFinite()) return noChange(last)
        if (kind == Kind.NONE) {
            val dx1 = current.x1 - start.x1; val dy1 = current.y1 - start.y1
            val dx2 = current.x2 - start.x2; val dy2 = current.y2 - start.y2
            val fingerTravel = max(hypot(dx1, dy1), hypot(dx2, dy2))
            val centerTravel = hypot(current.x - start.x, current.y - start.y)
            val spanChange = abs(current.span / start.span - 1.0)
            if (fingerTravel > threshold && spanChange >= 0.04) {
                kind = Kind.PINCH
            } else if (centerTravel > threshold && dx1 * dx2 + dy1 * dy2 > 0.0) {
                kind = if (wasZoomed) Kind.PAN else Kind.SCROLL
            } else {
                // Retain the initial sample until decided, so the first emitted
                // movement includes the small increments below touch slop.
                return noChange(last, current)
            }
        }
        val change = Change(kind, dx, dy,
            if (kind == Kind.PINCH) scale else 1.0,
            last.x, last.y, current.x, current.y)
        previous = current
        return change
    }

    fun reset() {
        initial = null; previous = null; kind = Kind.NONE; wasZoomed = false
    }

    private fun sample(x1: Double, y1: Double, x2: Double, y2: Double): Sample? {
        if (!x1.isFinite() || !y1.isFinite() || !x2.isFinite() || !y2.isFinite()) return null
        val span = hypot(x2 - x1, y2 - y1)
        if (!span.isFinite() || span <= 1e-9) return null
        return Sample(x1, y1, x2, y2, x1 / 2.0 + x2 / 2.0, y1 / 2.0 + y2 / 2.0, span)
    }

    private fun noChange(previous: Sample? = null, current: Sample? = previous) =
        Change(Kind.NONE, 0.0, 0.0, 1.0, previous?.x ?: 0.0, previous?.y ?: 0.0, current?.x ?: 0.0, current?.y ?: 0.0)
}
