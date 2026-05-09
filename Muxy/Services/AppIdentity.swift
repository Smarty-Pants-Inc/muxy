import Foundation

enum AppIdentity {
    static let legacyBundleIdentifier = "com.muxy.app"
    static let legacyApplicationSupportName = "Muxy"
    static let legacyURLScheme = "muxy"
    static let legacySocketName = "muxy.sock"
    static let legacyCLICommandName = "muxy"

    static var bundleIdentifier: String {
        stringValue("CFBundleIdentifier") ?? legacyBundleIdentifier
    }

    static var displayName: String {
        stringValue("CFBundleDisplayName") ?? stringValue("CFBundleName") ?? legacyApplicationSupportName
    }

    static var applicationSupportName: String {
        stringValue("MuxyApplicationSupportName") ?? defaultApplicationSupportName(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        )
    }

    static var urlScheme: String {
        stringValue("MuxyURLScheme") ?? defaultURLScheme(bundleIdentifier: bundleIdentifier)
    }

    static var socketName: String {
        stringValue("MuxySocketName") ?? defaultSocketName(urlScheme: urlScheme)
    }

    static var cliCommandName: String {
        stringValue("MuxyCLICommandName") ?? defaultCLICommandName(bundleIdentifier: bundleIdentifier)
    }

    static var sentryEnvironment: String? {
        stringValue("SentryEnvironment")
    }

    static var updatesEnabled: Bool {
        updateFeedURL(for: .stable) != nil || updateFeedURL(for: .beta) != nil
    }

    static func updateFeedURL(for channel: UpdateChannel) -> String? {
        configuredUpdateFeedURL(
            for: channel,
            bundleIdentifier: bundleIdentifier,
            stableFeedURL: stringValue("MuxyStableFeedURL"),
            betaFeedURL: stringValue("MuxyBetaFeedURL")
        )
    }

    static func defaultApplicationSupportName(bundleIdentifier: String, displayName: String) -> String {
        switch bundleIdentifier {
        case "com.smartypants.smarty-code":
            "Smarty Code"
        case "com.smartypants.smarty-code.dev":
            "Smarty Code Dev"
        default:
            displayName.isEmpty ? legacyApplicationSupportName : displayName
        }
    }

    static func defaultURLScheme(bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.smartypants.smarty-code":
            "smarty-code"
        case "com.smartypants.smarty-code.dev":
            "smarty-code-dev"
        default:
            legacyURLScheme
        }
    }

    static func defaultSocketName(urlScheme: String) -> String {
        let trimmed = urlScheme.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? legacySocketName : "\(trimmed).sock"
    }

    static func defaultCLICommandName(bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.smartypants.smarty-code":
            "smarty-code"
        case "com.smartypants.smarty-code.dev":
            "smarty-code-dev"
        default:
            legacyCLICommandName
        }
    }

    static func configuredUpdateFeedURL(
        for channel: UpdateChannel,
        bundleIdentifier: String,
        stableFeedURL: String?,
        betaFeedURL: String?
    ) -> String? {
        switch channel {
        case .stable:
            if let stableFeedURL { return stableFeedURL }
        case .beta:
            if let betaFeedURL { return betaFeedURL }
        }
        guard bundleIdentifier == legacyBundleIdentifier else { return nil }
        return defaultMuxyFeedURL(for: channel)
    }

    static func defaultMuxyFeedURL(for channel: UpdateChannel) -> String {
        switch channel {
        case .stable:
            "https://github.com/muxy-app/muxy/releases/latest/download/appcast-\(archSlug).xml"
        case .beta:
            "https://github.com/muxy-app/muxy/releases/download/beta-channel/appcast-beta-\(archSlug).xml"
        }
    }

    private static var archSlug: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static func stringValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
