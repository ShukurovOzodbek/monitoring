import Darwin
import Foundation

/// Per-process network throughput from one-shot `nettop` snapshots.
///
/// A long-running `nettop -L 0` (streaming mode) burns ~140% CPU on its own, so
/// instead we run `nettop -L 1` (about 10 ms) at most every `minimumInterval` and
/// turn the difference between two snapshots of per-process byte counters into rates.
/// The process exits after each snapshot, so there's nothing to leak or babysit.
///
/// Not thread-safe; owned by `SystemSampler`.
final class ProcessNetworkMonitor {
    static let minimumInterval: TimeInterval = 2

    private var previous: [Int32: (in: UInt64, out: UInt64)] = [:]
    private var previousTime: UInt64 = 0
    private(set) var rates: [Int32: (in: Double, out: Double)] = [:]

    /// Refreshes `rates` if the last snapshot is old enough; otherwise keeps the last rates.
    func update() {
        let now = MachTime.now()
        let elapsed = previousTime == 0 ? 0 : Double(now - previousTime) / 1e9
        if previousTime != 0 && elapsed < Self.minimumInterval { return }
        guard let output = Shell.captureStdout("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]) else {
            return
        }
        let counters = NettopParser.parseSnapshot(output)
        if previousTime != 0 {
            rates = NettopParser.rates(from: previous, to: counters, seconds: elapsed)
        }
        previous = counters
        previousTime = now
    }
}

/// Parsing for `nettop -P -L 1 -x -J bytes_in,bytes_out` output:
///
///     ,bytes_in,bytes_out,
///     Safari.900,1000,200,
enum NettopParser {
    /// Byte counters per pid. Rows are "name.pid"; names may contain dots.
    static func parseSnapshot(_ output: String) -> [Int32: (in: UInt64, out: UInt64)] {
        var result: [Int32: (in: UInt64, out: UInt64)] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(",") else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = UInt64(fields[1]),
                  let bytesOut = UInt64(fields[2]) else { continue }
            let existing = result[pid] ?? (0, 0)
            result[pid] = (existing.in + bytesIn, existing.out + bytesOut)
        }
        return result
    }

    /// Per-second rates between two snapshots. Counters drop when connections
    /// close; that counts as 0 rather than a negative rate.
    static func rates(from old: [Int32: (in: UInt64, out: UInt64)], to new: [Int32: (in: UInt64, out: UInt64)],
                      seconds: Double) -> [Int32: (in: Double, out: Double)] {
        guard seconds > 0 else { return [:] }
        var result: [Int32: (in: Double, out: Double)] = [:]
        for (pid, counters) in new {
            guard let before = old[pid] else { continue }
            let rIn = rate(from: before.in, to: counters.in, seconds: seconds)
            let rOut = rate(from: before.out, to: counters.out, seconds: seconds)
            if rIn > 0 || rOut > 0 { result[pid] = (rIn, rOut) }
        }
        return result
    }
}
