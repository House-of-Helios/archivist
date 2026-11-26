import Foundation

/// How an update goes in. While the app still runs, the new build is copied
/// in beside it under a hidden name and checked; then the two bundles' `Contents` trade
/// places by one atomic rename (the bundle folder stays, so the Dock keeps its icon), the old
/// contents are deleted, and the app is opened again. Nothing is left behind and nothing shows: no helper script, no
/// "(previous)" copy, no second app in Applications.
///
/// This type is the part that touches the disk by name, so it can be tested on fake
/// bundles; copying (`ditto`), checking (`codesign`) and opening live with the app.
public enum AppSwap {

    /// Where the new build is copied while the app runs: `.Archivist.app.update`.
    public static func stagedURL(for installed: URL) -> URL {
        installed.deletingLastPathComponent().appendingPathComponent(".\(installed.lastPathComponent).update")
    }

    /// Where the running bundle steps aside for the moment of the swap: `.Archivist.app.old`.
    public static func oldURL(for installed: URL) -> URL {
        installed.deletingLastPathComponent().appendingPathComponent(".\(installed.lastPathComponent).old")
    }

    /// Anything an update left beside the app — a swap cut short, or the copy the old
    /// shell helper kept as `Archivist (previous).app`. Cleared at every launch.
    public static func leftovers(for installed: URL) -> [URL] {
        let name = installed.deletingPathExtension().lastPathComponent
        let previous = installed.deletingLastPathComponent()
            .appendingPathComponent("\(name) (previous)").appendingPathExtension("app")
        return [stagedURL(for: installed), oldURL(for: installed), previous]
    }

    public enum Failure: Error, Equatable {
        /// The running app couldn't step aside; nothing changed.
        case couldNotMoveAside
        /// The new build couldn't take the name; the running app was put back.
        case couldNotMoveIn
    }

    /// The new build (already copied to `staged` and checked) goes in; the old one is deleted.
    /// The bundle folder itself stays: only its `Contents` trade places, in one atomic
    /// `renamex_np(RENAME_SWAP)`. The Dock (and Finder aliases) know an app by its folder's file
    /// identity, so swapping whole bundles left the Dock icon on the deleted copy and the new one
    /// came up as a second icon. On any failure the installed app is left as it was.
    public static func swap(installed: URL, staged: URL, fileManager fm: FileManager = .default) throws {
        let new = staged.appendingPathComponent("Contents"), current = installed.appendingPathComponent("Contents")
        guard fm.fileExists(atPath: new.path) else {
            try? fm.removeItem(at: staged)
            throw Failure.couldNotMoveIn
        }
        guard renamex_np(new.path, current.path, UInt32(RENAME_SWAP)) == 0 else {
            try? fm.removeItem(at: staged)
            throw Failure.couldNotMoveIn
        }
        try? fm.removeItem(at: staged)   // now holds the old Contents
        // Finder and Launch Services see the folder's date change and read the new Info.plist.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: installed.path)
    }

    /// Clears whatever `leftovers` finds. Returns what was removed.
    @discardableResult
    public static func clearLeftovers(for installed: URL, fileManager fm: FileManager = .default) -> [URL] {
        leftovers(for: installed).filter { fm.fileExists(atPath: $0.path) && (try? fm.removeItem(at: $0)) != nil }
    }
}
