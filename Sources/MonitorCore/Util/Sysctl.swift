import Darwin

/// Thin wrappers over `sysctlbyname`.
enum Sysctl {
    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var value: Int32 = 0
            var len = 4
            guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
            return Int(value)
        case 8:
            var value: Int64 = 0
            var len = 8
            guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
            return Int(value)
        default:
            return nil
        }
    }

    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
        return value
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buffer)
    }

    static func value<T: BitwiseCopyable>(_ name: String, initial: T) -> T? {
        var value = initial
        var len = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
        return value
    }
}

/// Converts mach absolute time units (used by `proc_pid_rusage` and
/// processor tick counters on Apple Silicon) into nanoseconds.
enum MachTime {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        let numer = UInt64(timebase.numer), denom = UInt64(timebase.denom)
        if numer == denom { return ticks }
        // Split to avoid overflow on large tick counts.
        return (ticks / denom) * numer + (ticks % denom) * numer / denom
    }

    /// Monotonic clock in nanoseconds (does not advance while asleep).
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// Per-second rate from two monotonically increasing counters. Counter resets
/// (interface reset, pid reuse) yield 0 instead of a huge negative spike.
@inline(__always)
func rate(from old: UInt64, to new: UInt64, seconds: Double) -> Double {
    guard new >= old, seconds > 0 else { return 0 }
    return Double(new - old) / seconds
}

extension String {
    /// Decodes a NUL-terminated C buffer, ignoring bytes after the terminator.
    init(cBuffer buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}
