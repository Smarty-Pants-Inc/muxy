import Foundation

enum CLIProxyUsageRedactor {
    static func redact(_ input: String) -> String {
        var value = input
        value = replace(#"(?i)(bearer\s+)[A-Za-z0-9._\-+/=]{8,}"#, in: value, with: "$1[REDACTED]")
        value = replace(
            #"(?i)((?:api[_-]?key|token|secret|password|authorization)\s*[=:]\s*)[^\s,;\]\}\)]+"#,
            in: value,
            with: "$1[REDACTED]"
        )
        value = replace(#"(?i)([?&](?:api[_-]?key|token|secret|password|key)=)[^&\s]+"#, in: value, with: "$1[REDACTED]")
        value = replace(#"(?i)\b(?:secret|token|password|authorization)[A-Za-z0-9._\-+/=]{8,}\b"#, in: value, with: "[REDACTED]")
        value = replace(#"\bsk-(?:proj-|ant-api03-)?[A-Za-z0-9][A-Za-z0-9_\-]{15,}\b"#, in: value, with: "[REDACTED]")
        value = replace(#"(?i)://[^/@\s]+@"#, in: value, with: "://[REDACTED]@")
        value = replace(#"(?i)[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, in: value, with: "[REDACTED_EMAIL]")
        return value
    }

    static func safeIdentifier(_ rawValue: String?, prefix: String) -> String {
        guard let rawValue else { return "\(prefix)-unknown" }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\(prefix)-unknown" }
        if isSafeIdentifier(trimmed) {
            return trimmed
        }
        return "\(prefix)-\(stableHash(trimmed).prefix(12))"
    }

    static func safeDisplayName(_ rawValue: String?, fallback: String) -> String {
        guard let rawValue else { return fallback }
        let redacted = redact(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return fallback }
        if redacted.contains("[REDACTED") {
            return fallback
        }
        return redacted
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard value.count <= 32 else { return false }
        guard value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil else { return false }
        let lowercased = value.lowercased()
        return !lowercased.contains("token")
            && !lowercased.contains("secret")
            && !lowercased.contains("password")
            && !value.contains("@")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    private static func replace(_ pattern: String, in value: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}
