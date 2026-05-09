import Foundation

enum MuxyFileStorage {
    static func fileURL(filename: String) -> URL {
        let dir = appSupportDirectory()
        return dir.appendingPathComponent(filename)
    }

    static func appSupportDirectory(create: Bool = true) -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        else {
            fatalError("Application Support directory unavailable")
        }
        let dir = appSupport.appendingPathComponent(AppIdentity.applicationSupportName, isDirectory: true)
        guard create else { return dir }
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: FilePermissions.privateDirectory]
        )
        return dir
    }

    static func legacyAppSupportDirectory(create: Bool = false) -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        else {
            fatalError("Application Support directory unavailable")
        }
        let dir = appSupport.appendingPathComponent(AppIdentity.legacyApplicationSupportName, isDirectory: true)
        guard create else { return dir }
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: FilePermissions.privateDirectory]
        )
        return dir
    }

    static func worktreeRoot(forProjectID projectID: UUID, create: Bool = true) -> URL {
        let dir = appSupportDirectory(create: create)
            .appendingPathComponent("worktree-checkouts", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard create else { return dir }
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: FilePermissions.privateDirectory]
        )
        return dir
    }

    static func worktreeDirectory(forProjectID projectID: UUID, name: String) -> URL {
        worktreeRoot(forProjectID: projectID).appendingPathComponent(name, isDirectory: true)
    }
}

enum MuxyLegacyMigration {
    static let defaultsMarkerKey = "smartyCode.didMigrateMuxyDefaults.v1"
    static let fileMarkerName = ".migrated-from-muxy"

    static func runIfNeeded() {
        guard AppIdentity.bundleIdentifier != AppIdentity.legacyBundleIdentifier else { return }
        migrateDefaultsIfNeeded()
        _ = try? copyLegacyFilesIfNeeded(
            legacyDirectory: MuxyFileStorage.legacyAppSupportDirectory(create: false),
            destinationDirectory: MuxyFileStorage.appSupportDirectory(),
            markerURL: MuxyFileStorage.appSupportDirectory().appendingPathComponent(fileMarkerName),
            fileManager: .default
        )
    }

    static func migrateDefaultsIfNeeded(
        defaults: UserDefaults = .standard,
        legacyBundleIdentifier: String = AppIdentity.legacyBundleIdentifier,
        currentBundleIdentifier: String = AppIdentity.bundleIdentifier
    ) {
        guard currentBundleIdentifier != legacyBundleIdentifier else { return }
        guard !defaults.bool(forKey: defaultsMarkerKey) else { return }
        guard let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier) else {
            defaults.set(true, forKey: defaultsMarkerKey)
            return
        }
        let current = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
        for (key, value) in legacy where current[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: defaultsMarkerKey)
    }

    @discardableResult
    static func copyLegacyFilesIfNeeded(
        legacyDirectory: URL,
        destinationDirectory: URL,
        markerURL: URL,
        fileManager: FileManager,
        isLegacyBundle: Bool = AppIdentity.bundleIdentifier == AppIdentity.legacyBundleIdentifier
    ) throws -> Bool {
        guard !isLegacyBundle else { return false }
        guard !fileManager.fileExists(atPath: markerURL.path) else { return false }
        guard fileManager.fileExists(atPath: legacyDirectory.path) else {
            try Data().write(to: markerURL, options: .atomic)
            return false
        }
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: FilePermissions.privateDirectory]
        )
        for item in try fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            guard !shouldSkipLegacyItem(item) else { continue }
            let target = destinationDirectory.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.copyItem(at: item, to: target)
        }
        try Data().write(to: markerURL, options: .atomic)
        return true
    }

    static func shouldSkipLegacyItem(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".sock") || name == fileMarkerName
    }
}
