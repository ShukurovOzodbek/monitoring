import Foundation

/// Runs short-lived command-line tools and captures their output.
enum Shell {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `executable` synchronously. Call from a background context.
    static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting so a full pipe buffer can't deadlock the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Fast path for hot loops: `posix_spawn` + read stdout. Foundation's `Process`
    /// adds ~70 ms of overhead per launch, which matters when we spawn every second.
    static func captureStdout(_ executable: String, _ arguments: [String]) -> String? {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return nil }
        let readFD = pipeFDs[0], writeFD = pipeFDs[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, nil, argv, environ)
        close(writeFD)
        guard spawned == 0 else {
            close(readFD)
            return nil
        }
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(readFD, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer[0..<count]) }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
        close(readFD)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return String(decoding: output, as: UTF8.self)
    }

    /// Runs off the calling actor so UI stays responsive.
    static func runAsync(_ executable: String, _ arguments: [String]) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try run(executable, arguments)
        }.value
    }

    /// Runs a shell command as root through the standard macOS admin password
    /// prompt. Throws `AdminCommandError.cancelled` if the user dismisses it.
    static func runAsAdministrator(_ command: String) async throws -> Result {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = try await runAsync("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            if result.stderr.contains("-128") { throw AdminCommandError.cancelled }
            throw AdminCommandError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}

public enum AdminCommandError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "The administrator prompt was cancelled."
        case .failed(let message): message.isEmpty ? "The command failed." : message
        }
    }
}
