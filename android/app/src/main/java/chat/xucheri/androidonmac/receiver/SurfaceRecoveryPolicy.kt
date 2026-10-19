package chat.xucheri.androidonmac.receiver

/** Pure lifecycle state; callers serialize access and use a monotonic clock. */
class SurfaceRecoveryPolicy(private val waitMillis: Long = 10_000) {
    enum class State { READY, WAITING, EXPIRED, STOPPED }
    var generation: Long = 0; private set
    private var missingSince: Long? = null
    private var stopped = false

    fun state(now: Long): State {
        if (stopped) return State.STOPPED
        val since = missingSince ?: return State.READY
        return if (now - since >= waitMillis) State.EXPIRED else State.WAITING
    }
    fun lost(now: Long) {
        if (stopped || missingSince != null) return
        missingSince = now
        generation++ // Invalidates queued UI/decoder callbacks before closing the attempt.
    }
    fun available(now: Long): Boolean {
        if (state(now) == State.EXPIRED || stopped) return false
        if (missingSince != null) { missingSince = null; generation++ }
        return true
    }
    fun beginAttempt(now: Long): Long? {
        if (state(now) != State.READY) return null
        generation++
        return generation
    }
    fun accepts(value: Long): Boolean = !stopped && generation == value
    fun finishAttempt(value: Long) { if (generation == value) generation++ }
    fun remainingMillis(now: Long): Long = missingSince?.let { (waitMillis - (now - it)).coerceAtLeast(0) } ?: 0
    fun stop() { if (!stopped) { stopped = true; generation++ } }
}
