package chat.xucheri.androidonmac.receiver

import java.util.ArrayDeque
import java.util.regex.Pattern

/** Only this phone's composition and a bounded, recently submitted tail are retained. */
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
    var canEmit: (Int) -> Boolean = { true }
    private var submittedTail = ""
    private val graphemes = Pattern.compile("\\X")

    fun setEnabled(value: Boolean) {
        if (enabled == value) return
        enabled = value; invalidate()
    }
    fun invalidate() { generation++; clear(); submittedTail = "" }
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
        val messages = textMessages(text) ?: return false
        if (!canEmit(messages.size)) return false
        clear() // commitText replaces the current composing span.
        messages.forEach { emit(connection, it) }
        return true
    }

    fun finish(connection: Long): Boolean {
        if (!accepts(connection)) return false
        val messages = textMessages(composingText) ?: return false
        if (!canEmit(messages.size)) return false
        clear() // commit -> finish and repeated finish must never send twice.
        messages.forEach { emit(connection, it) }
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
        val remoteBefore = before - localBefore
        val remoteAfter = after - localAfter
        val deletion = tailDeletion(remoteBefore, codePoints)
        // With no context a single physical delete is useful, but expanding an
        // IME's UTF-16 count into several keys can erase an unknown prefix.
        val backspaces = if (submittedTail.isEmpty() && remoteBefore == 1 && localBefore == 0) 1 else deletion.first
        val forwardDeletes = if (remoteAfter == 1 && localAfter == 0) 1 else 0
        if (!canEmit(backspaces + forwardDeletes)) return false
        composingText = composingText.substring(0, removeStart) + composingText.substring(start, end) + composingText.substring(removeEnd)
        selectionStart = removeStart; selectionEnd = removeStart + end - start
        submittedTail = deletion.second
        repeat(backspaces) { emit(connection, Output.Key("backspace")) }
        repeat(forwardDeletes) { emit(connection, Output.Key("delete")) }
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
        val messages = textMessages(composingText) ?: return false
        if (!canEmit(messages.size + 1)) return false
        clear()
        messages.forEach { emit(connection, it) }
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
        if (!accepts(connection)) return
        if (value is Output.Text) rememberSubmitted(value.value)
        else if (value is Output.Key && value.value !in setOf("backspace", "delete")) submittedTail = ""
        output(value)
    }
    private fun textMessages(value: String): List<Output>? {
        // Bound protocol messages by UTF-8 bytes without splitting emoji or CJK.
        val messages = ArrayList<Output>()
        var start = 0; var index = 0; var bytes = 0
        while (index < value.length) {
            if (messages.size >= RemoteInputQueue.MAX_PENDING) return null
            val codePoint = value.codePointAt(index)
            if (codePoint == 10 || codePoint == 13 || codePoint == 9) {
                if (start < index) messages.add(Output.Text(value.substring(start, index)))
                messages.add(Output.Key(if (codePoint == 9) "tab" else "enter"))
                index += if (codePoint == 13 && index + 1 < value.length && value[index + 1] == '\n') 2 else 1
                start = index; bytes = 0
                continue
            }
            val size = when { codePoint <= 0x7f -> 1; codePoint <= 0x7ff -> 2; codePoint <= 0xffff -> 3; else -> 4 }
            if (bytes + size > 4096) { messages.add(Output.Text(value.substring(start, index))); start = index; bytes = 0 }
            bytes += size; index += Character.charCount(codePoint)
        }
        if (start < value.length) messages.add(Output.Text(value.substring(start)))
        return messages.takeIf { it.size <= RemoteInputQueue.MAX_PENDING }
    }
    private fun rememberSubmitted(text: String) {
        val combined = submittedTail + text
        if (combined.length <= 4096) { submittedTail = combined; return }
        val matcher = graphemes.matcher(combined)
        var start = 0
        while (matcher.find() && combined.length - start > 4096) start = matcher.end()
        submittedTail = combined.substring(start)
    }
    private fun tailDeletion(units: Int, codePoints: Boolean): Pair<Int, String> {
        if (units == 0 || submittedTail.isEmpty()) return 0 to submittedTail
        val ends = ArrayList<Int>()
        val matcher = graphemes.matcher(submittedTail)
        while (matcher.find()) ends.add(matcher.end())
        var remaining = units; var count = 0; var end = submittedTail.length
        for (index in ends.lastIndex downTo 0) {
            if (remaining <= 0) break
            val start = if (index == 0) 0 else ends[index - 1]
            remaining -= if (codePoints) submittedTail.codePointCount(start, end) else end - start
            end = start; count++
        }
        return count to submittedTail.substring(0, end)
    }
    private fun safeBoundary(value: String, position: Int, forward: Boolean): Int {
        if (position > 0 && position < value.length && Character.isHighSurrogate(value[position - 1]) && Character.isLowSurrogate(value[position])) {
            return if (forward) position + 1 else position - 1
        }
        return position
    }
}

/** A small burst is immediate; large IME commits cannot flood the control socket. */
internal class RemoteInputQueue {
    data class Pending(val generation: Long, val value: RemoteImeState.Output)
    private val pending = ArrayDeque<Pending>()
    private var credits = BURST
    private var lastRefill: Long? = null
    val size get() = pending.size
    fun canAccept(count: Int) = count >= 0 && count <= MAX_PENDING - pending.size
    fun add(generation: Long, value: RemoteImeState.Output) {
        check(canAccept(1))
        pending.addLast(Pending(generation, value))
    }
    fun clear() { pending.clear(); credits = BURST; lastRefill = null }
    fun poll(now: Long, accepts: (Long) -> Boolean): Pending? {
        while (pending.isNotEmpty() && !accepts(pending.first.generation)) pending.removeFirst()
        if (pending.isEmpty()) return null
        refill(now)
        if (credits == 0) return null
        credits--
        return pending.removeFirst()
    }
    fun delayMillis(now: Long): Long? {
        if (pending.isEmpty()) return null
        refill(now)
        return if (credits > 0) 0 else (INTERVAL - (now - (lastRefill ?: now))).coerceAtLeast(1)
    }
    private fun refill(now: Long) {
        val previous = lastRefill
        if (previous == null) { lastRefill = now; return }
        val elapsed = (now - previous).coerceAtLeast(0)
        val earned = elapsed / INTERVAL
        if (earned > 0) { credits = (credits + earned.coerceAtMost(BURST.toLong()).toInt()).coerceAtMost(BURST); lastRefill = now - elapsed % INTERVAL }
    }
    companion object { const val MAX_PENDING = 2048; private const val BURST = 12; private const val INTERVAL = 10L }
}

internal class RemoteBatchEdit {
    private var depth = 0
    val active get() = depth > 0
    fun begin(): Boolean { if (depth == 64) return false; depth++; return true }
    fun end(): Boolean { depth = (depth - 1).coerceAtLeast(0); return active }
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
