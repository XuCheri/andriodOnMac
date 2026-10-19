import Foundation
import Testing
@testable import AndroidOnMacCore

@Suite
struct SessionDiagnosticsTests {
    @Test
    func testDetectsRealInputPermissionLogWithoutProcessExit() {
        let output = """
        INFO: Renderer: metal
        [server] ERROR: Injecting to another application requires INJECT_EVENTS permission
        [server] ERROR: Make sure you have enabled "USB debugging (Security Settings)" and then rebooted your device.
        """
        #expect(SessionDiagnostics.inputPermissionDenied(output))
    }

    @Test
    func testAudioSecurityExceptionDoesNotClaimInputPermissionFailure() {
        #expect(!(SessionDiagnostics.inputPermissionDenied("java.lang.SecurityException: Audio capture not permitted")))
    }

    @Test
    func testAccumulatedChunksRecognizeSplitPermissionLog() {
        let chunks = ["[server] ERROR: requires INJECT_", "EVENTS permission"]
        #expect(!(SessionDiagnostics.inputPermissionDenied(chunks[0])))
        #expect(SessionDiagnostics.inputPermissionDenied(chunks.joined()))
    }
}
