package chat.xucheri.androidonmac.receiver

/** Only text being composed on this phone is retained. No remote document or clipboard is read. */
internal class RemoteImeState(private val output: (Output) -> Unit) {
    sealed class Output {
        data class Text(val value: String) : Output()
        data class Key(val value: String) : Output()
    }
    var enabled = false
        private set
    var generation = 0L
        private set
    var composingText = ""
        private set
    var selectionStart = 0
        private set
    var selectionEnd = 0
        private set

    fun setEnabled(value: Boolean) {
        if (enabled == value) return
        enabled = value; invalidate()
    }
    fun invalidate() { generation++; clear() }
    fun openConnection(): Long { invalidate(); return generation }
    fun accepts(connection: Long) = enabled && connection == generation

    fun compose(connection: Long, text: String, newCursorPosition: Int = 1): Boolean {
        if (!accepts(connection) || !validText(text)) return false
        composingText = text
        val position = if (newCursorPosition > 0) text.length.toLong() + newCursorPosition - 1 else newCursorPosition.toLong()
        selectionStart = safeBoundary(text, position.coerceIn(0, text.length.toLong()).toInt(), false)
        selectionEnd = selectionStart
        return true
    }

    fun commit(connection: Long, text: String): Boolean {
        if (!accepts(connection) || !validText(text)) return false
        clear() // commitText replaces the current composing span.
        emitText(text, connection)
        return true
    }

    fun finish(connection: Long): Boolean {
        if (!accepts(connection)) return false
        val finalText = composingText
        clear() // commit -> finish and repeated finish must never send twice.
        emitText(finalText, connection)
        return true
    }

    fun select(connection: Long, start: Int, end: Int): Boolean {
        if (!accepts(connection) || start !in 0..composingText.length || end !in 0..composingText.length) return false
        selectionStart = safeBoundary(composingText, start, false)
        selectionEnd = safeBoundary(composingText, end, false)
        return true
    }

    fun delete(connection: Long, before: Int, after: Int, codePoints: Boolean = false): Boolean {
        if (!accepts(connection) || before !in 0..100 || after !in 0..100) return false
        val start = minOf(selectionStart, selectionEnd)
        val end = maxOf(selectionStart, selectionEnd)
        val availableBefore = if (codePoints) composingText.codePointCount(0, start) else start
        val availableAfter = if (codePoints) composingText.codePointCount(end, composingText.length) else composingText.length - end
        val localBefore = minOf(before, availableBefore)
        val localAfter = minOf(after, availableAfter)
        val removeStart = if (codePoints) composingText.offsetByCodePoints(start, -localBefore)
            else safeBoundary(composingText, start - localBefore, false)
        val removeEnd = if (codePoints) composingText.offsetByCodePoints(end, localAfter)
            else safeBoundary(composingText, end + localAfter, true)
        composingText = composingText.substring(0, removeStart) + composingText.substring(start, end) + composingText.substring(removeEnd)
        selectionStart = removeStart; selectionEnd = removeStart + end - start
        repeat(before - localBefore) { emit(connection, Output.Key("backspace")) }
        repeat(after - localAfter) { emit(connection, Output.Key("delete")) }
        return true
    }

    fun key(connection: Long, name: String): Boolean {
        if (!accepts(connection) || name !in RemoteKeyCommands.allowed) return false
        if (name == "backspace" || name == "delete") {
            if (selectionStart != selectionEnd) {
                val start = minOf(selectionStart, selectionEnd); val end = maxOf(selectionStart, selectionEnd)
                composingText = composingText.removeRange(start, end)
                selectionStart = start; selectionEnd = start
                return true
            }
            return delete(connection, if (name == "backspace") 1 else 0, if (name == "delete") 1 else 0, true)
        }
        if (name == "escape" && composingText.isNotEmpty()) { clear(); return true }
        finish(connection)
        emit(connection, Output.Key(name))
        return true
    }

    private fun clear() { composingText = ""; selectionStart = 0; selectionEnd = 0 }
    private fun validText(value: String): Boolean {
        if (value.length > 65_536 || value.indexOf('\u0000') >= 0) return false
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (Character.isHighSurrogate(char)) {
                if (index + 1 >= value.length || !Character.isLowSurrogate(value[index + 1])) return false
                index += 2
            } else {
                if (Character.isLowSurrogate(char)) return false
                index++
            }
        }
        return true
    }
    private fun emit(connection: Long, value: Output) {
        // Callbacks can synchronously disable/reconnect the view. Never let a
        // remaining chunk or key from the old edit reach the new session.
        if (accepts(connection)) output(value)
    }
    private fun emitText(value: String, connection: Long) {
        // Bound protocol messages by UTF-8 bytes without splitting emoji or CJK.
        var start = 0; var index = 0; var bytes = 0
        while (index < value.length && accepts(connection)) {
            val codePoint = value.codePointAt(index)
            if (codePoint == 10 || codePoint == 13 || codePoint == 9) {
                if (start < index) emit(connection, Output.Text(value.substring(start, index)))
                emit(connection, Output.Key(if (codePoint == 9) "tab" else "enter"))
                index += if (codePoint == 13 && index + 1 < value.length && value[index + 1] == '\n') 2 else 1
                start = index; bytes = 0
                continue
            }
            val size = when { codePoint <= 0x7f -> 1; codePoint <= 0x7ff -> 2; codePoint <= 0xffff -> 3; else -> 4 }
            if (bytes + size > 4096) { emit(connection, Output.Text(value.substring(start, index))); start = index; bytes = 0 }
            bytes += size; index += Character.charCount(codePoint)
        }
        if (start < value.length) emit(connection, Output.Text(value.substring(start)))
    }
    private fun safeBoundary(value: String, position: Int, forward: Boolean): Int {
        if (position > 0 && position < value.length && Character.isHighSurrogate(value[position - 1]) && Character.isLowSurrogate(value[position])) {
            return if (forward) position + 1 else position - 1
        }
        return position
    }
}

internal object RemoteKeyCommands {
    val allowed = setOf("enter", "backspace", "delete", "escape", "tab", "left", "right", "up", "down", "home", "end",
        "copy", "paste", "cut", "selectAll", "undo", "redo")
    fun command(key: String, commandModifier: Boolean, shift: Boolean): String? {
        if (!commandModifier) return key.takeIf { it in allowed }
        return when (key) {
            "a" -> "selectAll"; "c" -> "copy"; "v" -> "paste"; "x" -> "cut"
            "z" -> if (shift) "redo" else "undo"; "y" -> "redo"
            else -> null
        }
    }
}
