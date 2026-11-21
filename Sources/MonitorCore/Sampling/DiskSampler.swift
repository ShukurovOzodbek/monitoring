import Foundation
import IOKit

/// Disk read/write throughput, summed over all block storage drivers.
final class DiskSampler {
    private struct Totals {
        var read: UInt64 = 0, written: UInt64 = 0, readOps: UInt64 = 0, writeOps: UInt64 = 0
    }

    private var previous: Totals?
    private var previousTime: UInt64 = 0

    func sample() -> DiskSnapshot {
        let now = MachTime.now()
        let elapsed = previousTime == 0 ? 0 : Double(now - previousTime) / 1e9
        previousTime = now
        let totals = Self.readTotals()
        defer { previous = totals }
        guard let old = previous else {
            return DiskSnapshot(readRate: 0, writeRate: 0, readOpsRate: 0, writeOpsRate: 0,
                                totalRead: totals.read, totalWritten: totals.written)
        }
        return DiskSnapshot(readRate: rate(from: old.read, to: totals.read, seconds: elapsed),
                            writeRate: rate(from: old.written, to: totals.written, seconds: elapsed),
                            readOpsRate: rate(from: old.readOps, to: totals.readOps, seconds: elapsed),
                            writeOpsRate: rate(from: old.writeOps, to: totals.writeOps, seconds: elapsed),
                            totalRead: totals.read, totalWritten: totals.written)
    }

    private static func readTotals() -> Totals {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return Totals()
        }
        defer { IOObjectRelease(iterator) }
        var totals = Totals()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            func value(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            totals.read += value("Bytes (Read)")
            totals.written += value("Bytes (Write)")
            totals.readOps += value("Operations (Read)")
            totals.writeOps += value("Operations (Write)")
        }
        return totals
    }
}
