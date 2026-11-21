import Foundation
import IOKit
import IOKit.ps

/// Battery state from IOPowerSources plus health details from the
/// `AppleSmartBattery` registry entry.
enum BatterySampler {
    /// nil when the Mac has no internal battery.
    static func sample() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let description = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let description else { return nil }

        let current = (description[kIOPSCurrentCapacityKey] as? Int) ?? 0
        let maxPercent = (description[kIOPSMaxCapacityKey] as? Int) ?? 100
        let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
        let source: PowerSource = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue ? .ac : .battery
        func minutes(_ key: String) -> Int? {
            guard let value = description[key] as? Int, value >= 0 else { return nil }
            return value
        }

        let smart = smartBatteryProperties()
        func int(_ key: String) -> Int? { (smart[key] as? NSNumber).map { Int($0.int64Value) } }
        let design = int("DesignCapacity")
        let maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        let health: Double? = if let design, let maxCapacity, design > 0 {
            min(100, Double(maxCapacity) / Double(design) * 100)
        } else { nil }
        // Amperage is stored as an unsigned 64-bit value; int64Value restores the sign.
        let amperage = int("InstantAmperage") ?? int("Amperage")

        var adapterWatts: Int?
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
        }

        return BatterySnapshot(
            level: maxPercent > 0 ? Double(current) / Double(maxPercent) * 100 : Double(current),
            isCharging: isCharging,
            isFullyCharged: (description[kIOPSIsChargedKey] as? Bool) ?? false,
            powerSource: source,
            minutesToEmpty: source == .battery ? minutes(kIOPSTimeToEmptyKey) : nil,
            minutesToFull: isCharging ? minutes(kIOPSTimeToFullChargeKey) : nil,
            cycleCount: int("CycleCount"),
            designCapacity: design,
            maxCapacity: maxCapacity,
            currentCapacity: int("AppleRawCurrentCapacity"),
            health: health,
            temperatureCelsius: int("Temperature").map { Double($0) / 100 },
            voltage: int("Voltage").map { Double($0) / 1000 },
            amperage: amperage.map { Double($0) / 1000 },
            adapterWatts: adapterWatts,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return (properties?.takeRetainedValue() as? [String: Any]) ?? [:]
    }
}
