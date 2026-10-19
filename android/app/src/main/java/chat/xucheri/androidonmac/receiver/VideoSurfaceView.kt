package chat.xucheri.androidonmac.receiver

import android.content.Context
import android.view.SurfaceView
import android.view.View

/** The codec owns this Surface; gesture coordinates belong to the untransformed overlay. */
class VideoSurfaceView(context: Context) : SurfaceView(context) {
    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
}

/** Keeps gestures in viewport coordinates while the underlying Surface is zoomed/panned. */
class VideoTouchView(context: Context) : View(context) {
    init { isClickable = true; isFocusable = true }
    var activate: (() -> Unit)? = null
    override fun performClick(): Boolean {
        super.performClick()
        activate?.invoke()
        return true
    }
}
