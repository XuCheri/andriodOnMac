import Darwin
import Foundation
import Testing
@testable import AndroidOnMacCore

@Suite(.serialized)
struct ProcessLauncherTests {
    private var helper: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/ProcessLauncher")
    }

    @Test func timeoutCleansInheritedPipesWithoutTouchingAnUnrelatedProcess() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["10"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }

        let supervisor = ProcessSupervisor()
        defer { supervisor.shutdown() }
        let observation = ProcessObservation()
        let started = ProcessInfo.processInfo.systemUptime
        let child = try supervisor.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "trap '' TERM; /bin/sh -c 'trap \"\" TERM; printf \"%s\" $$ > \"$1\"; printf inherited-output; printf inherited-error >&2; exec /bin/sleep 5' descendant \"$1\" & wait",
            "root", pidFile.path
        ], environment: ["ANDROIDONMAC_PROCESS_LAUNCHER": helper.path], timeout: 1,
           output: { observation.append($0) }, completion: { observation.complete($0) })
        defer { child.stop() }
        let completed = await waitUntil { observation.result != nil }
        #expect(completed, "Inherited stdout/stderr must not block completion")
        #expect(ProcessInfo.processInfo.systemUptime - started < 3)
        guard let result = observation.result else { return }
        if case .failure(ProcessFailure.timedOut) = result {} else { Issue.record("Expected timedOut, got \(result)") }
        // Read the fixture identity independently of the interleaved stdout and
        // stderr callbacks; the timeout also leaves room for loaded CI startup.
        let descendant = try #require(readPID(pidFile))
        let reaped = await waitUntil { !isAlive(descendant) }
        #expect(reaped, "The owned child group must be gone after timeout")
        #expect(unrelated.isRunning, "Unrelated caller-owned processes must survive")
        #expect(supervisor.activeCount == 0)
    }

    @Test func taskCancellationCleansAChildThatIgnoresTermination() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let supervisor = ProcessSupervisor()
        defer { supervisor.shutdown() }
        let observation = ProcessObservation()
        let task = Task {
            do {
                let result = try await supervisor.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
                    "-c", "trap '' TERM; /bin/sh -c 'trap \"\" TERM; printf \"%s\" $$ > \"$1\"; exec /bin/sleep 5' descendant \"$1\" & wait",
                    "root", pidFile.path
                ], environment: ["ANDROIDONMAC_PROCESS_LAUNCHER": helper.path], timeout: 8)
                observation.complete(.success(result))
            } catch { observation.complete(.failure(error)) }
        }
        let ready = await waitUntil { readPID(pidFile) != nil }
        #expect(ready)
        let descendant = try #require(readPID(pidFile))
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let completed = await waitUntil { observation.result != nil }
        #expect(completed)
        #expect(ProcessInfo.processInfo.systemUptime - started < 3)
        if let result = observation.result {
            if case .failure(ProcessFailure.cancelled) = result {} else { Issue.record("Expected cancelled, got \(result)") }
        }
        let reaped = await waitUntil { !isAlive(descendant) }
        #expect(reaped)
        #expect(supervisor.activeCount == 0)
    }

    @Test func normalExitReapsLeftoversAndPreservesOutputAndExitCode() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let supervisor = ProcessSupervisor()
        defer { supervisor.shutdown() }
        let observation = ProcessObservation()
        let child = try supervisor.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "/bin/sh -c 'trap \"\" TERM; printf \"%s\" $$ > \"$1\"; exec /bin/sleep 5' descendant \"$1\" & while [ ! -s \"$1\" ]; do /bin/sleep 0.01; done; printf root-done; printf root-error >&2; exit 7",
            "root", pidFile.path
        ], environment: ["ANDROIDONMAC_PROCESS_LAUNCHER": helper.path], timeout: 4,
           output: { observation.append($0) }, completion: { observation.complete($0) })
        defer { child.stop() }
        let completed = await waitUntil { observation.result != nil }
        #expect(completed)
        guard let outcome = observation.result else { return }
        let result = try outcome.get()
        #expect(result.exitCode == 7)
        #expect(result.stdout.contains("root-done"))
        #expect(result.stderr == "root-error")
        let descendant = try #require(readPID(pidFile))
        let reaped = await waitUntil { !isAlive(descendant) }
        #expect(reaped)
        #expect(supervisor.activeCount == 0)
    }

    @Test func missingHelperStillBoundsPipeDrainAndDoesNotClaimDescendantOwnership() async throws {
        let supervisor = ProcessSupervisor()
        defer { supervisor.shutdown() }
        let observation = ProcessObservation()
        let started = ProcessInfo.processInfo.systemUptime
        let child = try supervisor.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "/bin/sleep 2 & printf 'DESCENDANT:%s\n' \"$!\"; printf root-done"
        ], environment: ["ANDROIDONMAC_PROCESS_LAUNCHER": "/nonexistent/no-process-launcher"],
           timeout: 5, output: { observation.append($0) }, completion: { observation.complete($0) })
        defer { child.stop() }
        let completed = await waitUntil { observation.result != nil }
        #expect(completed)
        #expect(ProcessInfo.processInfo.systemUptime - started < 1.5,
                "Direct-child fallback must not wait for an inherited pipe's EOF")
        guard let outcome = observation.result else { return }
        let result = try outcome.get()
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("root-done"))
        let descendant = try #require(observation.descendantPID)
        #expect(isAlive(descendant), "Without a helper, only the direct child is owned")
        // This test-owned, two-second sleeper exits naturally; no process-name
        // search, global ADB shutdown, or signaling a possibly recycled PID.
        let naturallyFinished = await waitUntil { !isAlive(descendant) }
        #expect(naturallyFinished)
        #expect(supervisor.activeCount == 0)
    }

    @Test func terminalPublishesNativeStdioBeforeExitWithoutEchoingInput() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("stdio.c")
        let executable = directory.appendingPathComponent("stdio-fixture")
        try """
        #include <stdio.h>
        #include <unistd.h>
        int main(void) {
            char input[80];
            if (!fgets(input, sizeof(input), stdin)) return 2;
            fprintf(stdout, "INFO: Renderer: test\\n");
            fprintf(stderr, "WARN: separate\\n");
            sleep(2);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let supervisor = ProcessSupervisor()
        defer { supervisor.shutdown() }
        let compiled = try await supervisor.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["clang", source.path, "-o", executable.path], timeout: 15)
        try #require(compiled.exitCode == 0)
        let observation = ProcessObservation()
        let child = try supervisor.launch(executable: executable, arguments: [],
            environment: ["ANDROIDONMAC_PROCESS_LAUNCHER": helper.path],
            input: "private-test-input\n", timeout: 5, outputMode: .lineBufferedTerminal,
            output: { observation.append($0) }, completion: { observation.complete($0) })
        defer { child.stop() }
        let receivedBeforeExit = await waitUntil(timeout: 1) { observation.output.contains("INFO: Renderer: test\n") }
        #expect(receivedBeforeExit, "Native stdio must publish a complete readiness line before process exit")
        #expect(child.isRunning)
        #expect(!observation.output.contains("private-test-input"))
        let completed = await waitUntil { observation.result != nil }
        #expect(completed)
        guard let outcome = observation.result else { return }
        let result = try outcome.get()
        #expect(result.exitCode == 0)
        #expect(result.stdout == "INFO: Renderer: test\n")
        #expect(result.stderr == "WARN: separate\n")
        #expect(supervisor.activeCount == 0)
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private func readPID(_ file: URL) -> Int32? {
        guard let contents = try? String(contentsOf: file) else { return nil }
        return Int32(contents)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

private final class ProcessObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var outcome: Result<ProcessResult, Error>?

    func append(_ value: String) { lock.lock(); text += value; lock.unlock() }
    func complete(_ value: Result<ProcessResult, Error>) { lock.lock(); outcome = value; lock.unlock() }
    var result: Result<ProcessResult, Error>? { lock.lock(); defer { lock.unlock() }; return outcome }
    var output: String { lock.lock(); defer { lock.unlock() }; return text }
    var descendantPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let marker = text.range(of: "DESCENDANT:") else { return nil }
        let digits = text[marker.upperBound...].prefix { $0.isNumber }
        return Int32(digits)
    }
}
