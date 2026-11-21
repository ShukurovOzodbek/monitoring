import Darwin
import Foundation

/// Per-process network throughput from a long-running `nettop` in delta mode.
///
/// nettop block-buffers its output when writing to a pipe (about 18 s of delay),
/// so it runs on a pseudo-terminal, where it flushes every line. Each block
/// starts with a CSV header line. The first block holds cumulative totals and
/// is skipped. Each later block holds the bytes moved during the last second.
final class ProcessNetworkMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [Int32: (in: Double, out: Double)] = [:]
    private var process: Process?
    private var running = false

    /// Most recent per-second rates keyed by pid.
    var rates: [Int32: (in: Double, out: Double)] {
        lock.withLock { latest }
    }

    func start() {
        lock.withLock {
            guard !running else { return }
            running = true
        }
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "ProcessNetworkMonitor"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        let proc: Process? = lock.withLock {
            running = false
            latest = [:]
            return process
        }
        proc?.terminate()
    }

    private var isRunning: Bool { lock.withLock { running } }

    /// nettop ignores the pty closing, so it would outlive the app (and leak one
    /// nettop per launch) whenever the app exits. This wrapper kills it when the
    /// app process is gone, even after a crash or kill -9, or when it's told to stop.
    static let watchdogScript = """
    /usr/bin/nettop -P -L 0 -d -s 1 -x -J bytes_in,bytes_out & n=$!
    trap 'kill $n 2>/dev/null; exit 0' TERM INT HUP
    while kill -0 "$PPID" 2>/dev/null && kill -0 "$n" 2>/dev/null; do sleep 1; done
    kill $n 2>/dev/null
    """

    private func runLoop() {
        while isRunning {
            runNettopOnce()
            if isRunning { Thread.sleep(forTimeInterval: 2) } // restart backoff
        }
    }

    private func runNettopOnce() {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", Self.watchdogScript]
        proc.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            close(master)
            close(slave)
            return
        }
        lock.withLock { process = proc }
        close(slave) // child keeps its copy; EOF on master once nettop exits

        var parser = NettopParser()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Data()
        while isRunning {
            let count = read(master, &buffer, buffer.count)
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if let block = parser.consume(line) {
                    lock.withLock { latest = block }
                }
            }
        }
        close(master)
        if proc.isRunning { proc.terminate() }
        proc.waitUntilExit()
        lock.withLock { process = nil }
    }
}

/// Line-oriented parser for `nettop -P -d -x -J bytes_in,bytes_out` output.
struct NettopParser {
    private var blockIndex = 0
    private var current: [Int32: (in: Double, out: Double)] = [:]

    /// Feed one line. Returns a finished delta block when a new header begins.
    mutating func consume(_ rawLine: String) -> [Int32: (in: Double, out: Double)]? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix(",") { // header: ",bytes_in,bytes_out,"
            defer {
                blockIndex += 1
                current = [:]
            }
            // Block 1 is cumulative since flows opened; only later blocks are deltas.
            return blockIndex >= 2 ? current : nil
        }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3,
              let dot = fields[0].lastIndex(of: "."),
              let pid = Int32(fields[0][fields[0].index(after: dot)...]),
              let bytesIn = Double(fields[1]),
              let bytesOut = Double(fields[2]) else { return nil }
        let existing = current[pid] ?? (0, 0)
        current[pid] = (existing.in + bytesIn, existing.out + bytesOut)
        return nil
    }
}
