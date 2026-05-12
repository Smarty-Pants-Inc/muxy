import Foundation

struct CLIProxyUsageProvider: AIUsageProvider {
    let id = "cliproxyapi"
    let displayName = "CLIProxyAPI"
    let iconName = "server.rack"

    private let service: any CLIProxyUsageSnapshotServing

    init(service: any CLIProxyUsageSnapshotServing = CLIProxyUsageService()) {
        self.service = service
    }

    func fetchUsageSnapshot() async -> AIProviderUsageSnapshot {
        let snapshot = await service.fetchUsageSnapshot()
        return Self.providerSnapshot(from: snapshot)
    }

    func fetchCLIProxyUsageSnapshot() async -> CLIProxyUsageSnapshot {
        await service.fetchUsageSnapshot()
    }

    static func providerSnapshot(from snapshot: CLIProxyUsageSnapshot, fetchedAt: Date? = nil) -> AIProviderUsageSnapshot {
        if !snapshot.isProxyReachable {
            return baseSnapshot(
                from: snapshot,
                state: .unavailable(message: "CLIProxyAPI not detected on local endpoints"),
                rows: [],
                fetchedAt: fetchedAt
            )
        }

        guard snapshot.statsBackend.hasUsageHistory else {
            let reason = snapshot.missingCapabilities.first { $0.id == "usage-history" }?.reason
                ?? "No usage statistics backend detected"
            return baseSnapshot(
                from: snapshot,
                state: .unavailable(message: "CLIProxyAPI detected; Usage history unavailable: \(reason)"),
                rows: [],
                fetchedAt: fetchedAt
            )
        }

        let rows = rows(from: snapshot)
        if rows.isEmpty {
            return baseSnapshot(
                from: snapshot,
                state: .unavailable(message: "CLIProxyAPI stats available, but no usage events were found"),
                rows: [],
                fetchedAt: fetchedAt
            )
        }
        return baseSnapshot(from: snapshot, state: .available, rows: rows, fetchedAt: fetchedAt)
    }

    private static func baseSnapshot(
        from snapshot: CLIProxyUsageSnapshot,
        state: AIProviderUsageState,
        rows: [AIUsageMetricRow],
        fetchedAt: Date?
    ) -> AIProviderUsageSnapshot {
        AIProviderUsageSnapshot(
            providerID: "cliproxyapi",
            providerName: "CLIProxyAPI",
            providerIconName: "server.rack",
            fetchedAt: fetchedAt ?? snapshot.fetchedAt,
            state: state,
            rows: rows
        )
    }

    private static func rows(from snapshot: CLIProxyUsageSnapshot) -> [AIUsageMetricRow] {
        var rows: [AIUsageMetricRow] = []
        if let capacity = aggregateCapacity(snapshot.accounts) {
            rows.append(
                AIUsageMetricRow(
                    label: "Primary capacity",
                    percent: capacity,
                    resetDate: nextResetDate(snapshot.accounts),
                    detail: "\(AIUsageParserSupport.formatNumber(capacity))% local capacity"
                )
            )
        }

        if let hour = snapshot.windows.first(where: { $0.id == "1h" }) {
            let velocity = snapshot.velocities.first(where: { $0.id == "1h" })
            let detail: String
            if let velocity {
                let formattedVelocity = AIUsageParserSupport.formatNumber(velocity.tokensPerMinute)
                detail = "\(hour.totalTokens) tokens, \(hour.requestCount) requests, \(formattedVelocity)/min"
            } else {
                detail = "\(hour.totalTokens) tokens, \(hour.requestCount) requests"
            }
            rows.append(
                AIUsageMetricRow(
                    label: "Hourly tokens",
                    percent: nil,
                    resetDate: nil,
                    detail: CLIProxyUsageRedactor.redact(detail),
                    periodDuration: 3600
                )
            )
            if let cost = hour.costEstimateUSD {
                rows.append(
                    AIUsageMetricRow(
                        label: "Estimated cost",
                        percent: nil,
                        resetDate: nil,
                        detail: "~\(AIUsageParserSupport.formatNumber(cost)) USD",
                        periodDuration: 3600
                    )
                )
            }
        }

        return rows
    }

    private static func aggregateCapacity(_ accounts: [CLIProxyAccountUsage]) -> Double? {
        let scores = accounts.compactMap { $0.capacity?.score }
        guard !scores.isEmpty else { return nil }
        return min(100, max(0, scores.reduce(0, +) / Double(scores.count)))
    }

    private static func nextResetDate(_ accounts: [CLIProxyAccountUsage]) -> Date? {
        accounts.compactMap { $0.quota?.resetsAt }.min()
    }
}
