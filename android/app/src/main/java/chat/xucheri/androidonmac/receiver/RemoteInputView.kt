package chat.xucheri.androidonmac.receiver

import android.content.Context
import android.text.Editable
import android.text.InputType
import android.text.Selection
import android.text.SpannableStringBuilder
import android.util.AttributeSet
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.CompletionInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager

/** Focusable IME endpoint, normally attached as a visible 1×1 view beside the video. */
class RemoteInputView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    var onText: (String) -> Unit = {}
    var onKey: (String) -> Unit = {}
    private val state = RemoteImeState { output ->
        when (output) {
            is RemoteImeState.Output.Text -> onText(output.value)
            is RemoteImeState.Output.Key -> onKey(output.value)
        }
    }
    private val inputMethod get() = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
    private var connection: RemoteConnection? = null
    private val handledKeys = mutableSetOf<Int>()
    private var deadAccent = 0

    init {
        isFocusable = true; isFocusableInTouchMode = true; isEnabled = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        importantForAutofill = IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        importantForContentCapture = IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
    }

    fun setRemoteEnabled(enabled: Boolean) {
        if (state.enabled == enabled) return
        state.setEnabled(enabled); isEnabled = enabled
        handledKeys.clear(); deadAccent = 0
        if (!enabled) hideKeyboard()
    }
    fun stop() { setRemoteEnabled(false); hideKeyboard() }
    fun showKeyboard() {
        if (!state.enabled || !isAttachedToWindow) return
        requestFocus()
        inputMethod.restartInput(this)
        post { if (state.enabled && hasFocus() && isAttachedToWindow) inputMethod.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT) }
    }
    fun hideKeyboard() {
        inputMethod.hideSoftInputFromWindow(windowToken, 0)
        state.invalidate(); connection?.discard(); connection = null
        handledKeys.clear(); deadAccent = 0; clearFocus()
    }

    override fun onCheckIsTextEditor() = state.enabled
    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        if (!state.enabled) return null
        connection?.discard()
        handledKeys.clear(); deadAccent = 0
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        outAttrs.imeOptions = EditorInfo.IME_ACTION_NONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI or
            EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        outAttrs.initialSelStart = 0; outAttrs.initialSelEnd = 0
        outAttrs.setInitialSurroundingText("")
        return RemoteConnection(state.openConnection()).also { connection = it }
    }
    override fun onDetachedFromWindow() { stop(); super.onDetachedFromWindow() }
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean = handleHardwareKey(event) || super.onKeyDown(keyCode, event)
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean = handleHardwareKey(event) || super.onKeyUp(keyCode, event)

    /** Activity may forward post-IME dispatchKeyEvent here when video/buttons have focus. */
    fun handleHardwareKey(event: KeyEvent): Boolean {
        if (!state.enabled) return false
        if (event.action == KeyEvent.ACTION_UP) return handledKeys.remove(event.keyCode)
        if (event.action == KeyEvent.ACTION_MULTIPLE) {
            val text = event.characters ?: return false
            return state.commit(state.generation, text).also { if (it) connection?.refresh() }
        }
        if (event.action != KeyEvent.ACTION_DOWN) return false
        val command = RemoteKeyCommands.command(keyName(event.keyCode), event.isCtrlPressed || event.isMetaPressed, event.isShiftPressed)
        val consumed = if (command != null) {
            deadAccent = 0; state.key(state.generation, command)
        } else if (!event.isCtrlPressed && !event.isMetaPressed) {
            val unicode = event.unicodeChar
            when {
                unicode and KeyCharacterMap.COMBINING_ACCENT != 0 -> { deadAccent = unicode and KeyCharacterMap.COMBINING_ACCENT_MASK; true }
                unicode > 0 && Character.isValidCodePoint(unicode) && !Character.isISOControl(unicode) -> {
                    val combined = if (deadAccent != 0) KeyCharacterMap.getDeadChar(deadAccent, unicode) else 0
                    val prefix = if (deadAccent != 0 && combined == 0) String(Character.toChars(deadAccent)) else ""
                    deadAccent = 0
                    state.commit(state.generation, prefix + String(Character.toChars(if (combined != 0) combined else unicode)))
                }
                else -> false
            }
        } else false
        if (consumed) { handledKeys.add(event.keyCode); connection?.refresh() }
        return consumed
    }

    private fun keyName(code: Int) = when (code) {
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "enter"
        KeyEvent.KEYCODE_DEL -> "backspace"; KeyEvent.KEYCODE_FORWARD_DEL -> "delete"
        KeyEvent.KEYCODE_ESCAPE -> "escape"; KeyEvent.KEYCODE_TAB -> "tab"
        KeyEvent.KEYCODE_DPAD_LEFT -> "left"; KeyEvent.KEYCODE_DPAD_RIGHT -> "right"
        KeyEvent.KEYCODE_DPAD_UP -> "up"; KeyEvent.KEYCODE_DPAD_DOWN -> "down"
        KeyEvent.KEYCODE_MOVE_HOME -> "home"; KeyEvent.KEYCODE_MOVE_END -> "end"
        KeyEvent.KEYCODE_A -> "a"; KeyEvent.KEYCODE_C -> "c"; KeyEvent.KEYCODE_V -> "v"
        KeyEvent.KEYCODE_X -> "x"; KeyEvent.KEYCODE_Z -> "z"; KeyEvent.KEYCODE_Y -> "y"
        else -> ""
    }

    private inner class RemoteConnection(private val generation: Long) : BaseInputConnection(this@RemoteInputView, true) {
        private val buffer = SpannableStringBuilder()
        private var closed = false
        private var batchDepth = 0
        init { Selection.setSelection(buffer, 0) }
        private fun current() = !closed && state.accepts(generation)
        override fun getEditable(): Editable = buffer
        fun discard() { closed = true; buffer.clear() }
        fun refresh() {
            if (!current()) return
            removeComposingSpans(buffer)
            buffer.replace(0, buffer.length, state.composingText)
            Selection.setSelection(buffer, state.selectionStart, state.selectionEnd)
            if (buffer.isNotEmpty()) setComposingSpans(buffer)
            if (batchDepth == 0) inputMethod.updateSelection(this@RemoteInputView, state.selectionStart, state.selectionEnd,
                if (buffer.isEmpty()) -1 else 0, if (buffer.isEmpty()) -1 else buffer.length)
        }
        private fun edit(action: () -> Boolean): Boolean {
            if (!current()) return false
            return action().also { if (it) refresh() }
        }
        override fun setComposingText(text: CharSequence?, newCursorPosition: Int) = edit { state.compose(generation, text?.toString() ?: "", newCursorPosition) }
        override fun commitText(text: CharSequence?, newCursorPosition: Int) = edit { state.commit(generation, text?.toString() ?: "") }
        override fun finishComposingText() = edit { state.finish(generation) }
        override fun setSelection(start: Int, end: Int) = edit { state.select(generation, start, end) }
        override fun setComposingRegion(start: Int, end: Int): Boolean = current() && minOf(start, end) == 0 && maxOf(start, end) == buffer.length
        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int) = edit { state.delete(generation, beforeLength, afterLength) }
        override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int) = edit { state.delete(generation, beforeLength, afterLength, true) }
        override fun sendKeyEvent(event: KeyEvent): Boolean = current() && handleHardwareKey(event)
        override fun performEditorAction(editorAction: Int) = edit { state.key(generation, "enter") }
        override fun commitCompletion(text: CompletionInfo?): Boolean = edit { state.commit(generation, text?.text?.toString() ?: "") }
        override fun performContextMenuAction(id: Int): Boolean {
            val command = when (id) { android.R.id.copy -> "copy"; android.R.id.paste -> "paste"; android.R.id.cut -> "cut"; android.R.id.selectAll -> "selectAll"; else -> return false }
            return edit { state.key(generation, command) }
        }
        override fun beginBatchEdit(): Boolean { if (!current()) return false; batchDepth = (batchDepth + 1).coerceAtMost(64); return true }
        override fun endBatchEdit(): Boolean { if (!current()) return false; batchDepth = (batchDepth - 1).coerceAtLeast(0); refresh(); return true }
        override fun closeConnection() {
            if (current()) state.invalidate() // Never commit unfinished candidates on rotation/stop.
            discard(); super.closeConnection()
        }
    }
}
