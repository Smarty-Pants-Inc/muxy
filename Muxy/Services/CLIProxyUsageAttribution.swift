import Foundation

enum CLIProxyUsageAttributionEnricher {
    static func enrich(
        snapshot: CLIProxyUsageSnapshot,
        registrySnapshot: AgentSessionRegistrySnapshot
    ) -> CLIProxyUsageSnapshot {
        let sessions = snapshot.sessions.map { session in
            let joinKey = "request-session:\(session.id)"
            guard let labels = registrySnapshot.attributionLabels(matchingJoinKey: joinKey) else {
                return session
            }
            return session.withAttribution(labels)
        }
        guard sessions != snapshot.sessions else { return snapshot }
        return snapshot.withSessions(sessions)
    }
}

extension CLIProxyUsageSnapshot {
    func withSessions(_ sessions: [CLIProxySessionUsage]) -> CLIProxyUsageSnapshot {
        CLIProxyUsageSnapshot(
            id: id,
            fetchedAt: fetchedAt,
            baseURL: baseURL,
            isProxyReachable: isProxyReachable,
            version: version,
            statsBackend: statsBackend,
            accounts: accounts,
            models: models,
            sessions: sessions,
            windows: windows,
            velocities: velocities,
            warnings: warnings,
            missingCapabilities: missingCapabilities
        )
    }
}
