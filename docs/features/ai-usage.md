# AI Usage

Muxy reads usage / quota data from common AI coding providers and surfaces it in a sidebar popover. Toggle the popover with `⌘L` or **View → AI Usage**.

```mermaid
flowchart TB
  Sidebar[Sidebar popover ⌘L]
  Settings[Settings → AI Usage]
  Sidebar --> Service[AIUsageService]
  Settings --> Service
  Service --> Tokens[Env vars / JSON files / Keychain]
  Service -->|HTTPS| Vendors[Provider APIs]
  Tokens --> Vendors
```

Tracking is **read-only** — Muxy reads tokens you've already configured for each tool and queries each vendor directly. Nothing is sent to Muxy's servers.

## Supported providers

Claude Code · OpenAI Codex CLI · CLIProxyAPI · GitHub Copilot · Cursor CLI · Amp · Z.ai · MiniMax · Kimi · Factory.

Enable / disable each in **Settings → AI Usage**.

## What's shown

Per provider, you see what that provider exposes — typically some combination of:

- Session / 5h / hourly windows
- Premium request count
- Daily / weekly / monthly limits
- Billing period summary

Toggle **Show Secondary Limits** in settings to keep the popover compact.

## Where the data comes from

| Source | Used for |
| --- | --- |
| Environment variables | e.g. `CLAUDE_CODE_OAUTH_TOKEN`, `ZAI_API_KEY` |
| Vendor JSON credential files | `~/.claude`, `~/.cursor`, `~/.codex`, … (overridable via `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, …) |
| macOS Keychain | via `/usr/bin/security find-generic-password` |

For providers that need OAuth refresh (Claude Code, Factory, Kimi), Muxy refreshes tokens silently before fetching usage.

## CLIProxyAPI native view

When a local CLIProxyAPI-compatible proxy is enabled as a provider, the popover adds a native local-only section. It probes local endpoints such as `127.0.0.1:8317` plus local Codex config, then shows only the metrics supported by the detected backend:

- overview cards for rolling tokens, accounts, capacity, and model count;
- account rows with status, quota/headroom, active sessions, last-used time, recent failure, and runway when available;
- token/request velocity for rolling windows, including a compact textual sparkline when history exists;
- refill timeline rows when quota reset windows are known;
- hot sessions by recent token usage, with context-bloat signals and confirmed/suggested agent attribution when local agent registry labels match request session IDs;
- model mix with prompt/completion split, cache read/write tokens, cache preservation score, latency, and estimated cost when available.

The preferred stats source is Smarty Code's local collector: when a local CLIProxyAPI management key is explicitly configured, it reads CLIProxyAPI's Redis-compatible usage queue and persists normalized events into app-owned SQLite for rolling history. The stock CLIProxyAPI 6.10.x Homebrew build no longer ships built-in persisted usage statistics, so if the proxy is reachable but no collector/dashboard/built-in stats source is available, velocity/history cards say why they are unavailable instead of showing fake zeroes. The panel also reports which local snapshot endpoints were probed, backs off after wrong-key management failures, and leaves management endpoints unprobed unless a local management key is configured. Sensitive values such as API keys, account emails, bearer tokens, and URL credentials are redacted before display.

## Auto-refresh

Choose an interval in **Settings → AI Usage**: Off / 5m / 15m / 30m / 1h. Manual refresh is always available from the popover.

## Hook integrations

For Claude Code, OpenCode, Codex, and Cursor, Muxy can also receive real-time usage and notification events through hook scripts that ship with the app. See [Notifications](notifications.md) for the shared hook setup.
