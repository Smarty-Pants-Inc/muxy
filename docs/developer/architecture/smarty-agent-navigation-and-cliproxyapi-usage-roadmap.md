# Milestone: Smarty Agent Navigation and CLIProxyAPI Usage Intelligence

Date: 2026-05-10
Status: Implemented and current-test-gated in the Smarty Code Muxy fork for the agreed read-only agent workbench and CLIProxyAPI usage-intelligence slice. Dev install and CUA dogfood have historical proof; fresh source validation is green after the latest changes. Stable promotion and live mutating agent controls remain explicitly deferred while stable Smarty Code is the running self-hosted app.

## Objective

Turn the Smarty Code Muxy fork into a stronger AI-agent workbench by shipping two coordinated surfaces:

1. **Agent-aware left navigation**: expand the left workspace navigation into a conductor -> orchestrator -> subagent session tree inspired by the abandoned `smarty-zed` control-plane plan, but implemented natively in Smarty Code where custom SwiftUI UX is available.
2. **CLIProxyAPI-native AI usage intelligence**: extend the existing AI Usage popover/settings into a richer view when a local CLIProxyAPI-compatible provider stack is detected, including multi-account status, token usage, token velocity, capacity, and health signals.

The milestone is intentionally split into low-contention tracks so a conductor agent can launch multiple orchestrators in parallel, each using subagents inside its assigned write scope.

## Document Completion Criteria

This document is considered complete when it gives a conductor agent enough information to start implementation without re-discovering the product intent. It must:

- name the target product surfaces and current owning files;
- preserve the abandoned `smarty-zed` conductor/orchestrator/subagent concepts while adapting them to native Smarty Code SwiftUI;
- define CLIProxyAPI detection levels and avoid assuming that one stats API always exists;
- include token velocity and other derived metrics with required source data;
- split implementation into parallel waves with disjoint write scopes and contention rules;
- state verification gates, privacy boundaries, and manual dogfood checks.

## Current Evidence

### Existing Muxy/Smarty Code surfaces

- `Muxy/Views/Sidebar.swift` owns the left project/worktree navigation and footer controls.
- `Muxy/Views/Sidebar/ExpandedProjectRow.swift` already renders project -> worktree hierarchy in the wide sidebar.
- `Muxy/Views/Sidebar/AIUsagePanel.swift` owns the AI Usage sidebar popover.
- `Muxy/Views/Settings/AIUsageSettingsView.swift` owns the AI Usage settings tab.
- `Muxy/Services/AIUsageService.swift`, `AIUsagePreferences.swift`, `AIUsageModels.swift`, `AIUsageProvider.swift`, and `Muxy/Services/Providers/*UsageProvider.swift` form the current provider snapshot pipeline.
- `AIProviderRegistry.usageProviders` now includes Claude Code, Codex, CLIProxyAPI, Copilot, Cursor, Amp, Z.ai, MiniMax, Kimi, and Factory.

### AI Usage preference gate

The existing AI Usage preference gate stays as-is for this milestone.

### `smarty-zed` design to port into native Smarty Code UX

The useful abandoned `smarty-zed` concepts are product concepts, not Zed-specific implementation details:

- durable session control plane: tmux sessions and Codex JSONL logs were treated as authoritative proof;
- session registry model: `role`, `parent_id`, `tmux_session`, `cwd`, `branch`, `codex_log`, `status`, `last_prompt_marker`, and `updated_at`;
- hierarchy: architect/conductor -> orchestrators -> workers/subagents;
- controls: spawn, attach, send prompt, broadcast, open log, open worktree, stop;
- risk banners: shared worktree, stale children, missing log, unverified prompt receipt.

Smarty Code can implement this directly in SwiftUI instead of being constrained by Zed extension panel limitations.

### CLIProxyAPI local facts observed during this spec pass

- Local service: `homebrew.mxcl.cliproxyapi` is running as a LaunchAgent.
- Binary: `/opt/homebrew/opt/cliproxyapi/bin/cliproxyapi`.
- Version observed: `CLIProxyAPI Version: 6.10.5, Commit: Homebrew, BuiltAt: 2026-05-04T15:42:26Z`.
- Config binds to `127.0.0.1:8317` and has `usage-statistics-enabled: true`.
- Installed README says built-in usage statistics were removed in CLIProxyAPI/CPAMC since v6.10.0. It points usage-statistics users to separate collectors such as CPA Usage Keeper or CLIProxyAPI Usage Dashboard, including per-request token collection from the Redis-compatible usage queue into SQLite.

Implication: detection must handle multiple levels of capability instead of assuming one stats API exists:

1. proxy reachable but no stats source;
2. proxy management API reachable but no persisted usage;
3. Redis-compatible usage queue available for recent events;
4. external usage keeper/dashboard SQLite/API available for historical aggregates;
5. future CLIProxyAPI versions/forks with built-in stats restored.

## Product Requirements

### A. Agent-aware left navigation

The wide left nav should become a hierarchical workbench, not just a project switcher:

```text
Project
  Worktree / branch
    Agent Tree
      Conductor session
        Orchestrator session
          Subagent / worker session
```

Shipped read-only slice capabilities:

- Keep the existing compact sidebar behavior fast and uncluttered.
- In wide mode, show expandable project -> worktree -> agent tree hierarchy.
- Show status pills: `ready`, `running`, `blocked`, `complete`, `failed`, `stale`, `unknown`.
- Show proof state separately from agent state: `unverified`, `prompt delivered`, `tool active`, `final reported`, `validated`.
- Surface risk badges for:
  - multiple sessions writing the same worktree;
  - dirty worktree without a committed checkpoint;
  - missing Codex log;
  - tmux session alive but no recent log activity;
  - final report exists but validation gate has not run.
- Provide safe context actions for local references:
  - open Codex JSONL log;
  - open final report;
  - open worktree/project.
- Render the later live-control affordances as disabled stubs until the guarded-control phase explicitly owns them:
  - attach/open terminal;
  - send prompt;
  - broadcast to subtree;
  - mark blocked/complete manually;
  - stop session, guarded by confirmation.
- Never treat terminal appearance as proof. Prompt delivery and completion proof must come from logs or explicit registry events.

Non-goals for this milestone:

- Building a full replacement for Codex subagent internals.
- Automatically killing or cleaning user tmux/Codex sessions without approval.
- Storing host-local session registries in git.

### B. CLIProxyAPI-native AI Usage panel

The existing AI Usage panel should keep provider cards, but add a native CLIProxyAPI section when detected.

Detection should be progressive and local-only:

- Detect configured Codex provider base URL from `~/.codex/config.toml` when safe, but do not require Codex to be installed.
- Probe common local bases: `http://127.0.0.1:8317`, `http://localhost:8317`, plus any user-configured override.
- Confirm OpenAI-compatible proxy health via `/v1/models` using configured local API key only when available.
- Detect CLIProxyAPI-specific capability through management API, version output, config path, Redis usage queue, or supported external keeper/dashboard endpoints.
- Never display or persist raw API keys, OAuth tokens, account emails, or management secrets. Account identifiers in UI should be labels supplied by the proxy or hashed/truncated local IDs.

Required views:

- **Overview**: total tokens by rolling window, active accounts, models in use, and warnings.
- **Accounts**: account/provider rows with quota/headroom, active sessions, current cooling/disabled state, recent failures, and last used time.
- **Velocity**: token velocity and request velocity over 1m/5m/15m/1h windows.
- **Models**: per-model tokens, requests, latency, cache reads/writes where available, and cost estimate if pricing data is reliable.

## CLIProxyAPI Metrics Backlog

Metrics must be capability-gated: show a metric only when its inputs are proven. Prefer an explicit "not available from detected stats backend" explanation over fake zeros.

### High-value metrics

| Metric | Why it is useful | Minimum data required |
| --- | --- | --- |
| Token velocity | Shows live burn rate and whether current work is accelerating. | Timestamped per-request prompt/completion/total tokens. |
| Prompt/completion split | Reveals whether context bloat or generation dominates spend. | Prompt and completion token counts. |
| Cache hit/read/write tokens | Shows how much reported cache activity contributes to prompt reuse. | Provider-specific cache token fields or normalized proxy events. |
| Burn-to-reset / exhaustion ETA | Predicts when an account/model window runs out at current velocity. | Token velocity plus quota/reset window. |
| Account heat map | Shows which accounts are hot, idle, cooling, or exhausted. | Per-account usage events. |
| Capacity score | One glance answer to "how much AI runway do I have right now?" | Quota headroom, cooling state, active sessions, reset windows. |
| Time-to-first-token | Separates proxy/provider latency from generation length. | Request start and first streamed token timestamp. |
| Generation throughput | Shows tokens/sec after first token. | Completion tokens and generation duration. |
| Cost estimate | Useful for paid API-backed providers, but should be marked estimated. | Model pricing table plus normalized token usage. |
| Agent attribution | Shows which conductor/orchestrator/subagent is consuming capacity. | Session/worktree/process labels joined to request metadata. |

### Derived visualizations worth building

- **Velocity sparkline** per account and total, with 5-minute and 1-hour moving averages.
- **Capacity runway**: "at current burn, account A lasts 42m; total pool lasts 3h 10m" when quota windows are known.
- **Refill timeline**: next reset/refill events across accounts/models.
- **Hot-session list**: top sessions by tokens in the last 15 minutes.
- **Context bloat detector**: prompt tokens/request trending upward within the same session.
- **Cache preservation score**: cache tokens divided by prompt tokens, shown only for models/providers that report cache metrics.
- **Model mix**: token share by model family, useful when provider aliases resolve to multiple upstream models.

## Data Model Direction

Do not overload the existing `AIUsageMetricRow` for everything. Keep the current provider snapshot model for simple quota rows, and add a CLIProxyAPI-specific model that can render down into summary cards when needed.

Proposed domain types:

```swift
struct CLIProxyUsageSnapshot: Equatable, Identifiable {
    var id: String
    var fetchedAt: Date
    var baseURL: URL
    var version: String?
    var statsBackend: CLIProxyStatsBackend
    var accounts: [CLIProxyAccountUsage]
    var models: [CLIProxyModelUsage]
    var windows: [CLIProxyUsageWindow]
    var warnings: [CLIProxyUsageWarning]
}

struct CLIProxyUsageWindow: Equatable, Identifiable {
    var id: String
    var label: String        // 1m, 5m, 15m, 1h, today, current quota window
    var startsAt: Date
    var endsAt: Date?
    var promptTokens: Int
    var completionTokens: Int
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var requestCount: Int
    var errorCount: Int
}

struct CLIProxyAccountUsage: Equatable, Identifiable {
    var id: String           // stable local hash or proxy-safe id
    var displayName: String
    var providerKind: String // codex, claude, gemini, openai-compatible, unknown
    var status: CLIProxyAccountStatus
    var activeSessionCount: Int?
    var quota: CLIProxyQuotaWindow?
    var recent: [CLIProxyUsageWindow]
}
```

The exact schema should be finalized by the CLIProxyAPI discovery track after inspecting the real stats source selected for this machine.

## Implemented Current State

- Agent navigation is implemented as a hidden wide-sidebar tree gated by `smarty.agentTree.enabled` or `SMARTY_CODE_AGENT_TREE_ENABLED`. It reads `/tmp/smarty-code-agent-usage-milestone/agent-sessions.json` by default, supports an override with `SMARTY_CODE_AGENT_SESSION_REGISTRY`, preserves compact sidebar behavior, and keeps mutating controls disabled.
- Agent session models parse conductor/orchestrator/subagent roles, lifecycle state, proof state, risk flags, local references, and attribution join labels from local registry JSON. Derived risks include shared worktree, dirty worktree, missing log, live-tmux stale log, unverified prompt receipt, unvalidated final report, and stale child.
- CLIProxyAPI usage intelligence is implemented as a local-only provider plus native AI Usage section. It probes local Codex config/default bases for `/v1/models`, then looks for collector-compatible normalized snapshots at `/v0/usage/snapshot`, `/api/usage/snapshot`, or `/usage/snapshot`. When a configured plaintext management key is available, it probes `/v0/management/usage-queue`, drains CLIProxyAPI 6.10.x usage queue records into app-owned SQLite, and replays persisted normalized events for rolling history. It reports the probed stats surfaces, the detected stats backend, proxy version header availability, local binary/config findings, safe management probe status, and whether Redis-queue/external/built-in collector data was detected. Wrong-key management failures back off before retrying so Smarty Code does not create a lockout loop.
- The native CLIProxyAPI view renders overview, capabilities, accounts, refill timeline, velocity, hot sessions, and models. It shows last-used time, recent failure, cache read/write tokens, cache preservation score, latency, time-to-first-token, generation throughput, cost estimates, rolling windows, textual velocity sparkline, runway, capacity, context-bloat signals, and confirmed/suggested agent attribution only when the collector payload and local agent registry provide the required inputs. Missing usage-history, quota, cache, latency, timing, throughput, cost, refill, context-bloat, or session-attribution data is rendered as explicit unavailable state instead of zeroes.
- The build script is Apple Silicon-only and thins copied framework/helper binaries to arm64 before signing so Smarty Code bundles do not retain nested x86_64 helper slices.

## Current Validation Snapshot

Validated on 2026-05-11 after the Dev-only agent-tree refresh fix and CUA
proof pass. Stable `Smarty Code` is the running self-hosted app and was not
quit, queued, installed, or promoted during this pass.

Source and build gates:

- `swift test --filter AgentTreeView` passed with 9 tests.
- `swift test --filter 'TerminalEnvVarBuilder|AgentSessionRegistry|CLIProxyUsage|AgentTreeView'` passed with 69 tests across terminal environment, agent registry, agent tree, CLIProxyAPI provider/parser/collector/metrics, and CLIProxyAPI section formatter suites after the latest derived-metrics and accessibility/performance hardening changes.
- `scripts/checks.sh` passed formatting, linting, build, and full test gates; the latest pass on 2026-05-11 completed in 16s after formatting the metrics file.
- After adding the live-tmux stale-log risk gate, `swift test --filter AgentSessionRegistry` passed with 9 tests and `scripts/checks.sh` passed again.
- `scripts/build-smarty-code.sh --channel dev --install` rebuilt and installed `Smarty Code Dev` build 487 after the latest source changes.
- `./scripts/verify-smarty-code-apps.sh --channel dev --expected-build 487 --source-app forks/muxy/build/smarty-code/dev/Smarty Code Dev.app` passed after the latest install: bundle id `com.smartypants.smarty-code.dev`, arm64 binary, zero nested x86_64 Mach-O files, codesign OK, and source match OK.
- Parent wrapper/script gates also passed: `bash -n scripts/verify-smarty-code-apps.sh scripts/queue-smarty-code-stable-install.sh scripts/promote-smarty-code-stable.sh scripts/open-smarty-code-full-disk-access.sh forks/muxy/scripts/build-smarty-code.sh` and `uv run --with pytest python -m pytest tests/test_smarty_wrapper.py` with 14 tests.

Dev-channel GUI dogfood evidence, captured with the installed `cua-driver`/CUA
path only:

- `/tmp/smarty-code-dev-agenttree-fixed.json` and `.png` show the wide sidebar
  rendering `smarty-code -> primary -> Agent sessions for smarty-code` with
  `Roadmap conductor`, `Navigation + Usage orchestrator`, and `CLIProxyAPI proof
  worker` rows. The same AX snapshot shows separate lifecycle status, proof
  badges, and risk badges such as `Status: Running`, `Proof: Tool`, `Status:
  Complete`, `Proof: Validated`, `Risk: Shared`, `Risk: Dirty`, and `Risk:
  Stale log`.
- `/tmp/smarty-code-dev-ai-usage-current-space.json` and `.png` show the AI
  Usage popover rendering the native `CLIProxyAPI usage` section. The live local
  service is reported as `Proxy only · http://127.0.0.1:8317`, `reachable`, with
  explicit missing-capability states for rolling tokens, accounts, capacity,
  models, usage history, velocity, hot sessions, and model mix instead of fake
  zeroes.

Operational safety evidence:

- This pass did not use or start Codex Computer Use. Host process state may
  include unrelated/pre-existing Codex Computer Use MCP processes, so process
  listings alone must not be used as proof of this milestone's GUI automation
  path. Stable `Smarty Code` remained the self-hosted app and was not quit,
  installed, promoted, or queued by this pass.
- Codex Computer Use must not be used for this project. It can trigger broad
  macOS app-data TCC prompts. Use the installed `cua-driver`/CUA skill path only,
  and stop rather than falling back to Codex Computer Use.

### Stable Promotion State

Stable promotion is intentionally deferred because this session is running inside
stable `Smarty Code`.

- Installed stable remains the user's live daily-driver app and must be treated
  as hands-off until Paul explicitly asks to quit/promote/install it.
- No live queued stable installer is currently active. The old log
  `/tmp/smarty-code-stable-install-20260510153102.log` is historical and only
  shows a prior helper waiting for stable to quit.
- Before any future stable promotion, rebuild/verify the exact stable bundle and
  install only after Paul confirms stable can be quit. Then run:

```bash
./scripts/verify-smarty-code-apps.sh --channel stable --expected-build 487 --source-app "forks/muxy/build/smarty-code/stable/Smarty Code.app"
```

Expected stable evidence is build 487 or newer as appropriate, arm64-only,
zero nested x86_64 Mach-O files, successful codesign verification, and installed
binary SHA-256 matching the rebuilt source app.

### Dev Dogfood Setup

The Dev proof depends on the local, out-of-git fixture and prefs below:

- `/tmp/smarty-code-agent-usage-milestone/agent-sessions.json` contains a
  conductor -> orchestrator -> subagent fixture with local Codex-log and final
  report references under the same directory.
- `com.smartypants.smarty-code.dev` has `smarty.agentTree.enabled=1`,
  `muxy.usage.enabled=1`, and `muxy.usage.provider.cliproxyapi.enabled=1`.

### Completion Audit Checkpoint

| Product DoD item | Evidence | Status |
| --- | --- | --- |
| 1. Navigation hierarchy | `AgentTreeView`, `AgentTreeSupport`, `AgentSessionRegistry`, `SidebarLayoutTests`, targeted tests, and `/tmp/smarty-code-dev-agenttree-fixed.json` prove the wide project/worktree/agent hierarchy in Dev. Compact/sidebar mode preservation is source/test-gated. | Dev source/test/CUA proven; not stable-promoted. |
| 2. Agent proof separation | `AgentSessionModels` keeps lifecycle and proof state distinct; registry tests derive proof from registry/Codex JSONL/final-report signals; Dev CUA shows separate `Status` and `Proof` badges. | Source/test/Dev CUA proven. |
| 3. Safe controls | Open-worktree/log/final-report references validate local paths before opening; mutating controls remain disabled in this read-only slice. Live-tmux stale-log risk is injected/tested instead of inferred solely from `running` state. | Safe read-only slice proven; full guarded attach/send/broadcast/mark/stop control phase is explicitly deferred. |
| 4. CLIProxyAPI detection | `CLIProxyUsageService` parses local Codex config including `experimental_bearer_token`, probes local `/v1/models`, normalized stats endpoints, local binary/config, Redis-queue hints, and management endpoints only with a configured management key. The accepted management-key env vars are `CLIPROXYAPI_MANAGEMENT_KEY`, `CLIPROXYAPI_REMOTE_MANAGEMENT_KEY`, and `CLIPROXYAPI_MANAGEMENT_SECRET_KEY`. `/v0/management/usage-queue` records are normalized into app-owned SQLite when management auth succeeds, with wrong-key backoff and persisted replay when the queue is empty. Live Dev CUA reports `Proxy only` reachable because no management key-backed live collector was enabled during dogfood. | Source/test/Dev CUA proven; live stats backend remains capability-gated. |
| 5. CLIProxyAPI-native view | `CLIProxyUsageSection` renders overview, capabilities, accounts, refill timeline, velocity, hot sessions, and models; formatter/tests cover textual velocity sparkline, cache preservation, context bloat, and refill rows. `/tmp/smarty-code-dev-ai-usage-current-space.json` historically proves the installed Dev popover renders the native CLIProxyAPI section in proxy-only mode. | Source/current-test proven; Dev CUA artifact is historical. |
| 6. Capability-gated metrics | Metrics/parser/UI tests cover missing-history/quota/cache/latency/timing/throughput/cost/attribution/refill/context-bloat explanations; Dev CUA shows unavailable states instead of zeroes for the live proxy-only backend. | Source/current-test proven; live velocity/history requires a management-key-backed collector or external stats backend. |
| 7. Validation and promotion | Targeted tests, `scripts/checks.sh`, Dev build/install, and Dev source-match verifier passed after the latest changes. | Dev complete; stable promotion/source-match intentionally deferred while stable is the running app. |

### Remaining Completion Risks / Gaps

These items prevent claiming the entire roadmap is fully complete if the target
scope includes stable promotion or the later control/collector phases:

- Stable is not source-matched to the latest dirty-worktree build because stable
  is currently the running self-hosted app and was intentionally untouched.
- Full mutating agent controls (`attach`, `send prompt`, `broadcast`, `mark
  blocked`, `mark complete`, `stop`) are intentionally not implemented; the
  completed slice ships safe disabled stubs plus local open-reference actions. A
  future guarded-control phase must prove session identity, confirmation UX,
  logging, and rollback behavior before enabling these actions.
- The Smarty Code-owned Redis-queue -> SQLite collector is implemented and
  unit-tested, but live dogfood still reports proxy-only when no management key
  is configured for the app. This is intentional capability-gating, not a fake
  zero-history state.
- Compact mode is covered by source/tests; after the Dev CUA proof, further GUI
  attempts were stopped to avoid more macOS TCC prompts and because Codex
  Computer Use is now explicitly forbidden for this workflow.
- Registry-scale performance is covered by a 131-session parser/cache test with
  deduplicated process probes. Large SwiftUI sidebar responsiveness with 100+
  visible sessions plus large project lists remains future visual/performance
  dogfood.

## Parallel Roadmap

### Wave 0 — Integration seed and contracts

Conductor owns this wave.

Deliverables:

- Commit this milestone spec into the integration branch.
- Create an out-of-git orchestration registry under `/tmp/smarty-code-agent-usage-milestone/`.
- Create one integration branch and one branch/worktree per track.
- Assign disjoint write scopes before launching agents.

Verification:

```bash
git status --short --branch
git -C forks/muxy status --short --branch
git -C forks/muxy worktree list --porcelain
```

### Wave 1 — Discovery and prototypes, maximum parallelism

These tracks can run concurrently because they should be read-mostly or isolated prototype work.

| Track | Scope | Primary outputs | Avoid touching |
| --- | --- | --- | --- |
| 01 Navigation IA | Map current sidebar/worktree UX and propose final hierarchy/components. | UX spec, component boundaries, accessibility checklist. | AI usage service/provider code. |
| 02 Agent registry/control | Design session registry, tmux/log readers, and safe controls. | Data contract, mocked registry fixtures, proof strategy. | Existing sidebar rendering except documented integration points. |
| 03 CLIProxyAPI discovery | Prove current stats surfaces and external collector options. | Detection matrix, sample payloads with secrets redacted, recommended backend. | SwiftUI navigation components. |
| 04 Metrics engine | Define rolling-window math, velocity, ETA, capacity score, and tests. | Pure Swift calculators with fixture tests. | Network probing and UI. |
| 05 Usage UX | Design CLIProxyAPI panels and empty states. | Wireframes or SwiftUI preview prototypes. | Service/network implementation. |
| 06 Test harness | Decide unit/UI/integration tests and fixture redaction rules. | Test plan, fixtures, CI/check commands. | Product implementation outside tests/docs. |

Wave 1 gate:

- Every track reports exact files changed, evidence gathered, and recommended next write scope.
- CLIProxyAPI discovery must state whether metrics come from management API, Redis usage queue, an external SQLite/API keeper, or a new local collector.
- No track may require secrets in committed fixtures.

### Wave 2 — Parallel implementation behind feature flags

Run after Wave 1 contracts are accepted.

| Track | Owned write scope | Deliverables | Verification |
| --- | --- | --- | --- |
| 10 Sidebar hierarchy | `Muxy/Views/Sidebar*`, new sidebar components as needed, related view tests/previews. | Project/worktree/agent tree UI behind a setting or hidden feature flag. | SwiftUI previews plus targeted tests. |
| 11 Agent session model | New agent/session registry service/models and fixture tests. | Read-only registry rendering from fixture/local state; safe action stubs. | Unit tests for registry parsing/status transitions. |
| 12 CLIProxyAPI provider | New CLIProxyAPI detection/provider service and settings integration. | Capability-gated provider snapshot with safe errors. | Unit tests with URLProtocol/fixture responses. |
| 13 Metrics calculators | Pure calculators for velocity, ETA, capacity, and heat. | Deterministic math tests over synthetic windows. | `swift test --filter` targeted calculators. |
| 14 Usage panel UI | `AIUsagePanel` extension/components for CLIProxyAPI-native cards. | Overview/accounts/velocity/models UI. | Snapshot/preview/manual validation. |

Contention rule: Tracks 10 and 14 both touch UI. Launch them in parallel only if their component paths are separated; otherwise run them in sequential mini-waves after shared model contracts land.

### Wave 3 — Integration and real local validation

Conductor merges in this order unless Wave 1 finds a better dependency graph:

1. pure models/calculators/tests;
2. CLIProxyAPI detection/provider;
3. agent registry/control read-only layer;
4. usage panel UI;
5. sidebar hierarchy UI;

After each risky merge:

```bash
cd forks/muxy
scripts/checks.sh
```

For the final integrated milestone:

```bash
cd forks/muxy
scripts/setup.sh
scripts/checks.sh
scripts/build-smarty-code.sh --channel dev
scripts/build-smarty-code.sh --channel stable
```

Manual gates:

- Launch `Smarty Code Dev` first.
- Confirm missing-capability explanations are clear and never expose secrets.
- Confirm token velocity changes when a controlled local request is made through the proxy, if a stats backend is available.
- Confirm agent-tree fixture/local registry renders without disturbing existing tmux or Codex sessions.
- Promote to stable only after dev-channel validation.

### Wave 4 — Hardening and release readiness

- Accessibility: VoiceOver labels for agent rows, status pills, and metric charts.
- Privacy: redaction tests for account IDs, tokens, management keys, URLs with credentials.
- Performance: sidebar remains responsive with 100+ sessions and large project lists.
- Failure modes: proxy offline, stats backend missing, malformed events, clock skew, reset-window unknown, stale tmux sessions.
- Docs: update feature docs and troubleshooting after implementation, not before behavior exists.

## Conductor Operating Instructions

When using this document as a launch plan:

1. Treat this file as the milestone source of truth until a later spec supersedes it.
2. Use one integration branch and separate branch/worktree per track.
3. Give each orchestrator a bounded write scope and tell it not to revert or disturb other tracks.
4. Require each orchestrator to keep its own todo list, use subagents for bounded internal review/proof, and produce a final report with:
   - changed files;
   - tests run;
   - manual validation;
   - blockers;
   - merge risks;
   - follow-up recommendations.
5. Verify orchestrator prompt delivery and completion through Codex JSONL logs when tmux/Codex sessions are used.
6. Merge only after inspecting diffs and running the relevant gate.
7. Keep host-local CLIProxyAPI secrets, management keys, account files, tmux registries, and Codex logs out of git.

## Orchestrator Launch Contracts

Use these launch contracts when creating track worktrees. Each orchestrator may spawn its own subagents, but must keep edits inside the owned write scope unless it explicitly reports a blocker and receives approval to broaden scope.

| Track | Branch/worktree slug | Owned write scope | Required final artifacts | Acceptance gate |
| --- | --- | --- | --- | --- |
| 01 Navigation IA | `agent-nav-ia` | Docs/prototypes for sidebar hierarchy only. | `HANDOFF.md` or final report section with component map and accessibility checklist. | Conductor can assign Track 10 without more UX discovery. |
| 02 Agent registry/control | `agent-registry` | New agent registry/control model docs or isolated fixtures. | Registry schema, status transition table, safety policy. | Track 11 has stable model contracts and fixture examples. |
| 03 CLIProxyAPI discovery | `cliproxy-discovery` | Probe scripts/docs/fixtures only; no UI implementation. | Redacted detection matrix and recommended stats backend. | Track 12 knows exactly which API/queue/database to implement first. |
| 04 Metrics engine | `cliproxy-metrics` | Pure metrics calculators and tests after model contract is agreed. | Formula notes and deterministic fixtures. | Velocity/ETA/capacity tests fail before implementation and pass after. |
| 05 Usage UX | `usage-ux` | SwiftUI preview/prototype files or docs; no network code. | Empty states, layout sketches, information architecture. | Track 14 can implement without changing service contracts. |
| 06 Test harness | `test-harness` | Tests/fixtures/docs for verification strategy. | Redaction rules and command matrix. | Conductor knows exact gates per implementation track. |
| 10 Sidebar hierarchy | `sidebar-hierarchy` | `Muxy/Views/Sidebar*` and new sidebar components only. | UI implementation plus preview/manual proof. | Sidebar renders project/worktree/agent hierarchy and compact mode is unchanged. |
| 11 Agent session model | `agent-session-model` | New agent/session service/models/tests. | Read-only registry implementation and tests. | Fixture/local registry can render without touching host tmux sessions. |
| 12 CLIProxyAPI provider | `cliproxy-provider` | CLIProxyAPI detection/provider service and provider tests. | Capability-gated snapshots and safe missing-capability explanations. | Offline, no-stats, and stats-available fixtures all behave correctly. |
| 13 Metrics calculators | `metrics-calculators` | Pure calculator files/tests. | Rolling-window velocity, ETA, and capacity calculators. | Deterministic tests cover edge cases and missing-data behavior. |
| 14 Usage panel UI | `usage-panel-ui` | `AIUsagePanel` components and related UI only. | Overview/accounts/velocity/models UI. | UI renders from fixtures and hides unavailable metrics honestly. |

Orchestrator goal prompt template:

```text
Read docs/developer/architecture/smarty-agent-navigation-and-cliproxyapi-usage-roadmap.md.
You own Track <NN> only: <owned write scope>. Do not revert or disturb other tracks.
Keep your todo list updated. Use bounded subagents for independent review/proof.
Implement the track to its acceptance gate, run the specified verification, and produce a final report listing changed files, commands run, manual checks, blockers, and merge risks.
If you need to edit outside scope or touch host-local secrets/tmux/Codex sessions, stop and report the exact blocker first.
```

## Recommended Decisions For Former Open Questions

These are the default decisions for implementation. Paul can override them, but orchestrators should proceed with these answers unless told otherwise.

### 1. Agent registry/control scope

**Decision:** Start with a read-only agent registry that observes tmux/Codex logs, local registry fixtures, and worktree state. Do not launch, kill, broadcast, or mutate live Codex/tmux sessions in the first implementation slice.

Rationale:

- The first product risk is representation and proof, not automation power.
- Read-only ingestion lets the sidebar safely render conductor -> orchestrator -> subagent trees without risking the user's live tmux/Codex sessions.
- It keeps the initial UI testable from fixtures and local JSONL/log state.
- Mutating controls can be added after identity, proof state, and safety boundaries are reliable.

Implementation impact:

- Track 11 owns a read-only `AgentSessionRegistry`/model first.
- Track 10 may render disabled/guarded action buttons, but destructive or externally visible actions must stay unavailable until a later explicit control phase.
- `Attach`/`Open Log`/`Open Worktree` can ship first because they are navigational; `Send Prompt`/`Broadcast`/`Stop` require a later guarded-control gate.

### 2. Canonical CLIProxyAPI stats backend

**Decision:** Make a small Smarty Code-owned local collector the canonical backend, using CLIProxyAPI's Redis-compatible usage queue as the preferred raw event source when available and persisting normalized events into app-owned SQLite. Treat management API data as configuration/account/health metadata, not as the primary usage history source. Treat CPA Usage Keeper and CLIProxyAPI Usage Dashboard as optional import/probe adapters, not required dependencies.

Rationale:

- The installed CLIProxyAPI README for v6.10.x says built-in usage statistics are no longer shipped in CLIProxyAPI/CPAMC.
- Token velocity, hot sessions, moving averages, ETA, and attribution all need timestamped per-request events, not just aggregate account metadata.
- Owning the lightweight local collector keeps the Smarty Code UX local-first and avoids requiring the user to install another dashboard just to see native metrics.
- Persisting normalized events in SQLite gives deterministic tests and stable rolling-window calculations.

Implementation impact:

- Track 03 must prove whether the Redis-compatible usage queue is enabled and what payload shape it exposes on this machine.
- Track 12 should implement capability detection in this order: proxy reachable -> management/config metadata -> Redis queue collector -> optional external keeper/dashboard adapters.
- If no event source is available, the panel should explicitly mark velocity/history metrics unavailable.

### 3. Token/cost attribution

**Decision:** Use explicit session labels/registry bindings as the authoritative attribution source. Use process cwd, terminal pane cwd, request metadata, or conversation/session IDs only as confidence-scored suggestions until the user or registry confirms the binding.

Rationale:

- Automatic cwd attribution can be wrong for multiplexed shells, reused tmux sessions, remote commands, background jobs, and model requests that use aliases.
- Cost and velocity dashboards should not falsely blame the wrong project/worktree.
- Explicit labels align with the conductor/orchestrator registry model and are easier to audit.

Implementation impact:

- The UI should distinguish `Attributed to <project>` from `Suggested: <project>`.
- Aggregates that affect decisions, warnings, or cost rollups should use only confirmed attribution.
- Track 11 should expose stable session/worktree labels that Track 12/13 can join against request/session IDs.
- Track 13 should include tests for unknown, suggested, and confirmed attribution states.
