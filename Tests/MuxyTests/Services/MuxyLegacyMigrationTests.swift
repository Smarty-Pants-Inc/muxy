import Foundation
import Testing

@testable import Muxy

@Suite("MuxyLegacyMigration")
struct MuxyLegacyMigrationTests {
    @Test("Smarty Code Dev startup does not probe legacy Muxy data unless explicitly enabled")
    func smartyCodeDevDoesNotProbeLegacyDataByDefault() throws {
        let suiteName = "muxy.tests.migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        let legacyID = "\(suiteName).legacy"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.removePersistentDomain(forName: legacyID)
        }
        defaults.setPersistentDomain(["theme": "Muxy Light"], forName: legacyID)

        var probedLegacyFiles = false
        var createdDestination = false
        MuxyLegacyMigration.runIfNeeded(
            defaults: defaults,
            currentBundleIdentifier: "com.smartypants.smarty-code.dev",
            legacyBundleIdentifier: legacyID,
            environment: [:],
            legacyDirectoryProvider: {
                probedLegacyFiles = true
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("legacy-muxy-should-not-be-read", isDirectory: true)
            },
            destinationDirectoryProvider: {
                createdDestination = true
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("smarty-code-should-not-be-created", isDirectory: true)
            }
        )

        #expect(!defaults.bool(forKey: MuxyLegacyMigration.defaultsMarkerKey))
        #expect(defaults.string(forKey: "theme") == nil)
        #expect(!probedLegacyFiles)
        #expect(!createdDestination)
    }

    @Test("Smarty Code stable startup does not probe legacy Muxy data unless explicitly enabled")
    func smartyCodeStableDoesNotProbeLegacyDataByDefault() {
        let suiteName = "muxy.tests.migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(!MuxyLegacyMigration.shouldAutomaticallyMigrate(
            currentBundleIdentifier: "com.smartypants.smarty-code",
            legacyBundleIdentifier: AppIdentity.legacyBundleIdentifier,
            defaults: defaults,
            environment: [:]
        ))
    }

    @Test("Smarty Code legacy migration remains available with explicit opt in")
    func smartyCodeMigrationCanBeExplicitlyEnabled() {
        let suiteName = "muxy.tests.migration.\(UUID().uuidString)"
        let envSuiteName = "muxy.tests.migration.env.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        guard let envDefaults = UserDefaults(suiteName: envSuiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            envDefaults.removePersistentDomain(forName: envSuiteName)
        }

        defaults.set(true, forKey: MuxyLegacyMigration.optInKey)

        #expect(MuxyLegacyMigration.shouldAutomaticallyMigrate(
            currentBundleIdentifier: "com.smartypants.smarty-code.dev",
            legacyBundleIdentifier: AppIdentity.legacyBundleIdentifier,
            defaults: defaults,
            environment: [:]
        ))
        #expect(MuxyLegacyMigration.shouldAutomaticallyMigrate(
            currentBundleIdentifier: "com.smartypants.smarty-code.dev",
            legacyBundleIdentifier: AppIdentity.legacyBundleIdentifier,
            defaults: envDefaults,
            environment: [MuxyLegacyMigration.optInEnvironmentKey: "true"]
        ))
    }

    @Test("non-Smarty renamed apps keep automatic migration behavior")
    func nonSmartyRenamedAppStillMigratesAutomatically() {
        let suiteName = "muxy.tests.migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(MuxyLegacyMigration.shouldAutomaticallyMigrate(
            currentBundleIdentifier: "com.example.renamed-muxy",
            legacyBundleIdentifier: AppIdentity.legacyBundleIdentifier,
            defaults: defaults,
            environment: [:]
        ))
    }

    @Test("legacy files are copied once without socket files")
    func copyLegacyFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muxy-migration-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("Muxy", isDirectory: true)
        let destination = root.appendingPathComponent("Smarty Code", isDirectory: true)
        let marker = destination.appendingPathComponent(MuxyLegacyMigration.fileMarkerName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "project".write(to: legacy.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
        try "socket".write(to: legacy.appendingPathComponent("muxy.sock"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let copied = try MuxyLegacyMigration.copyLegacyFilesIfNeeded(
            legacyDirectory: legacy,
            destinationDirectory: destination,
            markerURL: marker,
            fileManager: .default,
            isLegacyBundle: false
        )

        #expect(copied)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("projects.json").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("muxy.sock").path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("legacy file copy does not overwrite existing destination files")
    func copyDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muxy-migration-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("Muxy", isDirectory: true)
        let destination = root.appendingPathComponent("Smarty Code", isDirectory: true)
        let marker = destination.appendingPathComponent(MuxyLegacyMigration.fileMarkerName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "legacy".write(to: legacy.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
        try "current".write(to: destination.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try MuxyLegacyMigration.copyLegacyFilesIfNeeded(
            legacyDirectory: legacy,
            destinationDirectory: destination,
            markerURL: marker,
            fileManager: .default,
            isLegacyBundle: false
        )

        let text = try String(contentsOf: destination.appendingPathComponent("projects.json"), encoding: .utf8)
        #expect(text == "current")
    }

    @Test("legacy defaults are copied into an empty current suite")
    func defaultsCopy() {
        let suiteName = "muxy.tests.migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        let legacyID = "\(suiteName).legacy"
        let currentID = "\(suiteName).current"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.removePersistentDomain(forName: legacyID)
            defaults.removePersistentDomain(forName: currentID)
        }
        defaults.setPersistentDomain(["theme": "Muxy Light"], forName: legacyID)

        MuxyLegacyMigration.migrateDefaultsIfNeeded(
            defaults: defaults,
            legacyBundleIdentifier: legacyID,
            currentBundleIdentifier: currentID
        )

        #expect(defaults.string(forKey: "theme") == "Muxy Light")
        #expect(defaults.bool(forKey: MuxyLegacyMigration.defaultsMarkerKey))
    }
}
