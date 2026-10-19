package chat.xucheri.androidonmac.receiver

import org.junit.Assert.*
import org.junit.Test

class SurfaceRecoveryPolicyTest {
    @Test fun foregroundLossInvalidatesOldCallbacksWithoutStoppingSession() {
        val policy = SurfaceRecoveryPolicy()
        val old = policy.beginAttempt(0)!!
        assertTrue(policy.accepts(old))
        policy.lost(10)
        assertFalse(policy.accepts(old))
        assertEquals(SurfaceRecoveryPolicy.State.WAITING, policy.state(10))
        assertNull(policy.beginAttempt(10))
        assertTrue(policy.available(11))
        val replacement = policy.beginAttempt(11)!!
        assertNotEquals(old, replacement)
        assertTrue(policy.accepts(replacement))
        assertFalse(policy.accepts(old))
    }
    @Test fun duplicateLossDoesNotExtendTheTenSecondDeadline() {
        val policy = SurfaceRecoveryPolicy()
        policy.lost(100)
        policy.lost(9000)
        assertEquals(1L, policy.remainingMillis(10_099))
        assertEquals(SurfaceRecoveryPolicy.State.WAITING, policy.state(10_099))
        assertEquals(SurfaceRecoveryPolicy.State.EXPIRED, policy.state(10_100))
        assertFalse(policy.available(10_100))
        assertNull(policy.beginAttempt(10_101))
    }
    @Test fun restoredSurfaceStartsAFreshDeadlineForAnotherRotation() {
        val policy = SurfaceRecoveryPolicy()
        policy.lost(0)
        assertTrue(policy.available(9999))
        assertEquals(SurfaceRecoveryPolicy.State.READY, policy.state(20_000))
        policy.lost(20_000)
        assertEquals(10_000L, policy.remainingMillis(20_000))
    }
    @Test fun backgroundOrManualStopCannotBeResumedByLateSurfaceCallbacks() {
        val policy = SurfaceRecoveryPolicy()
        val old = policy.beginAttempt(0)!!
        policy.lost(1); policy.stop()
        assertFalse(policy.available(2))
        assertNull(policy.beginAttempt(2))
        assertFalse(policy.accepts(old))
        assertEquals(SurfaceRecoveryPolicy.State.STOPPED, policy.state(2))
    }
    @Test fun surfaceReplacementDoesNotResetNetworkRecoveryBudget() {
        val surfaces = SurfaceRecoveryPolicy()
        val retries = RecoveryPolicy()
        for (delay in listOf(1000L, 2000L, 4000L)) {
            surfaces.lost(0)
            assertTrue(surfaces.available(1))
            assertNotNull(surfaces.beginAttempt(1))
            assertEquals(delay, retries.nextDelayMillis())
        }
        assertNull(retries.nextDelayMillis())
        retries.rendered()
        assertEquals(1000L, retries.nextDelayMillis())
    }
    @Test fun newAttemptRejectsQueuedCallbacksEvenWithoutSurfaceLoss() {
        val policy = SurfaceRecoveryPolicy()
        val first = policy.beginAttempt(0)!!
        policy.finishAttempt(first)
        assertFalse(policy.accepts(first))
        val next = policy.beginAttempt(1)!!
        assertFalse(policy.accepts(first))
        assertTrue(policy.accepts(next))
    }
}
