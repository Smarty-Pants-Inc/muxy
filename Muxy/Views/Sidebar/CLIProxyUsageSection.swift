import SwiftUI

enum CLIProxyUsageFormatter {
    static func redacted(_ value: String) -> String {
        CLIProxyUsageRedactor.redact(value)
    }

    static func tokenCount(_ value: Int) -> String {
        AIUsageParserSupport.formatNumber(Double(value))
    }

    static func percent(_ value: Double) -> String {
        "\(AIUsageParserSupport.formatNumber(max(0, min(100, value))))%"
    }

    static func tokensPerMinute(_ value: Double) -> String {
        "\(AIUsageParserSupport.formatNumber(max(0, value))) tok/min"
    }

    static func requestsPerMinute(_ value: Double) -> String {
        "\(AIUsageParserSupport.formatNumber(max(0, value))) req/min"
    }

    static func tokensPerSecond(_ value: Double) -> String {
        "\(AIUsageParserSupport.formatNumber(max(0, value))) tok/s"
    }

    static func costEstimate(_ value: Double) -> String {
        "~\(AIUsageParserSupport.formatNumber(max(0, value))) USD"
    }

    static func cachePreservationScore(_ value: Double) -> String {
        "\(AIUsageParserSupport.formatNumber(max(0, value) * 100))% cache preserved"
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func statusLabel(_ status: CLIProxyAccountStatus) -> String {
        switch status {
        case .active: "active"
        case .idle: "idle"
        case .cooling: "cooling"
        case .disabled: "disabled"
        case .exhausted: "exhausted"
        case .error: "error"
        case .unknown: "unknown"
        }
    }

    static func accountsDetail(_ accounts: [CLIProxyAccountUsage]) -> String {
        guard !accounts.isEmpty else { return "No account metadata returned" }
        let activeCount = accounts.count { $0.status == .active }
        let unknownCount = accounts.count { $0.status == .unknown }
        if unknownCount == accounts.count {
            return "status unknown"
        }
        if unknownCount > 0 {
            return "\(activeCount) active, \(unknownCount) unknown"
        }
        return "\(activeCount) active"
    }

    static func historyUnavailableText(snapshot: CLIProxyUsageSnapshot) -> String {
        snapshot.missingCapabilities.first { $0.id == "usage-history" }?.reason
            ?? "Timestamped usage history is not available from the detected backend"
    }

    static func missingCapabilityText(snapshot: CLIProxyUsageSnapshot, id: String) -> String? {
        snapshot.missingCapabilities.first { $0.id == id }?.reason
    }

    static func capabilityReportText(snapshot: CLIProxyUsageSnapshot) -> String? {
        snapshot.warnings.first { $0.id == "capability-report" }?.message
    }

    static func runway(_ estimate: CLIProxyRunwayEstimate?) -> String? {
        guard let estimate else { return nil }
        if let minutes = estimate.minutesUntilExhaustion {
            if minutes < 1 {
                return "Runway under 1m"
            }
            if minutes < 60 {
                return "Runway \(Int(minutes.rounded()))m"
            }
            let hours = minutes / 60
            return "Runway \(AIUsageParserSupport.formatNumber(hours))h"
        }
        return estimate.reason
    }

    static func attributionLabel(_ attribution: CLIProxySessionAttribution) -> String {
        let prefix = switch attribution.confidence {
        case .confirmed: "Attributed"
        case .suggested: "Suggested"
        case .unknown: "Unconfirmed"
        }
        return "\(prefix): \(CLIProxyUsageRedactor.redact(attribution.hierarchyLabel))"
    }

    static func velocitySparkline(_ velocities: [CLIProxyUsageVelocity]) -> String? {
        let active = velocities.filter { $0.tokensPerMinute > 0 }
        guard !active.isEmpty else { return nil }
        guard let maxVelocity = active.map(\.tokensPerMinute).max(), maxVelocity > 0 else { return nil }
        return active.map { velocity in
            let filled = max(1, min(8, Int((velocity.tokensPerMinute / maxVelocity * 8).rounded(.up))))
            let empty = max(0, 8 - filled)
            return "\(velocity.label)[\(String(repeating: "#", count: filled))\(String(repeating: ".", count: empty))]"
        }
        .joined(separator: " ")
    }

    static func refillLine(_ event: CLIProxyRefillEvent, now: Date) -> String {
        let prefix = event.resetsAt <= now ? "ready now" : "in \(relativeDuration(until: event.resetsAt, from: now))"
        let remaining = tokenCount(event.remainingTokens)
        let limit = tokenCount(event.limitTokens)
        return "\(prefix) · \(remaining)/\(limit) tokens left"
    }

    static func contextBloat(_ signal: CLIProxyContextBloatSignal) -> String {
        let deltaPrefix = signal.deltaPromptTokens >= 0 ? "+" : ""
        let percent = signal.percentChange.map { " (\(deltaPrefix)\(AIUsageParserSupport.formatNumber($0))%)" } ?? ""
        let label = signal.isBloating ? "Context bloat" : "Context trend"
        return "\(label): \(deltaPrefix)\(tokenCount(signal.deltaPromptTokens)) prompt avg\(percent) over \(signal.sampleCount) requests"
    }

    private static func relativeDuration(until date: Date, from now: Date) -> String {
        let interval = max(0, date.timeIntervalSince(now))
        if interval < 60 { return "<1m" }
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }
}

struct CLIProxyUsageSection: View {
    let snapshot: CLIProxyUsageSnapshot

    private var hasHistory: Bool { snapshot.statsBackend.hasUsageHistory }

    private var accountsWithCapacity: [CLIProxyAccountUsage] {
        snapshot.accounts.filter { $0.capacity?.score != nil }
    }

    private var capacityScore: Double? {
        let scores = accountsWithCapacity.compactMap { $0.capacity?.score }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private var activeModels: [CLIProxyModelUsage] {
        snapshot.models.filter { $0.requestCount > 0 || $0.totalTokens > 0 }
    }

    private var activeVelocities: [CLIProxyUsageVelocity] {
        snapshot.velocities.filter { $0.requestCount > 0 || $0.totalTokens > 0 }
    }

    private var activeSessions: [CLIProxySessionUsage] {
        snapshot.sessions.filter { $0.requestCount > 0 || $0.totalTokens > 0 }
    }

    private var mostRecentWindow: CLIProxyUsageWindow? {
        snapshot.windows.first { $0.id == "1h" && ($0.totalTokens > 0 || $0.requestCount > 0) }
            ?? snapshot.windows.first { $0.totalTokens > 0 || $0.requestCount > 0 }
    }

    private var optionalMetricMissingCapabilities: [CLIProxyMissingCapability] {
        ["cache-tokens", "latency", "time-to-first-token", "generation-throughput", "cost-estimates"].compactMap { id in
            snapshot.missingCapabilities.first { $0.id == id }
        }
    }

    private var nonCapabilityWarnings: [CLIProxyUsageWarning] {
        snapshot.warnings.filter { $0.id != "capability-report" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing4) {
            header
            overview
            capabilities
            accounts
            refillTimeline
            velocity
            hotSessions
            models
        }
        .padding(UIMetrics.spacing4)
        .background(MuxyTheme.hover, in: RoundedRectangle(cornerRadius: UIMetrics.radiusLG))
        .overlay(
            RoundedRectangle(cornerRadius: UIMetrics.radiusLG)
                .stroke(MuxyTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CLIProxyAPI usage")
    }

    private var header: some View {
        HStack(spacing: UIMetrics.spacing3) {
            Image(systemName: "server.rack")
                .font(.system(size: UIMetrics.fontBody, weight: .semibold))
                .foregroundStyle(MuxyTheme.fgMuted)
            VStack(alignment: .leading, spacing: UIMetrics.spacing1) {
                Text("CLIProxyAPI")
                    .font(.system(size: UIMetrics.fontBody, weight: .semibold))
                    .foregroundStyle(MuxyTheme.fg)
                Text(headerDetail)
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
                    .lineLimit(2)
            }
            Spacer(minLength: UIMetrics.spacing2)
            statusPill(snapshot.isProxyReachable ? "reachable" : "not detected", color: snapshot.isProxyReachable ? .green : .red)
        }
    }

    private var headerDetail: String {
        let base = CLIProxyUsageFormatter.redacted(snapshot.baseURL.absoluteString)
        if let version = snapshot.version {
            return "\(snapshot.statsBackend.displayName) · \(version) · \(base)"
        }
        return "\(snapshot.statsBackend.displayName) · \(base)"
    }

    private var overview: some View {
        section(title: "Overview", systemImage: "gauge.with.dots.needle.50percent") {
            metricGrid([
                overviewTokensTile,
                accountTile,
                capacityTile,
                modelTile,
            ])
            if !hasHistory {
                missingNotice(
                    title: "Usage history unavailable",
                    message: CLIProxyUsageFormatter.historyUnavailableText(snapshot: snapshot)
                )
            }
            ForEach(nonCapabilityWarnings) { warning in
                warningRow(warning)
            }
        }
    }

    private var capabilities: some View {
        section(title: "Capabilities", systemImage: "checklist") {
            metricLine(
                title: "Proxy",
                value: snapshot.isProxyReachable ? "Reachable" : "Not detected",
                detail: CLIProxyUsageFormatter.redacted(snapshot.baseURL.absoluteString)
            )
            metricLine(
                title: "Stats backend",
                value: snapshot.statsBackend.displayName,
                detail: CLIProxyUsageFormatter.capabilityReportText(snapshot: snapshot)
            )
            if snapshot.missingCapabilities.isEmpty {
                missingNotice(
                    title: "No missing optional capabilities reported",
                    message: "The detected backend did not report unavailable stats inputs"
                )
            } else {
                ForEach(snapshot.missingCapabilities) { capability in
                    missingNotice(title: "\(capability.capability) unavailable", message: capability.reason)
                }
            }
        }
    }

    private var overviewTokensTile: CLIProxyUsageMetricTile.Model {
        guard hasHistory else {
            return .init(title: "Rolling tokens", value: "Unavailable", detail: "Requires timestamped usage events")
        }
        guard let window = mostRecentWindow else {
            return .init(title: "Rolling tokens", value: "No events", detail: "Stats backend is present, but no usage was captured")
        }
        return .init(
            title: "\(window.label) tokens",
            value: CLIProxyUsageFormatter.tokenCount(window.totalTokens),
            detail: "\(window.requestCount) requests, \(window.errorCount) errors"
        )
    }

    private var accountTile: CLIProxyUsageMetricTile.Model {
        guard !snapshot.accounts.isEmpty else {
            return .init(title: "Accounts", value: "Unavailable", detail: "No account metadata returned")
        }
        return .init(
            title: "Accounts",
            value: "\(snapshot.accounts.count)",
            detail: CLIProxyUsageFormatter.accountsDetail(snapshot.accounts)
        )
    }

    private var capacityTile: CLIProxyUsageMetricTile.Model {
        guard let capacityScore else {
            return .init(title: "Capacity", value: "Unavailable", detail: "Quota/headroom data missing")
        }
        return .init(title: "Capacity", value: CLIProxyUsageFormatter.percent(capacityScore), detail: "Average safe headroom")
    }

    private var modelTile: CLIProxyUsageMetricTile.Model {
        guard hasHistory else {
            return .init(title: "Models", value: "Unavailable", detail: "Requires usage history")
        }
        guard !activeModels.isEmpty else {
            return .init(title: "Models", value: "No captures", detail: "No model events recorded")
        }
        return .init(title: "Models", value: "\(activeModels.count)", detail: "In rolling usage")
    }

    private var accounts: some View {
        section(title: "Accounts", systemImage: "person.2") {
            if snapshot.accounts.isEmpty {
                missingNotice(
                    title: "Account metadata unavailable",
                    message: "Detected backend did not provide account rows or capacity inputs"
                )
            } else {
                VStack(alignment: .leading, spacing: UIMetrics.spacing3) {
                    ForEach(Array(snapshot.accounts.prefix(4))) { account in
                        accountRow(account)
                    }
                    if snapshot.accounts.count > 4 {
                        Text("\(snapshot.accounts.count - 4) more accounts")
                            .font(.system(size: UIMetrics.fontFootnote))
                            .foregroundStyle(MuxyTheme.fgDim)
                    }
                }
            }
        }
    }

    private var velocity: some View {
        section(title: "Velocity", systemImage: "speedometer") {
            if !hasHistory {
                missingNotice(title: "Velocity unavailable", message: "Token velocity requires timestamped per-request history")
            } else if activeVelocities.isEmpty {
                missingNotice(
                    title: "No velocity captured",
                    message: "Stats backend is available, but no rolling windows contain requests yet"
                )
            } else {
                VStack(alignment: .leading, spacing: UIMetrics.spacing3) {
                    if let sparkline = CLIProxyUsageFormatter.velocitySparkline(activeVelocities) {
                        metricLine(
                            title: "Sparkline",
                            value: sparkline,
                            detail: "Relative token velocity by rolling window"
                        )
                    }
                    ForEach(activeVelocities) { velocity in
                        let requests = CLIProxyUsageFormatter.requestsPerMinute(velocity.requestsPerMinute)
                        metricLine(
                            title: velocity.label,
                            value: CLIProxyUsageFormatter.tokensPerMinute(velocity.tokensPerMinute),
                            detail: "\(requests) · \(velocity.requestCount) requests"
                        )
                    }
                }
            }
        }
    }

    private var refillTimeline: some View {
        section(title: "Refill timeline", systemImage: "calendar.badge.clock") {
            let refills = snapshot.refillTimeline
            if refills.isEmpty {
                missingNotice(
                    title: "Refill timeline unavailable",
                    message: CLIProxyUsageFormatter.missingCapabilityText(snapshot: snapshot, id: "quota")
                        ?? "Quota reset windows unavailable from the detected backend"
                )
            } else {
                VStack(alignment: .leading, spacing: UIMetrics.spacing3) {
                    ForEach(Array(refills.prefix(4))) { refill in
                        metricLine(
                            title: refill.accountDisplayName,
                            value: CLIProxyUsageFormatter.refillLine(refill, now: snapshot.fetchedAt),
                            detail: refill.providerKind
                        )
                    }
                    if refills.count > 4 {
                        Text("\(refills.count - 4) more refill events")
                            .font(.system(size: UIMetrics.fontFootnote))
                            .foregroundStyle(MuxyTheme.fgDim)
                    }
                }
            }
        }
    }

    private var models: some View {
        section(title: "Models", systemImage: "cube.transparent") {
            if !hasHistory {
                missingNotice(title: "Model mix unavailable", message: "Model mix requires usage events from a stats backend")
            } else if activeModels.isEmpty {
                missingNotice(title: "No model usage captured", message: "No requests with model names are present in the detected history")
            } else {
                VStack(alignment: .leading, spacing: UIMetrics.spacing3) {
                    ForEach(Array(activeModels.prefix(4))) { model in
                        modelRow(model)
                    }
                    ForEach(optionalMetricMissingCapabilities) { capability in
                        missingNotice(title: "\(capability.capability) unavailable", message: capability.reason)
                    }
                    if activeModels.count > 4 {
                        Text("\(activeModels.count - 4) more models")
                            .font(.system(size: UIMetrics.fontFootnote))
                            .foregroundStyle(MuxyTheme.fgDim)
                    }
                }
            }
        }
    }

    private var hotSessions: some View {
        section(title: "Hot sessions", systemImage: "flame") {
            if !hasHistory {
                missingNotice(title: "Session attribution unavailable", message: "Hot sessions require timestamped usage events")
            } else if activeSessions.isEmpty {
                missingNotice(
                    title: "No session usage captured",
                    message: CLIProxyUsageFormatter.missingCapabilityText(snapshot: snapshot, id: "agent-attribution")
                        ?? "Detected stats do not include request session identifiers"
                )
            } else {
                VStack(alignment: .leading, spacing: UIMetrics.spacing3) {
                    ForEach(Array(activeSessions.prefix(4))) { session in
                        sessionRow(session)
                    }
                    if activeSessions.count > 4 {
                        Text("\(activeSessions.count - 4) more sessions")
                            .font(.system(size: UIMetrics.fontFootnote))
                            .foregroundStyle(MuxyTheme.fgDim)
                    }
                }
            }
        }
    }

    private func accountRow(_ account: CLIProxyAccountUsage) -> some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing2) {
            HStack(spacing: UIMetrics.spacing2) {
                VStack(alignment: .leading, spacing: UIMetrics.spacing1) {
                    Text(CLIProxyUsageFormatter.redacted(account.displayName))
                        .font(.system(size: UIMetrics.fontBody, weight: .medium))
                        .foregroundStyle(MuxyTheme.fg)
                        .lineLimit(1)
                    Text(CLIProxyUsageFormatter.redacted(account.providerKind))
                        .font(.system(size: UIMetrics.fontFootnote))
                        .foregroundStyle(MuxyTheme.fgDim)
                }
                Spacer(minLength: UIMetrics.spacing2)
                statusPill(CLIProxyUsageFormatter.statusLabel(account.status), color: statusColor(account.status))
            }
            HStack(spacing: UIMetrics.spacing3) {
                if let score = account.capacity?.score {
                    Text("Capacity \(CLIProxyUsageFormatter.percent(score))")
                } else {
                    Text(account.capacity?.reason ?? "Capacity unavailable")
                }
                if let sessions = account.activeSessionCount {
                    Text("\(sessions) sessions")
                }
                if let quota = account.quota {
                    Text("\(CLIProxyUsageFormatter.tokenCount(quota.remainingTokens)) tokens left")
                }
                if let lastUsedAt = account.lastUsedAt {
                    Text("last used \(CLIProxyUsageFormatter.timestamp(lastUsedAt))")
                }
            }
            .font(.system(size: UIMetrics.fontFootnote))
            .foregroundStyle(MuxyTheme.fgDim)
            .lineLimit(2)
            if let runway = CLIProxyUsageFormatter.runway(account.capacity?.runway) {
                Text(runway)
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
            }
            if let failure = account.recentFailure {
                Text("Recent failure: \(failure.message)")
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.warning)
                    .lineLimit(2)
            }
        }
        .padding(UIMetrics.spacing3)
        .background(MuxyTheme.surface, in: RoundedRectangle(cornerRadius: UIMetrics.radiusMD))
    }

    private func modelRow(_ model: CLIProxyModelUsage) -> some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing2) {
            HStack(spacing: UIMetrics.spacing2) {
                Text(CLIProxyUsageFormatter.redacted(model.model))
                    .font(.system(size: UIMetrics.fontBody, weight: .medium))
                    .foregroundStyle(MuxyTheme.fg)
                    .lineLimit(1)
                Spacer(minLength: UIMetrics.spacing2)
                Text(CLIProxyUsageFormatter.tokenCount(model.totalTokens))
                    .font(.system(size: UIMetrics.fontBody, weight: .semibold))
                    .foregroundStyle(MuxyTheme.fg)
            }
            HStack(spacing: UIMetrics.spacing3) {
                Text("\(model.requestCount) requests")
                Text("prompt \(CLIProxyUsageFormatter.tokenCount(model.promptTokens))")
                Text("completion \(CLIProxyUsageFormatter.tokenCount(model.completionTokens))")
                if let cacheRead = model.cacheReadTokens {
                    Text("cache read \(CLIProxyUsageFormatter.tokenCount(cacheRead))")
                }
                if let cacheWrite = model.cacheWriteTokens {
                    Text("cache write \(CLIProxyUsageFormatter.tokenCount(cacheWrite))")
                }
                if model.errorCount > 0 {
                    Text("\(model.errorCount) errors")
                }
            }
            .font(.system(size: UIMetrics.fontFootnote))
            .foregroundStyle(MuxyTheme.fgDim)
            .lineLimit(2)
            if let latency = model.averageLatencyMS {
                Text("avg latency \(CLIProxyUsageFormatter.tokenCount(Int(latency.rounded())))ms")
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
            }
            if let timeToFirstToken = model.averageTimeToFirstTokenMS {
                Text("avg first token \(CLIProxyUsageFormatter.tokenCount(Int(timeToFirstToken.rounded())))ms")
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
            }
            if let throughput = model.generationTokensPerSecond {
                Text("generation \(CLIProxyUsageFormatter.tokensPerSecond(throughput))")
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
            }
            if let cachePreservationScore = model.cachePreservationScore {
                Text(CLIProxyUsageFormatter.cachePreservationScore(cachePreservationScore))
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
            }
            if let cost = model.costEstimateUSD {
                Text("estimated cost \(CLIProxyUsageFormatter.costEstimate(cost))")
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
            }
        }
        .padding(UIMetrics.spacing3)
        .background(MuxyTheme.surface, in: RoundedRectangle(cornerRadius: UIMetrics.radiusMD))
    }

    private func sessionRow(_ session: CLIProxySessionUsage) -> some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing2) {
            HStack(spacing: UIMetrics.spacing2) {
                VStack(alignment: .leading, spacing: UIMetrics.spacing1) {
                    Text(CLIProxyUsageFormatter.redacted(session.displayName))
                        .font(.system(size: UIMetrics.fontBody, weight: .medium))
                        .foregroundStyle(MuxyTheme.fg)
                        .lineLimit(1)
                    if let attribution = session.attribution {
                        Text(CLIProxyUsageFormatter.attributionLabel(attribution))
                            .font(.system(size: UIMetrics.fontFootnote))
                            .foregroundStyle(MuxyTheme.fgDim)
                            .lineLimit(1)
                    } else {
                        Text("Attribution unconfirmed")
                            .font(.system(size: UIMetrics.fontFootnote))
                            .foregroundStyle(MuxyTheme.fgDim)
                    }
                }
                Spacer(minLength: UIMetrics.spacing2)
                Text(CLIProxyUsageFormatter.tokenCount(session.totalTokens))
                    .font(.system(size: UIMetrics.fontBody, weight: .semibold))
                    .foregroundStyle(MuxyTheme.fg)
            }
            HStack(spacing: UIMetrics.spacing3) {
                Text("\(session.requestCount) requests")
                Text("prompt \(CLIProxyUsageFormatter.tokenCount(session.promptTokens))")
                Text("completion \(CLIProxyUsageFormatter.tokenCount(session.completionTokens))")
                if session.errorCount > 0 {
                    Text("\(session.errorCount) errors")
                }
                if !session.modelNames.isEmpty {
                    Text(CLIProxyUsageFormatter.redacted(session.modelNames.prefix(2).joined(separator: ", ")))
                }
                if let lastUsedAt = session.lastUsedAt {
                    Text("last used \(CLIProxyUsageFormatter.timestamp(lastUsedAt))")
                }
            }
            .font(.system(size: UIMetrics.fontFootnote))
            .foregroundStyle(MuxyTheme.fgDim)
            .lineLimit(2)
            if let contextBloatSignal = session.contextBloatSignal {
                Text(CLIProxyUsageFormatter.contextBloat(contextBloatSignal))
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(contextBloatSignal.isBloating ? MuxyTheme.warning : MuxyTheme.fgDim)
                    .lineLimit(2)
            }
        }
        .padding(UIMetrics.spacing3)
        .background(MuxyTheme.surface, in: RoundedRectangle(cornerRadius: UIMetrics.radiusMD))
    }

    private func section(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing3) {
            HStack(spacing: UIMetrics.spacing2) {
                Image(systemName: systemImage)
                    .font(.system(size: UIMetrics.fontFootnote, weight: .semibold))
                    .foregroundStyle(MuxyTheme.fgMuted)
                Text(title)
                    .font(.system(size: UIMetrics.fontFootnote, weight: .semibold))
                    .foregroundStyle(MuxyTheme.fgMuted)
                Spacer(minLength: 0)
            }
            content()
        }
    }

    private func metricGrid(_ models: [CLIProxyUsageMetricTile.Model]) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: UIMetrics.spacing3), GridItem(.flexible(), spacing: UIMetrics.spacing3)],
            alignment: .leading,
            spacing: UIMetrics.spacing3
        ) {
            ForEach(models) { model in
                CLIProxyUsageMetricTile(model: model)
            }
        }
    }

    private func metricLine(title: String, value: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIMetrics.spacing3) {
            Text(title)
                .font(.system(size: UIMetrics.fontBody))
                .foregroundStyle(MuxyTheme.fgMuted)
            Spacer(minLength: UIMetrics.spacing2)
            VStack(alignment: .trailing, spacing: UIMetrics.spacing1) {
                Text(CLIProxyUsageFormatter.redacted(value))
                    .font(.system(size: UIMetrics.fontBody, weight: .medium))
                    .foregroundStyle(MuxyTheme.fg)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(CLIProxyUsageFormatter.redacted(detail))
                        .font(.system(size: UIMetrics.fontFootnote))
                        .foregroundStyle(MuxyTheme.fgDim)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func missingNotice(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: UIMetrics.spacing3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: UIMetrics.fontFootnote, weight: .semibold))
                .foregroundStyle(MuxyTheme.warning)
            VStack(alignment: .leading, spacing: UIMetrics.spacing1) {
                Text(CLIProxyUsageFormatter.redacted(title))
                    .font(.system(size: UIMetrics.fontFootnote, weight: .semibold))
                    .foregroundStyle(MuxyTheme.fgMuted)
                Text(CLIProxyUsageFormatter.redacted(message))
                    .font(.system(size: UIMetrics.fontFootnote))
                    .foregroundStyle(MuxyTheme.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(UIMetrics.spacing3)
        .background(MuxyTheme.surface, in: RoundedRectangle(cornerRadius: UIMetrics.radiusMD))
    }

    private func warningRow(_ warning: CLIProxyUsageWarning) -> some View {
        HStack(alignment: .top, spacing: UIMetrics.spacing3) {
            Image(systemName: warning.severity == .error ? "xmark.octagon" : "info.circle")
                .font(.system(size: UIMetrics.fontFootnote, weight: .semibold))
                .foregroundStyle(warning.severity == .error ? .red : MuxyTheme.warning)
            Text(CLIProxyUsageFormatter.redacted(warning.message))
                .font(.system(size: UIMetrics.fontFootnote))
                .foregroundStyle(MuxyTheme.fgDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusPill(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: UIMetrics.fontCaption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, UIMetrics.spacing2)
            .padding(.vertical, UIMetrics.spacing1)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }

    private func statusColor(_ status: CLIProxyAccountStatus) -> Color {
        switch status {
        case .active: .green
        case .idle: MuxyTheme.fgMuted
        case .cooling: MuxyTheme.warning
        case .disabled,
             .exhausted: .red
        case .error: .red
        case .unknown: MuxyTheme.fgDim
        }
    }
}

private struct CLIProxyUsageMetricTile: View {
    struct Model: Identifiable {
        let id: String
        let title: String
        let value: String
        let detail: String

        init(title: String, value: String, detail: String) {
            id = title
            self.title = title
            self.value = value
            self.detail = detail
        }
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.spacing1) {
            Text(CLIProxyUsageFormatter.redacted(model.title))
                .font(.system(size: UIMetrics.fontFootnote))
                .foregroundStyle(MuxyTheme.fgDim)
                .lineLimit(1)
            Text(CLIProxyUsageFormatter.redacted(model.value))
                .font(.system(size: UIMetrics.fontBody, weight: .semibold))
                .foregroundStyle(MuxyTheme.fg)
                .lineLimit(1)
            Text(CLIProxyUsageFormatter.redacted(model.detail))
                .font(.system(size: UIMetrics.fontFootnote))
                .foregroundStyle(MuxyTheme.fgDim)
                .lineLimit(2)
        }
        .padding(UIMetrics.spacing3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuxyTheme.surface, in: RoundedRectangle(cornerRadius: UIMetrics.radiusMD))
    }
}
