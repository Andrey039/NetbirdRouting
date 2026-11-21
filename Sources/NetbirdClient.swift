import Foundation

struct CommandResult {
    let code: Int32
    let output: String
    var succeeded: Bool { code == 0 }
}

protocol NetbirdRunning {
    /// Completion is delivered on the main thread.
    func run(_ arguments: [String], completion: @escaping (CommandResult) -> Void)
}

final class NetbirdClient: NetbirdRunning {
    let executable: String
    let timeout: TimeInterval

    init(executable: String = ProcessInfo.processInfo.environment["NETBIRD_BIN"] ?? "/usr/local/bin/netbird",
         timeout: TimeInterval = 15) {
        self.executable = executable
        self.timeout = timeout
    }

    func run(_ arguments: [String], completion: @escaping (CommandResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(CommandResult(code: -1, output: error.localizedDescription)) }
                return
            }

            // A stuck CLI must not permanently block polling or queued actions.
            let deadline = ProcessDeadline(process: process)
            let timer = DispatchWorkItem { deadline.expire() }
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeout, execute: timer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let timedOut = deadline.finish()
            timer.cancel()
            let result = CommandResult(code: timedOut ? -2 : process.terminationStatus,
                                       output: timedOut ? "NetBird CLI timeout (\(self.timeout)s)" : String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Synchronizes completion with the watchdog; never signals a completed process.
private final class ProcessDeadline {
    private let lock = NSLock()
    private let process: Process
    private var finished = false
    private var timedOut = false

    init(process: Process) { self.process = process }

    func expire() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, process.isRunning else { return }
        timedOut = true
        // SIGKILL also handles a CLI that ignores SIGTERM.
        kill(process.processIdentifier, SIGKILL)
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        return timedOut
    }
}
