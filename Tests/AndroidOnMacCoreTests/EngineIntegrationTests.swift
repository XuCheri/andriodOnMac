import Foundation
import Testing
@testable import AndroidOnMacCore

private func integrationEngine() -> EnginePaths? {
    if let located = EnginePaths.locate() { return located }
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let engine = EnginePaths(directory: repository.appendingPathComponent(".cache/engine"))
    return engine.isAvailable ? engine : nil
}

private func existingADBIsCompatible() throws -> Bool {
    let existing = try ADBServerProbe.version()
    return existing == nil || existing == 41
}

@Suite(.serialized)
struct EngineIntegrationTests {
    @Test(.enabled(if: integrationEngine() != nil, "Run scripts/fetch-engine.sh for bundled-engine integration"),
          .enabled(if: try existingADBIsCompatible(), "User-owned incompatible ADB is left untouched"))
    func testPinnedADBStartsAndOwnedServerIsCleanedUp() async throws {
        let engine = try #require(integrationEngine())
        let existing = try ADBServerProbe.version()
        try #require(existing == nil || existing == 41, "ADB changed after test eligibility was checked; leave it untouched")
        let supervisor = ProcessSupervisor()
        defer { supervisor.shutdown() }
        let adb = ADBService(paths: engine, processes: supervisor)
        _ = try await adb.devices()
        #expect(try ADBServerProbe.version() == 41)
        if existing == nil { #expect(supervisor.activeCount == 1) }
        else { #expect(supervisor.activeCount == 0, "An existing server must be reused, never owned") }
        supervisor.shutdown()
        for _ in 0..<40 {
            if supervisor.activeCount == 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(supervisor.activeCount == 0)
        if existing == nil { #expect(try ADBServerProbe.version() == nil) }
        else { #expect(try ADBServerProbe.version() == existing) }
    }
}
