import XCTest
@testable import AndroidOnMacCore

final class ProcessSupervisorTests: XCTestCase {
    func testCapturesBothStreamsAndExitStatus() async throws {
        let runner = ProcessSupervisor()
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf output; printf error >&2; exit 7"])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "output")
        XCTAssertEqual(result.stderr, "error")
        XCTAssertEqual(runner.activeCount, 0)
    }

    func testInputDeliveredThroughStdin() async throws {
        let result = try await ProcessSupervisor().run(executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [], input: "test input\n")
        XCTAssertEqual(result.stdout, "test input\n")
    }

    func testArgumentsRemainLiteral() async throws {
        let literal = "$(touch never-created); `echo nope` & spaced value"
        let result = try await ProcessSupervisor().run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", literal])
        XCTAssertEqual(result.stdout, literal)
    }

    func testTimeoutReapsOwnedProcess() async throws {
        let runner = ProcessSupervisor()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch ProcessFailure.timedOut { }
        XCTAssertEqual(runner.activeCount, 0)
    }

    func testTaskCancellationReapsOwnedProcess() async throws {
        let runner = ProcessSupervisor()
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch ProcessFailure.cancelled { }
        catch is CancellationError { }
        XCTAssertEqual(runner.activeCount, 0)
    }

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
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch ProcessFailure.cancelled { }
        XCTAssertTrue(other.isRunning)
        XCTAssertEqual(runner.activeCount, 0)
    }

    func testMissingExecutableLeavesNoTrackedChild() async {
        let runner = ProcessSupervisor()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/nonexistent/androidonmac-test"), arguments: [])
            XCTFail("Expected launch failure")
        } catch { }
        XCTAssertEqual(runner.activeCount, 0)
    }

    func testOutputRetentionIsBounded() async throws {
        let result = try await ProcessSupervisor().run(executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i = 0; i < 200000; i++) printf \"a\" }"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 128 * 1024)
    }

    func testEngineUsesTheProbedLocalServer() {
        let paths = EnginePaths(directory: URL(fileURLWithPath: "/test/engine"))
        XCTAssertEqual(paths.environment["ADB_SERVER_SOCKET"], "tcp:127.0.0.1:5037")
        XCTAssertEqual(paths.environment["ANDROID_ADB_SERVER_PORT"], "5037")
    }
}
