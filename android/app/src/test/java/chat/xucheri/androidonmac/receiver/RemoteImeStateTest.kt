package chat.xucheri.androidonmac.receiver

import org.junit.Assert.*
import org.junit.Test

class RemoteImeStateTest {
    private class Fixture {
        val output = mutableListOf<RemoteImeState.Output>()
        val state = RemoteImeState(output::add).apply { setEnabled(true) }
        val token = state.openConnection()
        fun text(value: String) = RemoteImeState.Output.Text(value)
        fun key(value: String) = RemoteImeState.Output.Key(value)
    }

    @Test fun chineseCandidateUpdatesStayLocalUntilOneCommit() {
        val f = Fixture()
        for (candidate in listOf("n", "ni", "ni'h", "ni'hao", "你好")) assertTrue(f.state.compose(f.token, candidate))
        assertTrue(f.output.isEmpty())
        assertTrue(f.state.commit(f.token, "你好"))
        assertTrue(f.state.finish(f.token)); assertTrue(f.state.finish(f.token))
        assertEquals(listOf(f.text("你好")), f.output)
        assertEquals("", f.state.composingText)
    }

    @Test fun finishingWithoutCommitSendsTheFinalCandidateOnlyOnce() {
        val f = Fixture()
        f.state.compose(f.token, "中"); f.state.compose(f.token, "中文输入")
        f.state.finish(f.token); f.state.finish(f.token)
        assertEquals(listOf(f.text("中文输入")), f.output)
    }

    @Test fun legitimateRepeatedCommitsAreNotDeduplicatedByContent() {
        val f = Fixture()
        f.state.commit(f.token, "哈"); f.state.finish(f.token)
        f.state.commit(f.token, "哈"); f.state.finish(f.token)
        assertEquals(listOf(f.text("哈"), f.text("哈")), f.output)
    }

    @Test fun emptyCommitCancelsCompositionWithoutDeletingRemoteText() {
        val f = Fixture()
        f.state.compose(f.token, "unfinished")
        assertTrue(f.state.commit(f.token, "")); f.state.finish(f.token)
        assertTrue(f.output.isEmpty()); assertEquals("", f.state.composingText)
    }

    @Test fun disablingAndReconnectingDiscardCompositionAndRejectOldCallbacks() {
        val f = Fixture()
        f.state.compose(f.token, "不能发送")
        f.state.setEnabled(false)
        assertFalse(f.state.commit(f.token, "迟到提交")); assertFalse(f.state.finish(f.token))
        f.state.setEnabled(true)
        val next = f.state.openConnection()
        assertFalse(f.state.compose(f.token, "旧连接")); assertFalse(f.state.key(f.token, "enter"))
        f.state.commit(next, "新会话")
        assertEquals(listOf(f.text("新会话")), f.output)
    }

    @Test fun keyboardRecreationAndHidingInvalidateOldInputConnection() {
        val f = Fixture()
        f.state.compose(f.token, "rotation")
        val replacement = f.state.openConnection()
        assertFalse(f.state.finish(f.token)); assertEquals("", f.state.composingText)
        f.state.compose(replacement, "hidden")
        f.state.invalidate()
        assertFalse(f.state.commit(replacement, "hidden")); assertTrue(f.output.isEmpty())
    }

    @Test fun backspaceEditsComposingTextBeforeTouchingTheRemoteDocument() {
        val f = Fixture()
        f.state.compose(f.token, "nihao")
        f.state.delete(f.token, 1, 0)
        assertEquals("niha", f.state.composingText); assertTrue(f.output.isEmpty())
        f.state.delete(f.token, 6, 0)
        assertEquals("", f.state.composingText)
        assertTrue(f.output.isEmpty()) // Never infer keys for an unknown remote prefix.
    }

    @Test fun forwardDeleteAndCursorPositionRespectLocalComposition() {
        val f = Fixture()
        f.state.compose(f.token, "abcd", 0)
        f.state.delete(f.token, 0, 1)
        assertEquals("bcd", f.state.composingText); assertTrue(f.output.isEmpty())
        f.state.select(f.token, 1, 1)
        f.state.delete(f.token, 1, 3)
        assertEquals("", f.state.composingText)
        assertTrue(f.output.isEmpty())
    }

    @Test fun codePointDeletionNeverSplitsEmojiSurrogates() {
        val f = Fixture()
        f.state.compose(f.token, "中🙂")
        f.state.delete(f.token, 1, 0, true)
        assertEquals("中", f.state.composingText)
        f.state.compose(f.token, "🙂")
        f.state.delete(f.token, 1, 0) // Defensive widening for UTF-16-based IMEs.
        assertEquals("", f.state.composingText)
        assertTrue(f.output.isEmpty())
        f.state.compose(f.token, "🙂中", 0)
        f.state.delete(f.token, 0, 1, true)
        assertEquals("中", f.state.composingText)
    }

    @Test fun selectedCompositionIsDeletedLocallyAndSurroundingDeletionPreservesSelection() {
        val f = Fixture()
        f.state.compose(f.token, "abcd"); f.state.select(f.token, 1, 3)
        f.state.delete(f.token, 1, 1)
        assertEquals("bc", f.state.composingText)
        f.state.key(f.token, "backspace")
        assertEquals("", f.state.composingText); assertTrue(f.output.isEmpty())
    }

    @Test fun enterCommitsPendingCandidateBeforeSendingOneReturn() {
        val f = Fixture()
        f.state.compose(f.token, "确认")
        f.state.key(f.token, "enter"); f.state.finish(f.token)
        assertEquals(listOf(f.text("确认"), f.key("enter")), f.output)
    }

    @Test fun escapeCancelsPendingCompositionWithoutSendingIt() {
        val f = Fixture()
        f.state.compose(f.token, "cancel")
        f.state.key(f.token, "escape")
        assertTrue(f.output.isEmpty())
        f.state.key(f.token, "escape")
        assertEquals(listOf(f.key("escape")), f.output)
    }

    @Test fun plainKeysAndMacShortcutsUseOnlyTheProtocolAllowList() {
        val expected = mapOf("a" to "selectAll", "c" to "copy", "v" to "paste", "x" to "cut", "z" to "undo", "y" to "redo")
        for ((key, command) in expected) assertEquals(command, RemoteKeyCommands.command(key, true, false))
        assertEquals("redo", RemoteKeyCommands.command("z", true, true))
        assertEquals("delete", RemoteKeyCommands.command("delete", false, false))
        assertNull(RemoteKeyCommands.command("q", true, false))
        assertNull(RemoteKeyCommands.command("a", false, false))
        val f = Fixture()
        assertFalse(f.state.key(f.token, "shell")); assertTrue(f.output.isEmpty())
        f.state.key(f.token, "backspace"); f.state.key(f.token, "delete")
        assertEquals(listOf(f.key("backspace"), f.key("delete")), f.output)
    }

    @Test fun committedUnicodeIsChunkedAtProtocolByteBoundariesWithoutDataLoss() {
        val f = Fixture()
        val text = "中🙂e\u0301".repeat(1000)
        assertTrue(f.state.commit(f.token, text))
        val chunks = f.output.map { (it as RemoteImeState.Output.Text).value }
        assertTrue(chunks.size > 1)
        assertEquals(text, chunks.joinToString(""))
        for (chunk in chunks) assertTrue(chunk.toByteArray(Charsets.UTF_8).size <= 4096)
    }

    @Test fun softKeyboardNewlinesAndTabsBecomeRealMacKeys() {
        val f = Fixture()
        f.state.commit(f.token, "\n"); f.state.finish(f.token)
        f.state.commit(f.token, "第一行\r\n第二行\t后面")
        assertEquals(listOf(f.key("enter"), f.text("第一行"), f.key("enter"), f.text("第二行"), f.key("tab"), f.text("后面")), f.output)
    }

    @Test fun stoppingInsideTheFirstTextCallbackDropsRemainingChunksAndKeys() {
        val output = mutableListOf<RemoteImeState.Output>()
        lateinit var state: RemoteImeState
        state = RemoteImeState { value -> output.add(value); state.setEnabled(false) }
        state.setEnabled(true)
        val token = state.openConnection()
        state.commit(token, "中".repeat(4000) + "\n")
        assertEquals(1, output.size)
        assertTrue(output.first() is RemoteImeState.Output.Text)
        assertFalse(state.enabled)
    }

    @Test fun reconnectInsideCompositionCommitCannotSendTheOldReturnKey() {
        val output = mutableListOf<RemoteImeState.Output>()
        lateinit var state: RemoteImeState
        state = RemoteImeState { value -> output.add(value); state.openConnection() }
        state.setEnabled(true)
        val token = state.openConnection()
        state.compose(token, "已确认")
        state.key(token, "enter")
        assertEquals(listOf(RemoteImeState.Output.Text("已确认")), output)
        assertFalse(state.accepts(token))
    }

    @Test fun malformedOrUnboundedInputDoesNotMutateOrEmit() {
        val f = Fixture()
        f.state.compose(f.token, "keep")
        for (invalid in listOf("a\u0000b", "\uD800", "\uDC00", "x".repeat(65_537))) {
            assertFalse(f.state.commit(f.token, invalid)); assertFalse(f.state.compose(f.token, invalid))
        }
        assertFalse(f.state.delete(f.token, -1, 0)); assertFalse(f.state.delete(f.token, 101, 0))
        assertFalse(f.state.select(f.token, -1, 0)); assertFalse(f.state.select(f.token, 0, 100))
        assertEquals("keep", f.state.composingText); assertTrue(f.output.isEmpty())
    }

    @Test fun committedEmojiUtf16DeletionSendsOneBackspaceWithoutDeletingItsPrefix() {
        val f = Fixture()
        f.state.commit(f.token, "a🙂")
        f.output.clear()
        f.state.delete(f.token, 2, 0)
        assertEquals(listOf(f.key("backspace")), f.output)
        f.output.clear()
        f.state.delete(f.token, 100, 0)
        assertEquals(listOf(f.key("backspace")), f.output) // Only the known "a".
    }

    @Test fun committedExtendedGraphemesAreNotExpandedIntoMultipleMacDeletes() {
        for (cluster in listOf("👨‍👩‍👧‍👦", "👩🏽‍💻", "🇨🇳", "e\u0301")) {
            for (codePoints in listOf(false, true)) {
                val f = Fixture()
                f.state.commit(f.token, "keep" + cluster)
                f.output.clear()
                val units = if (codePoints) cluster.codePointCount(0, cluster.length) else cluster.length
                f.state.delete(f.token, units, 0, codePoints)
                assertEquals(cluster, listOf(f.key("backspace")), f.output)
            }
        }
    }

    @Test fun composingDeletionCanReachOnlyTheKnownCommittedTail() {
        val f = Fixture()
        f.state.commit(f.token, "🙂"); f.output.clear()
        f.state.compose(f.token, "ni")
        f.state.delete(f.token, 20, 0)
        assertEquals("", f.state.composingText)
        assertEquals(listOf(f.key("backspace")), f.output)
    }

    @Test fun pointerOrNavigationInvalidationCannotReuseAnotherFieldsTail() {
        val f = Fixture()
        f.state.commit(f.token, "old🙂")
        val next = f.state.openConnection()
        f.output.clear()
        f.state.delete(next, 2, 0)
        assertTrue(f.output.isEmpty())
        f.state.commit(next, "new🙂"); f.state.key(next, "left")
        f.output.clear()
        f.state.delete(next, 2, 0)
        assertTrue(f.output.isEmpty())
        f.state.key(next, "backspace")
        assertEquals(listOf(f.key("backspace")), f.output) // Explicit single keys remain useful.
    }

    @Test fun batchNestingReturnsFalseWhenTheLastBatchEnds() {
        val batch = RemoteBatchEdit()
        assertFalse(batch.end())
        assertTrue(batch.begin()); assertTrue(batch.begin())
        assertTrue(batch.end()); assertTrue(batch.active)
        assertFalse(batch.end()); assertFalse(batch.active)
        repeat(64) { assertTrue(batch.begin()) }
        assertFalse(batch.begin())
        repeat(63) { assertTrue(batch.end()) }
        assertFalse(batch.end())
    }

    @Test fun ordinaryInputHasNoDelayAndBulkInputStaysBelowControlRateLimits() {
        val queue = RemoteInputQueue()
        val value = RemoteImeState.Output.Key("enter")
        queue.add(1, value)
        assertEquals(value, queue.poll(0) { true }?.value)
        assertNull(queue.delayMillis(0))
        repeat(1000) { queue.add(1, value) }
        var sent = 1
        for (time in 0L..999L) while (queue.poll(time) { true } != null) sent++
        assertTrue(sent in 100..112)
        assertEquals(1001 - sent, queue.size)
        var time = 1000L
        while (queue.size > 0) {
            while (queue.poll(time) { true } != null) sent++
            time += queue.delayMillis(time) ?: 0
        }
        assertEquals(1001, sent)
    }

    @Test fun queuedOldGenerationAndExplicitStopDiscardUnsentText() {
        val queue = RemoteInputQueue()
        repeat(20) { queue.add(1, RemoteImeState.Output.Text("old")) }
        queue.add(2, RemoteImeState.Output.Text("new"))
        assertEquals("new", (queue.poll(0) { it == 2L }?.value as RemoteImeState.Output.Text).value)
        assertEquals(0, queue.size)
        queue.add(2, RemoteImeState.Output.Text("discard")); queue.clear()
        assertNull(queue.poll(1) { true })
    }

    @Test fun queueAdmissionRejectsWholeEditsWithoutLosingCompositionOrSendingAPrefix() {
        val queue = RemoteInputQueue()
        val f = Fixture()
        f.state.canEmit = queue::canAccept
        repeat(RemoteInputQueue.MAX_PENDING - 1) { queue.add(1, f.key("enter")) }
        f.state.compose(f.token, "keep")
        assertFalse(f.state.commit(f.token, "first\nsecond"))
        assertFalse(f.state.key(f.token, "enter"))
        assertEquals("keep", f.state.composingText); assertTrue(f.output.isEmpty())
        queue.clear()
        assertTrue(f.state.finish(f.token))
        assertEquals(listOf(f.text("keep")), f.output)
    }

    @Test fun oversizedMultilineEditIsRejectedBeforeAnyInputIsEmitted() {
        val f = Fixture()
        f.state.compose(f.token, "keep")
        assertFalse(f.state.commit(f.token, "\n".repeat(RemoteInputQueue.MAX_PENDING + 1)))
        assertEquals("keep", f.state.composingText); assertTrue(f.output.isEmpty())
    }
}
