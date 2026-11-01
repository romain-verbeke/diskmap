import AppKit
import DiskMapCore

/// Something the start screen offers to scan.
struct ScanTarget: Identifiable {
    let path: String
    let name: String
    /// Capacity details, for volumes only.
    let detail: String?
    let usedFraction: Double?

    var id: String { path }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
}

enum ScanTargets {
    /// Mounted volumes the user can see, with the startup disk first.
    static func volumes() -> [ScanTarget] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        return urls.map { url -> ScanTarget in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent
            guard let total = values?.volumeTotalCapacity, total > 0 else {
                return ScanTarget(path: url.path, name: name, detail: nil, usedFraction: nil)
            }
            let free = values?.volumeAvailableCapacityForImportantUsage
                ?? Int64(values?.volumeAvailableCapacity ?? 0)
            let used = max(Int64(total) - free, 0)
            return ScanTarget(
                path: url.path, name: name,
                detail: "\(formatBytes(UInt64(used))) of \(formatBytes(UInt64(total))) used",
                usedFraction: Double(used) / Double(total))
        }
        .sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }

    /// Common starting folders that exist on this Mac.
    static func folders() -> [ScanTarget] {
        let home = NSHomeDirectory()
        let paths = [home, home + "/Downloads", home + "/Documents", home + "/Desktop", "/Applications"]
        return paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { path in
                ScanTarget(path: path, name: FileManager.default.displayName(atPath: path), detail: nil, usedFraction: nil)
            }
    }
}
