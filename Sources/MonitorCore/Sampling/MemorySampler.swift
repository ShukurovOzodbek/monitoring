import Darwin

/// RAM breakdown matching Activity Monitor's Memory tab.
enum MemorySampler {
    static let totalMemory = Sysctl.uint64("hw.memsize") ?? 0

    static func sample() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .empty }

        let page = UInt64(Sysctl.int("vm.pagesize") ?? 16_384)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let free = UInt64(stats.free_count) * page

        var swap = xsw_usage()
        swap = Sysctl.value("vm.swapusage", initial: swap) ?? swap

        let pressure: MemoryPressure = switch Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: .critical
        case 2: .warning
        default: .normal
        }

        return MemorySnapshot(total: totalMemory, used: app + wired + compressed, app: app, wired: wired,
                              compressed: compressed, cachedFiles: cached, free: free,
                              swapUsed: swap.xsu_used, swapTotal: swap.xsu_total, pressure: pressure)
    }
}
