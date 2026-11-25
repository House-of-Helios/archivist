import Darwin
import Foundation
import IOKit

/// What kind of storage a path lives on. Decides how Archivist copies.
public enum DriveKind: String, Sendable, CaseIterable, Codable {
    case ssd          // SolidState = true
    case spinning     // SolidState = false
    case unknown      // nothing reported and the model name says nothing: treated like spinning (safe; sysinfo does the same)
    case network      // smbfs, afpfs, nfs, webdav

    /// Copy like a spinning disk: one reader, disk order.
    public var seeks: Bool { self == .spinning || self == .unknown }
}

/// The volume a path lives on, as macOS reports it.
public struct Drive: Sendable, Equatable {
    public let mountPoint: String
    public let fileSystem: String      // "apfs", "hfs", "exfat", "msdos", "smbfs", ...
    public let device: dev_t
    public let kind: DriveKind
    public let name: String

    public init(mountPoint: String, fileSystem: String, device: dev_t, kind: DriveKind, name: String) {
        self.mountPoint = mountPoint; self.fileSystem = fileSystem; self.device = device; self.kind = kind; self.name = name
    }

    /// APFS can clone within one volume (probe: clonefile ok only on APFS, same volume).
    public func canClone(to other: Drive) -> Bool { fileSystem == "apfs" && device == other.device }

    /// Timestamp slack when comparing modification dates (FAT family stores 2 s steps).
    public func mtimeWindow(with other: Drive) -> Double {
        let coarse: Set = ["exfat", "msdos"]
        if coarse.contains(fileSystem) || coarse.contains(other.fileSystem) { return 2 }
        if fileSystem == "apfs" && other.fileSystem == "apfs" { return 0 }
        return 1 // HFS+ and network shares keep whole seconds
    }

    /// Files and folders macOS keeps at a volume's root that are never backed up.
    public static let systemRootNames: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100",
        ".TemporaryItems", ".vol", ".PKInstallSandboxManager-SystemSoftware", ".MobileBackups",
    ]

    public static func of(path: String, override: DriveKind? = nil) throws -> Drive {
        var st = statfs()
        guard statfs(path, &st) == 0 else { throw ArchivistError.io("statfs", path, errno) }
        let fs = withUnsafeBytes(of: st.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let mount = withUnsafeBytes(of: st.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        var s = stat()
        guard stat(path, &s) == 0 else { throw ArchivistError.io("stat", path, errno) }
        let networkFS: Set = ["smbfs", "afpfs", "nfs", "webdav"]
        var kind: DriveKind = .unknown
        var name = (mount as NSString).lastPathComponent
        if networkFS.contains(fs) {
            kind = .network
        } else {
            let device = withUnsafeBytes(of: st.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let chars = deviceCharacteristics(bsdName: (device as NSString).lastPathComponent)
            // 1. What the drive itself reports. 2. Its model name. 3. Unknown: the app measures it.
            let byModel = kindFromModel(vendor: chars?["Vendor Name"] as? String, product: chars?["Product Name"] as? String)
            switch chars?["Medium Type"] as? String {
            case "Solid State"?: kind = .ssd
            // USB SSDs have been seen reporting "not solid state" (Samsung T7, Apple Community):
            // a model name that says SSD wins over that.
            case "Rotational"?: kind = byModel == .ssd ? .ssd : .spinning
            default: kind = byModel
            }
            if let info = diskutilInfo(mount) {
                if kind == .unknown, let ssd = info["SolidState"] as? Bool { kind = ssd ? .ssd : .spinning }
                name = (info["VolumeName"] as? String) ?? name
                // The Mac's own files live on its hidden Data volume: call it what Finder calls the drive.
                if mount == "/System/Volumes/Data", let boot = diskutilInfo("/")?["VolumeName"] as? String { name = boot }
            }
        }
        return Drive(mountPoint: mount, fileSystem: fs, device: s.st_dev, kind: override ?? kind, name: name)
    }

    /// The IORegistry's "Device Characteristics" of the storage device under a BSD name
    /// (`disk6s2`): Medium Type, Vendor Name, Product Name. Searched up through parents.
    static func deviceCharacteristics(bsdName: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let found = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault,
                                                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return found as? [String: Any]
    }

    /// When a USB case hides the medium, the model name usually tells: SSDs say so in their
    /// names; these families are spinning disks. Unknown stays unknown (the app measures it).
    public static func kindFromModel(vendor: String?, product: String?) -> DriveKind {
        let name = "\(vendor ?? "") \(product ?? "")".lowercased()
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return .unknown }
        let solid = ["ssd", "nvme", "solid state", "flash", "t7", "t9", "sandisk extreme", "extreme pro", "thunderbolt 3 pro"]
        if solid.contains(where: name.contains) { return .ssd }
        let spinning = ["my passport", "my book", "easystore", "elements", "wd_black p10", "wd black p10", "expansion",
                        "backup plus", "one touch hdd", "seagate basic", "lacie rugged", "lacie d2", "g-drive", "toshiba canvio", "canvio",
                        "lacie porsche", "lacie mobile", "hdd", "hard drive", "st1000", "st2000", "st4000", "st5000", "wd10", "wd20", "wd40", "wd50"]
        if spinning.contains(where: name.contains) { return .spinning }
        return .unknown
    }

    /// diskutil is a separate program (~0.2 s a call), asked per source: remember its answer for a minute.
    private static let cacheLock = NSLock()
    private static var cache: [String: (at: Date, info: [String: Any]?)] = [:]

    static func diskutilInfo(_ mount: String) -> [String: Any]? {
        cacheLock.lock()
        if let hit = cache[mount], Date().timeIntervalSince(hit.at) < 60 { cacheLock.unlock(); return hit.info }
        cacheLock.unlock()
        let info = diskutilInfoUncached(mount)
        cacheLock.lock(); cache[mount] = (Date(), info); cacheLock.unlock()
        return info
    }

    static func diskutilInfoUncached(_ mount: String) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", mount]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}

public enum ArchivistError: Error, CustomStringConvertible {
    case io(String, String, Int32)
    case refused(String)
    case changedDuringCopy(String)

    public var description: String {
        switch self {
        case let .io(call, path, e): return "\(call) \(path): \(String(cString: strerror(e)))"
        case let .refused(why): return why
        case let .changedDuringCopy(path): return "\(path): in use, copied next backup"
        }
    }
}
