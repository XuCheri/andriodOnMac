package chat.xucheri.androidonmac.receiver

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.EOFException

class ProtocolTest {
    private fun raw(length: Int, kind: Int = 1, pts: Long = 0, flags: Int = 0, payload: ByteArray = byteArrayOf()): ByteArray =
        ByteArrayOutputStream().also { out -> DataOutputStream(out).apply { writeInt(length); writeByte(kind); writeLong(pts); writeByte(flags); write(payload) } }.toByteArray()
    private fun bootstrap(host: String = "127.0.0.1", port: Any = 32123) = JSONObject().put("v", 1).put("host", host)
        .put("port", port).put("fingerprint", "ab".repeat(32)).put("pairToken", "a".repeat(32)).toString()
    @Test fun jsonFrameRoundTripWithChinese() {
        val output = ByteArrayOutputStream()
        WireFrame.writeJSON(output, JSONObject().put("type", "input").put("text", "中文 👋"))
        val wire = output.toByteArray()
        assertEquals(1, wire[4].toInt())
        assertEquals(0, wire[13].toInt())
        val result = WireFrame.read(ByteArrayInputStream(wire))
        assertEquals("中文 👋", result.json().getString("text"))
    }
    @Test fun videoHeaderMatchesNetworkByteOrder() {
        val frame = WireFrame.read(ByteArrayInputStream(raw(14, 2, 1234567, 1, byteArrayOf(0, 0, 0, 1))))
        assertTrue(frame.keyFrame); assertEquals(1234567L, frame.pts); assertEquals(4, frame.payload.size)
    }
    @Test fun rejectsUnsignedOverflowAndOversizedFramesBeforeAllocation() {
        listOf(-1, Int.MIN_VALUE, 0, 9, WireFrame.MAX_BODY + 1).forEach { length ->
            assertThrows(ProtocolException::class.java) { WireFrame.read(ByteArrayInputStream(raw(length))) }
        }
    }
    @Test fun rejectsUnknownTypeAndFlagsAndNegativePTS() {
        listOf(raw(10, 4), raw(10, 0), raw(10, flags = 2), raw(10, pts = -1)).forEach {
            assertThrows(ProtocolException::class.java) { WireFrame.read(ByteArrayInputStream(it)) }
        }
    }
    @Test fun rejectsPartialHeaderAndBody() {
        listOf(byteArrayOf(0, 0), raw(20), raw(10).copyOf(8)).forEach {
            assertThrows(EOFException::class.java) { WireFrame.read(ByteArrayInputStream(it)) }
        }
    }
    @Test fun controlPayloadLimitIsSeparateFromVideoLimit() {
        assertThrows(ProtocolException::class.java) { WireFrame.read(ByteArrayInputStream(raw(65547))) }
        assertThrows(ProtocolException::class.java) { WireFrame.writeJSON(ByteArrayOutputStream(), JSONObject().put("x", "a".repeat(65536))) }
    }
    @Test fun rejectsMalformedUTF8AndInvalidJSON() {
        assertThrows(ProtocolException::class.java) { WireFrame(1, 0, 0, byteArrayOf(0xc3.toByte(), 0x28)).json() }
        assertThrows(ProtocolException::class.java) { WireFrame(1, 0, 0, "not json".toByteArray()).json() }
        assertThrows(ProtocolException::class.java) { WireFrame(2, 0, 0, "{}".toByteArray()).json() }
    }
    @Test fun acceptsURLSafeUSBLaunchWithoutShellQuoting() {
        val raw = bootstrap()
        val encoded = "aom:" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(raw.toByteArray())
        assertEquals(Bootstrap.parse(raw), Bootstrap.parse(encoded))
        assertThrows(ProtocolException::class.java) { Bootstrap.parse("aom:!invalid!") }
    }
    @Test fun acceptsBootstrapIPv4HostnameAndBracketedIPv6() {
        listOf("127.0.0.1", "192.168.1.24", "macbook.local", "[fe80::1234]").forEach {
            val parsed = Bootstrap.parse(bootstrap(it))
            assertEquals(32123, parsed.port); assertEquals("ab".repeat(32), parsed.fingerprint)
        }
        assertEquals("fe80::1234", Bootstrap.parse(bootstrap("[fe80::1234]")).host)
    }
    @Test fun rejectsEndpointAndOptionInjection() {
        listOf("-option", "localhost/path", "x;evil", "x\n", "https://mac", "a b", "1.2.3.04", "999.2.3.4", "::::", "a..b").forEach {
            assertThrows("host $it", ProtocolException::class.java) { Bootstrap.parse(bootstrap(it)) }
        }
        listOf(0, 65536, -1, 2.5, "123").forEach {
            assertThrows(ProtocolException::class.java) { Bootstrap.parse(bootstrap(port = it)) }
        }
    }
    @Test fun refusesMissingOrInvalidPinAndUnsupportedVersion() {
        val value = JSONObject(bootstrap())
        value.put("fingerprint", "aa")
        assertThrows(ProtocolException::class.java) { Bootstrap.parse(value.toString()) }
        value.put("fingerprint", "ab".repeat(32)).put("v", 2)
        assertThrows(ProtocolException::class.java) { Bootstrap.parse(value.toString()) }
    }
    @Test fun tokenIsRemovedBeforePersistingEndpoint() {
        val parsed = Bootstrap.parse(bootstrap())
        assertNotNull(parsed.pairToken); assertNull(parsed.withoutToken().pairToken)
        assertEquals(parsed.fingerprint, parsed.withoutToken().fingerprint)
    }
    @Test fun pinsExactCertificateBytes() {
        val der = byteArrayOf(1, 2, 3)
        val hash = CertificatePin.sha256(der)
        assertEquals(64, hash.length)
        assertTrue(CertificatePin.matches(hash, der))
        assertFalse(CertificatePin.matches(hash, byteArrayOf(1, 2, 4)))
    }
    @Test fun reconnectHasExactlyThreeAttempts() {
        val policy = RecoveryPolicy()
        assertEquals(1000L, policy.nextDelayMillis()); assertEquals(2000L, policy.nextDelayMillis())
        assertEquals(4000L, policy.nextDelayMillis()); assertNull(policy.nextDelayMillis())
    }
    @Test fun onlyRenderingResetsRecoveryAndStopIsPermanent() {
        val policy = RecoveryPolicy()
        policy.nextDelayMillis(); policy.nextDelayMillis(); policy.rendered()
        assertEquals(1000L, policy.nextDelayMillis())
        policy.stop(); policy.rendered(); assertNull(policy.nextDelayMillis())
    }
    @Test fun approvalDoesNotConsumeHeartbeatOrFirstFrameDeadline() {
        val watchdog = SessionWatchdog(0)
        assertNull(watchdog.expired(119_999))
        watchdog.paired(119_999)
        watchdog.controlReceived(149_998)
        assertNull(watchdog.expired(149_998))
        watchdog.controlReceived(149_999)
        assertEquals(SessionWatchdog.Failure.FIRST_FRAME_TIMEOUT, watchdog.expired(149_999))
        assertEquals(SessionWatchdog.Failure.PAIRING_TIMEOUT, SessionWatchdog(0).expired(120_000))
    }
    @Test fun staticDesktopStaysAliveWithControlHeartbeats() {
        val watchdog = SessionWatchdog(0)
        watchdog.paired(1000); watchdog.rendered()
        for (now in 1000L..121_000L step 2000L) {
            watchdog.controlReceived(now)
            assertNull(watchdog.expired(now + 1999))
        }
        assertEquals(SessionWatchdog.Failure.CONTROL_TIMEOUT, watchdog.expired(129_000))
    }
    @Test fun rediscoveryRequiresTheSavedPinAndVersionAndNeverTheDisplayName() {
        val saved = Bootstrap.parse(bootstrap("192.168.1.10"))
        val attributes = mapOf("fingerprint" to saved.fingerprint.toByteArray(), "v" to "1".toByteArray())
        val updated = DiscoveredIdentity.endpoint(saved, "192.168.1.20", 54321, attributes)
        assertEquals("192.168.1.20", updated?.host); assertEquals(54321, updated?.port)
        assertEquals(saved.fingerprint, updated?.fingerprint); assertNull(updated?.pairToken)
        assertNull(DiscoveredIdentity.endpoint(saved, "192.168.1.20", 54321, attributes + ("fingerprint" to "cd".repeat(32).toByteArray())))
        assertNull(DiscoveredIdentity.endpoint(saved, "192.168.1.20", 54321, attributes + ("v" to "2".toByteArray())))
        assertNull(DiscoveredIdentity.endpoint(saved, "127.0.0.1", 54321, attributes))
        assertNull(DiscoveredIdentity.endpoint(saved, "192.168.1.20", 0, attributes))
        assertNull(DiscoveredIdentity.endpoint(saved, "192.168.1.20", 54321, emptyMap()))
    }
    @Test fun acceptsScopedIPv6DiscoveryWithoutAllowingShellCharacters() {
        assertTrue(Bootstrap.validHost("fe80::1234%wlan0"))
        assertFalse(Bootstrap.validHost("fe80::1234%wlan0;evil"))
        assertFalse(Bootstrap.validHost("fe80::1234%"))
    }
    @Test fun scannerRuntimeDependenciesExistDespiteUpstreamPOMOmission() {
        val loader = javaClass.classLoader
        listOf("androidx.core.content.ContextCompat", "androidx.core.app.ActivityCompat", "androidx.fragment.app.Fragment", "androidx.activity.result.contract.ActivityResultContract").forEach {
            assertNotNull(Class.forName(it, false, loader))
        }
    }
    @Test fun coordinatesExcludeBarsAndNonFiniteInput() {
        assertEquals(ContentPoint(0.5, 0.5), ContentCoordinates.point(100f, 50f, 200, 100))
        assertNull(ContentCoordinates.point(-1f, 50f, 200, 100))
        assertNull(ContentCoordinates.point(201f, 50f, 200, 100))
        assertNull(ContentCoordinates.point(Float.NaN, 0f, 200, 100))
        assertNull(ContentCoordinates.point(0f, 0f, 0, 100))
    }
}
