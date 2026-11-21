import Darwin

/// Per-interface traffic using 64-bit counters from `NET_RT_IFLIST2`
/// (`getifaddrs` only exposes 32-bit counters that wrap at 4 GB).
final class NetworkSampler {
    private var previous: [String: (in: UInt64, out: UInt64)] = [:]
    private var previousTime: UInt64 = 0

    /// Interfaces that carry real traffic. Tunnels (utun, ipsec), bridges and
    /// loopback are listed but excluded from totals so VPN traffic isn't counted twice.
    static func countsTowardTotal(_ name: String) -> Bool {
        ["en", "pdp_ip", "awdl", "llw"].contains { name.hasPrefix($0) }
    }

    func sample() -> NetworkSnapshot {
        let now = MachTime.now()
        let elapsed = previousTime == 0 ? 0 : Double(now - previousTime) / 1e9
        previousTime = now

        let counters = Self.readCounters()
        let addresses = Self.readAddresses()
        var interfaces: [NetworkInterfaceStats] = []
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0, inRate = 0.0, outRate = 0.0
        var next: [String: (in: UInt64, out: UInt64)] = [:]

        for entry in counters {
            next[entry.name] = (entry.bytesIn, entry.bytesOut)
            let old = previous[entry.name]
            let rIn = old.map { rate(from: $0.in, to: entry.bytesIn, seconds: elapsed) } ?? 0
            let rOut = old.map { rate(from: $0.out, to: entry.bytesOut, seconds: elapsed) } ?? 0
            interfaces.append(NetworkInterfaceStats(name: entry.name, isUp: entry.isUp,
                                                    addresses: addresses[entry.name] ?? [],
                                                    bytesIn: entry.bytesIn, bytesOut: entry.bytesOut,
                                                    inRate: rIn, outRate: rOut))
            if Self.countsTowardTotal(entry.name) {
                totalIn += entry.bytesIn
                totalOut += entry.bytesOut
                inRate += rIn
                outRate += rOut
            }
        }
        previous = next
        // Active interfaces first, then by name.
        interfaces.sort { ($0.isUp && !$0.addresses.isEmpty ? 0 : 1, $0.name) < ($1.isUp && !$1.addresses.isEmpty ? 0 : 1, $1.name) }
        return NetworkSnapshot(inRate: inRate, outRate: outRate, totalIn: totalIn, totalOut: totalOut, interfaces: interfaces)
    }

    private struct Counter {
        let name: String
        let isUp: Bool
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    private static func readCounters() -> [Counter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }

        var result: [Counter] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(msg.ifm_index), &nameBuffer) != nil {
                        result.append(Counter(name: String(cBuffer: nameBuffer),
                                              isUp: msg.ifm_flags & IFF_UP != 0,
                                              bytesIn: msg.ifm_data.ifi_ibytes,
                                              bytesOut: msg.ifm_data.ifi_obytes))
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    private static func readAddresses() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: [String]] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            result[name, default: []].append(String(cBuffer: host))
        }
        return result
    }
}
