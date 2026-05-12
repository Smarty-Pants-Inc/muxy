# AI Usage Tracking

Muxy reads usage / quota data for the user's AI coding tools and surfaces it in a sidebar popover. Tracking is **read-only**: Muxy reads credentials the user already configured for each tool and queries the vendor's usage endpoint directly. Nothing is written to tools' settings; nothing leaves the user's Mac for Muxy's servers.

## Component map

```mermaid
flowchart TB
  Service[AIUsageService<br/>@Observable @MainActor singleton]
  Service --> Prefs[AIUsagePreferences<br/>tracking / enabled / global]
  Service --> Catalog[AIUsageProviderCatalog<br/>from AIProviderRegistry]
  Service --> Fetch[fetchSnapshots<br/>TaskGroup]
  Fetch --> Provider[AIUsageProvider]
  Provider --> Token[AIUsageTokenReader<br/>env / JSON / Keychain]
  Provider --> OAuth[AIUsageOAuth<br/>refresh access token]
  Provider --> Session[AIUsageSession<br/>HTTP + common errors]
  Provider --> Parser["{Provider}UsageParser"]
  Parser --> Rows[AIUsageMetricRow]
  Service --> Auto[AIUsageAutoTracking]
  Service --> Compose[SnapshotComposer + RowPolicy]
  Compose --> Footer[SidebarFooter popover]
```

The service is observed by `SidebarFooter` (preview icon + popover) and `AIUsageSettingsView`. Both hold the singleton as `let` and rely on `@Observable` to invalidate on read.

## Providers

`AIUsageProvider` is the read-only counterpart to `AIProviderIntegration`. A single concrete type can adopt both (e.g. `ClaudeCodeProvider` installs hooks AND fetches usage). `AIProviderRegistry.usageProviders` lists all usage providers — Claude Code, Codex, CLIProxyAPI, Copilot, Amp, Z.ai, MiniMax, Kimi, Factory.

Each provider has a matching `{Name}UsageParser` taking raw JSON → `[AIUsageMetricRow]`. Parsers are unit-tested against fixture payloads in `Tests/MuxyTests/Services/*UsageParserTests.swift`; HTTP paths are tested with `URLProtocol` stubs in `*UsageAPIClientTests.swift` where present.

## Credentials

`AIUsageTokenReader` is the single entry point, tried in provider-defined order:

1. Environment variables (`CLAUDE_CODE_OAUTH_TOKEN`, `ZAI_API_KEY`, …).
2. JSON credential files written by the vendor CLI under `~/.claude`, `~/.codex`, etc. Some providers honor env-var overrides (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
3. macOS Keychain via `/usr/bin/security find-generic-password`. The account name is passed via `Process.arguments` (array form, not a shell string) to avoid argument injection.

OAuth providers (Factory, Kimi) use `AIUsageOAuth.refreshAccessToken` to exchange a refresh token and persist the updated credential file with the same shape the vendor CLI wrote.

## Refresh lifecycle

`AIUsageService.refresh(force:)` and `refreshIfNeeded()` are coalesced: an in-flight task is awaited rather than parallelized. `@MainActor` plus an internal `refreshTask` field gates concurrent entry. Auto-refresh cadence is `AIUsageAutoRefreshInterval` (5m / 15m / 30m / 1h) persisted in UserDefaults; a 60-second view-level timer in `SidebarFooter` calls `refreshIfNeeded` and the service decides whether enough time has elapsed.

## Settings & defaults

Per-provider flags live in `UserDefaults` keyed by the canonical provider ID:

| Key | Purpose |
| --- | --- |
| `muxy.usage.provider.<id>.tracked` | Provider has at least one snapshot; included in the popover. |
| `muxy.usage.provider.<id>.enabled` | User toggle in settings. |
| `muxy.usage.enabled` | Global on/off. |
| `muxy.usage.displayMode` | `used` or `remaining`. |
| `muxy.usage.autoRefreshIntervalSeconds` | Cadence. |
| `muxy.usage.showSecondaryLimits` | Show weekly/monthly/billing rows. |

On first launch `AIUsageSettingsStore.isUsageEnabled()` runs a one-shot migration: if any provider already has a tracked preference, the global flag is turned on so users who enabled tracking before the global toggle existed keep seeing the panel.

## Row policy

`AIUsageRowPolicy` splits metric rows into primary (session / 5h / hourly / premium) and secondary (weekly / monthly / daily / billing) buckets by label prefix. By default the UI shows only primary rows; the "Show Secondary Limits" toggle opts into the full list. Dollar-denominated detail strings are filtered out so the sidebar stays focused on quotas.

## CLIProxyAPI

`CLIProxyUsageProvider` is local-only and capability-gated. It first confirms an OpenAI-compatible local proxy with `/v1/models`, then looks for normalized usage snapshots exposed by a local collector-compatible endpoint (`/v0/usage/snapshot`, `/api/usage/snapshot`, or `/usage/snapshot`). If a plaintext CLIProxyAPI management key is configured locally, the provider probes `/v0/management/usage-queue`, drains CLIProxyAPI 6.10.x queue records into app-owned SQLite, and replays persisted normalized events for rolling history after the destructive queue is empty. The provider also reports which stats endpoints were probed, whether a version surface was exposed by the local proxy, whether management endpoints were safely probed, and whether the detected snapshot represents SQLite-collected Redis-queue data, an external collector/dashboard, or built-in usage data. Wrong-key management failures are backed off before retrying. If no collector/dashboard/built-in stats source responds, Muxy reports the missing usage-history capability instead of rendering zero-token history.

CLIProxyAPI snapshots may include account `lastUsedAt`, `recentFailure`, quota reset windows, per-request `sessionID`, cache read/write token counts, request latency, time-to-first-token, generation duration, and `costEstimateUSD`. These fields render only when present in the collector payload; missing cache/cost/latency/quota/refill/context-bloat/session-attribution data is called out as unavailable rather than inferred. When session IDs match the local agent registry's explicit attribution join keys, the native view labels hot sessions as confirmed or suggested agent usage. Queue records without explicit future session/conversation/thread fields are not treated as attributed sessions. Account identifiers, session identifiers, warning text, failure messages, URLs, and model/account display strings pass through the CLIProxyAPI redactor before UI display.
