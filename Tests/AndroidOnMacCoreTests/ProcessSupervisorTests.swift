import Foundation
import Testing
@testable import AndroidOnMacCore

@Suite(.serialized)
struct ProcessSupervisorTests {
    @Test
    func testCapturesBothStreamsAndExitStatus() async throws {
        let runner = ProcessSupervisor()
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf output; printf error >&2; exit 7"])
        #expect(result.exitCode == 7)
        #expect(result.stdout == "output")
        #expect(result.stderr == "error")
        #expect(runner.activeCount == 0)
    }

    @Test
    func testInputDeliveredThroughStdin() async throws {
        let result = try await ProcessSupervisor().run(executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [], input: "test input\n")
        #expect(result.stdout == "test input\n")
    }

    @Test
    func testArgumentsRemainLiteral() async throws {
        let literal = "$(touch never-created); `echo nope` & spaced value"
        let result = try await ProcessSupervisor().run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", literal])
        #expect(result.stdout == literal)
    }

    @Test
    func testTimeoutReapsOwnedProcess() async throws {
        let runner = ProcessSupervisor()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
            Issue.record("Expected timeout")
        } catch ProcessFailure.timedOut { }
        #expect(runner.activeCount == 0)
    }

    @Test
    func testTaskCancellationReapsOwnedProcess() async throws {
        let runner = ProcessSupervisor()
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch ProcessFailure.cancelled { }
        catch is CancellationError { }
        #expect(runner.activeCount == 0)
    }

    @Test
    func testTerminateAllDoesNotStopUnownedProcess() async throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["10"]
        try other.run()
        defer { if other.isRunning { other.terminate() }; other.waitUntilExit() }
        let runner = ProcessSupervisor()
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        runner.terminateAll()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch ProcessFailure.cancelled { }
        #expect(other.isRunning)
        #expect(runner.activeCount == 0)
    }

    @Test
    func testMissingExecutableLeavesNoTrackedChild() async {
        let runner = ProcessSupervisor()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/nonexistent/androidonmac-test"), arguments: [])
            Issue.record("Expected launch failure")
        } catch { }
        #expect(runner.activeCount == 0)
    }

    @Test
    func testOutputRetentionIsBounded() async throws {
        let result = try await ProcessSupervisor().run(executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i = 0; i < 200000; i++) printf \"a\" }"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 128 * 1024)
    }

    @Test
    func testEngineUsesTheProbedLocalServer() {
        let paths = EnginePaths(directory: URL(fileURLWithPath: "/test/engine"))
        #expect(paths.environment["ADB_SERVER_SOCKET"] == "tcp:127.0.0.1:5037")
        #expect(paths.environment["ANDROID_ADB_SERVER_PORT"] == "5037")
    }

    @Test
    func testShutdownRejectsWorkThatResumesLater() async {
        let runner = ProcessSupervisor()
        runner.shutdown()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["late work"])
            Issue.record("Closed supervisor must reject new work")
        } catch ProcessFailure.cancelled { }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(runner.activeCount == 0)
    }
}
