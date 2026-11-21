import Darwin

/// Whole-machine and per-core CPU usage from `host_processor_info` tick deltas.
final class CPUSampler {
    private struct Ticks {
        var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
        var total: UInt64 { user + system + idle + nice }
    }

    private var previous: [Ticks] = []
    let performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? Sysctl.int("hw.logicalcpu") ?? 0
    let efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0

    func sample(processCount: Int, threadCount: Int) -> CPUSnapshot {
        let current = Self.readTicks()
        defer { previous = current }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        guard previous.count == current.count, !current.isEmpty else {
            return CPUSnapshot(user: 0, system: 0, idle: 100,
                               cores: current.indices.map { CoreUsage(index: $0, user: 0, system: 0) },
                               loadAverage: loads, performanceCoreCount: performanceCores,
                               efficiencyCoreCount: efficiencyCores, processCount: processCount, threadCount: threadCount)
        }

        var cores: [CoreUsage] = []
        var sumUser: UInt64 = 0, sumSystem: UInt64 = 0, sumTotal: UInt64 = 0
        for (index, (now, old)) in zip(current, previous).enumerated() {
            // Counters are 32-bit in the kernel and can wrap; treat a wrap as no activity.
            let user = delta(now.user, old.user) + delta(now.nice, old.nice)
            let system = delta(now.system, old.system)
            let total = user + system + delta(now.idle, old.idle)
            sumUser += user
            sumSystem += system
            sumTotal += total
            cores.append(CoreUsage(index: index,
                                   user: total == 0 ? 0 : Double(user) / Double(total) * 100,
                                   system: total == 0 ? 0 : Double(system) / Double(total) * 100))
        }
        let user = sumTotal == 0 ? 0 : Double(sumUser) / Double(sumTotal) * 100
        let system = sumTotal == 0 ? 0 : Double(sumSystem) / Double(sumTotal) * 100
        return CPUSnapshot(user: user, system: system, idle: max(0, 100 - user - system), cores: cores,
                           loadAverage: loads, performanceCoreCount: performanceCores,
                           efficiencyCoreCount: efficiencyCores, processCount: processCount, threadCount: threadCount)
    }

    private func delta(_ new: UInt64, _ old: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    private static func readTicks() -> [Ticks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * states
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            return Ticks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                         idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }
}
