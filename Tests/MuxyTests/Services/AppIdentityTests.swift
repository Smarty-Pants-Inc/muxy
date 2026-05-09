import Testing

@testable import Muxy

@Suite("AppIdentity")
struct AppIdentityTests {
    @Test("stable Smarty Code defaults use isolated identity")
    func stableDefaults() {
        let bundleID = "com.smartypants.smarty-code"
        #expect(AppIdentity.defaultApplicationSupportName(bundleIdentifier: bundleID, displayName: "") == "Smarty Code")
        #expect(AppIdentity.defaultURLScheme(bundleIdentifier: bundleID) == "smarty-code")
        #expect(AppIdentity.defaultCLICommandName(bundleIdentifier: bundleID) == "smarty-code")
        #expect(AppIdentity.defaultSocketName(urlScheme: "smarty-code") == "smarty-code.sock")
    }

    @Test("dev Smarty Code defaults use isolated identity")
    func devDefaults() {
        let bundleID = "com.smartypants.smarty-code.dev"
        #expect(AppIdentity.defaultApplicationSupportName(bundleIdentifier: bundleID, displayName: "") == "Smarty Code Dev")
        #expect(AppIdentity.defaultURLScheme(bundleIdentifier: bundleID) == "smarty-code-dev")
        #expect(AppIdentity.defaultCLICommandName(bundleIdentifier: bundleID) == "smarty-code-dev")
        #expect(AppIdentity.defaultSocketName(urlScheme: "smarty-code-dev") == "smarty-code-dev.sock")
    }

    @Test("Smarty Code update feeds are disabled unless configured")
    func smartyUpdatesDisabledByDefault() {
        #expect(AppIdentity.configuredUpdateFeedURL(
            for: .stable,
            bundleIdentifier: "com.smartypants.smarty-code",
            stableFeedURL: nil,
            betaFeedURL: nil
        ) == nil)
        #expect(AppIdentity.configuredUpdateFeedURL(
            for: .beta,
            bundleIdentifier: "com.smartypants.smarty-code.dev",
            stableFeedURL: nil,
            betaFeedURL: nil
        ) == nil)
    }

    @Test("legacy Muxy update feeds keep upstream appcasts")
    func legacyUpdatesKeepMuxyFeeds() {
        #expect(AppIdentity.configuredUpdateFeedURL(
            for: .stable,
            bundleIdentifier: AppIdentity.legacyBundleIdentifier,
            stableFeedURL: nil,
            betaFeedURL: nil
        )?.contains("muxy-app/muxy") == true)
    }

    @Test("configured update feed overrides default")
    func configuredFeedWins() {
        #expect(AppIdentity.configuredUpdateFeedURL(
            for: .stable,
            bundleIdentifier: "com.smartypants.smarty-code",
            stableFeedURL: "https://example.com/appcast.xml",
            betaFeedURL: nil
        ) == "https://example.com/appcast.xml")
    }
}
