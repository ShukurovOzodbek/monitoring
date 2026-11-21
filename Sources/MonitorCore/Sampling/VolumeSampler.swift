import Foundation

/// Storage capacity of mounted, user-visible volumes.
enum VolumeSampler {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsRootFileSystemKey, .volumeLocalizedFormatDescriptionKey,
    ]

    static func sample() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let available = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? available
            return VolumeInfo(name: values.volumeName ?? url.lastPathComponent,
                              mountPath: url.path,
                              fileSystem: values.volumeLocalizedFormatDescription ?? "",
                              total: UInt64(total),
                              available: available,
                              availableIncludingPurgeable: max(important, available),
                              isInternal: values.volumeIsInternal ?? false,
                              isRemovable: values.volumeIsRemovable ?? false,
                              isRoot: values.volumeIsRootFileSystem ?? false)
        }
        return volumes.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }
}
