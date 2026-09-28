import Foundation
import HrafnStore

/// Where the app and its extensions keep what they share: the database and
/// the per-account locks, in the App Group container.
public struct SharedContainer: Sendable {

    /// Hrafn's App Group, on the app and every extension.
    public static let hrafnAppGroup = "group.dev.stevedylandev.hrafn"

    /// The App Group, or `nil` when the capability is missing (a build without
    /// signing): everything then lives in the app's own container, and the
    /// extension cannot see it.
    public let appGroup: String?
    public let root: URL

    public init(appGroup: String?) {
        self.appGroup = appGroup
        root = appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? URL.applicationSupportDirectory
    }

    /// Whether the App Group container is really in use.
    public var isShared: Bool {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) } != nil
    }

    public var databaseURL: URL { root.appending(path: "Hrafn.sqlite") }
    /// OMEMO state, in a directory of its own that is excluded from backups
    /// (`OMEMODatabase`).
    public var omemoDirectory: URL { root.appending(path: "OMEMO") }
    public var lockDirectory: URL { root.appending(path: "Locks") }
    /// Shared files and avatars.
    public var media: MediaStore { MediaStore(root: root) }

    /// Moves a database created before the App Group existed (Phase 4 kept it
    /// in Application Support) into the shared container, once.
    public func migrateLegacyDatabase() throws {
        guard isShared else { return }
        let legacy = URL.applicationSupportDirectory.appending(path: "Hrafn.sqlite")
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: databaseURL.path) else { return }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: legacy.path + suffix)
            guard manager.fileExists(atPath: from.path) else { continue }
            try manager.moveItem(at: from, to: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    /// Opens the shared database.
    public func openDatabase() throws -> HrafnDatabase {
        try migrateLegacyDatabase()
        return try HrafnDatabase(url: databaseURL)
    }

    public func openOMEMODatabase() throws -> OMEMODatabase {
        try OMEMODatabase(directory: omemoDirectory)
    }
}
