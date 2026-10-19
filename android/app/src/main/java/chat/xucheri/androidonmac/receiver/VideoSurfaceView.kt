package chat.xucheri.androidonmac.receiver

import android.content.Context
import android.view.SurfaceView

/** Accessibility activation uses the same click path as a confirmed touch tap. */
class VideoSurfaceView(context: Context) : SurfaceView(context) {
    init { isClickable = true; isFocusable = true }
    var activate: (() -> Unit)? = null
    override fun performClick(): Boolean {
        super.performClick()
        activate?.invoke()
        return true
    }
}
