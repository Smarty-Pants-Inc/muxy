import Foundation
import Testing

@testable import Muxy

@Suite("MuxyLegacyMigration")
struct MuxyLegacyMigrationTests {
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
