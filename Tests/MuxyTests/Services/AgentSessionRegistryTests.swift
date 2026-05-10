import Foundation
import Testing

@testable import Muxy

@Suite("AgentSessionRegistry")
struct AgentSessionRegistryTests {
    @Test("composes conductor orchestrator subagent hierarchy deterministically")
    func hierarchyComposition() throws {
        let fixture = """
        {
          "sessions": [
            {
              "id": "worker-1",
              "parent_id": "orchestrator-1",
              "role": "worker",
              "title": "Fixture worker",
              "status": "complete",
              "proof_status": "validated",
              "cwd": "/repo/feature",
              "branch": "feature/nav",
              "codex_log": "/logs/worker.jsonl"
            },
            {
              "id": "conductor-1",
              "role": "conductor",
              "title": "Roadmap conductor",
              "status": "running",
              "proof_status": "tool-active",
              "cwd": "/repo",
              "branch": "main",
              "codex_log": "/logs/conductor.jsonl"
            },
            {
              "id": "orchestrator-1",
              "parent_id": "conductor-1",
              "role": "orchestrator",
              "title": "Track 11",
              "status": "blocked",
              "proof_status": "prompt delivered",
              "cwd": "/repo/feature",
              "branch": "feature/nav",
              "codex_log": "/logs/orchestrator.jsonl"
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            now: Date(timeIntervalSince1970: 2_000),
            deriveFileRisks: false
        )

        #expect(snapshot.sessions.map(\.id) == ["conductor-1", "orchestrator-1", "worker-1"])
        #expect(snapshot.roots.count == 1)

        let conductor = try #require(snapshot.roots.first)
        #expect(conductor.session.role == .conductor)
        #expect(conductor.session.status == .running)
        #expect(conductor.children.count == 1)

        let orchestrator = try #require(conductor.children.first)
        #expect(orchestrator.session.role == .orchestrator)
        #expect(orchestrator.session.status == .blocked)
        #expect(orchestrator.session.proofStatus == .promptDelivered)
        #expect(orchestrator.children.count == 1)

        let worker = try #require(orchestrator.children.first)
        #expect(worker.session.role == .subagent)
        #expect(worker.session.status == .complete)
        #expect(worker.session.proofStatus == .validated)
    }

    @Test("parses lifecycle proof and explicit risk aliases")
    func parsingAliases() throws {
        let fixture = """
        [
          {
            "id": "a",
            "role": "architect",
            "status": "in_progress",
            "proof_status": "final reported",
            "risk_flags": ["dirty-worktree", "missing log", "validation-pending"],
            "updated_at": "2026-05-10T12:00:00Z"
          },
          {
            "id": "b",
            "parent_id": "a",
            "role": "sub-agent",
            "status": "done",
            "proof_status": "prompt_delivered"
          }
        ]
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            now: Date(timeIntervalSince1970: 2_000),
            deriveFileRisks: false
        )

        let architect = try #require(snapshot.session(id: "a"))
        #expect(architect.role == .architect)
        #expect(architect.status == .running)
        #expect(architect.proofStatus == .finalReported)
        let expectedUpdatedAt = try #require(ISO8601DateFormatter().date(from: "2026-05-10T12:00:00Z"))
        #expect(architect.updatedAt == expectedUpdatedAt)
        #expect(architect.riskFlags == [.dirtyWorktree, .missingLog, .unvalidatedFinalReport])

        let subagent = try #require(snapshot.session(id: "b"))
        #expect(subagent.role == .subagent)
        #expect(subagent.status == .complete)
        #expect(subagent.proofStatus == .promptDelivered)
    }

    @Test("derives stale missing log shared worktree and proof risks")
    func derivedRisks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let staleLog = tempDir.appendingPathComponent("stale.jsonl")
        try "{}\n".write(to: staleLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: staleLog.path
        )

        let fixture = """
        {
          "sessions": [
            {
              "id": "conductor",
              "role": "conductor",
              "status": "running",
              "proof_status": "unverified",
              "cwd": "/repo/shared",
              "codex_log": "missing.jsonl"
            },
            {
              "id": "orchestrator",
              "parent_id": "conductor",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "tool_active",
              "cwd": "/repo/shared",
              "codex_log": "stale.jsonl"
            },
            {
              "id": "subagent",
              "parent_id": "orchestrator",
              "role": "subagent",
              "status": "stale",
              "proof_status": "final_reported",
              "cwd": "/repo/other",
              "codex_log": "stale.jsonl",
              "final_report": "FINAL_REPORT.md"
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            baseURL: tempDir,
            now: Date(timeIntervalSince1970: 1_000),
            staleLogInterval: 300
        )

        let conductor = try #require(snapshot.session(id: "conductor"))
        #expect(conductor.riskFlags.contains(.missingLog))
        #expect(conductor.riskFlags.contains(.sharedWorktree))
        #expect(conductor.riskFlags.contains(.unverifiedPromptReceipt))
        #expect(conductor.riskFlags.contains(.staleChild))

        let orchestrator = try #require(snapshot.session(id: "orchestrator"))
        #expect(orchestrator.riskFlags.contains(.staleLog))
        #expect(orchestrator.riskFlags.contains(.sharedWorktree))
        #expect(orchestrator.riskFlags.contains(.staleChild))

        let subagent = try #require(snapshot.session(id: "subagent"))
        #expect(subagent.riskFlags.contains(.unvalidatedFinalReport))
        #expect(!subagent.riskFlags.contains(.missingLog))
    }

    @Test("builds attribution labels for later usage joins")
    func attributionLabels() throws {
        let fixture = """
        {
          "sessions": [
            {
              "id": "conductor",
              "role": "conductor",
              "title": "Roadmap",
              "status": "running",
              "proof_status": "tool_active",
              "cwd": "/repo",
              "branch": "main",
              "tmux_session": "muxy-conductor",
              "codex_log": "/logs/conductor.jsonl"
            },
            {
              "id": "track-11",
              "parent_id": "conductor",
              "role": "orchestrator",
              "title": "Track 11",
              "status": "ready",
              "proof_status": "prompt_delivered",
              "cwd": "/repo-track-11",
              "branch": "feature/track-11",
              "tmux_session": "muxy-track-11",
              "codex_log": "/logs/track-11.jsonl",
              "attribution": {
                "confidence": "confirmed",
                "request_session_ids": ["cliproxy-session-1"],
                "conversation_ids": ["codex-conversation-1"],
                "labels": ["agent-session-model"]
              }
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            now: Date(timeIntervalSince1970: 2_000),
            deriveFileRisks: false
        )

        let labels = try #require(snapshot.attributionLabels(forID: "track-11"))
        #expect(labels.displayLabel == "Track 11")
        #expect(labels.hierarchyLabel == "Roadmap / Track 11")
        #expect(labels.roleLabel == "Orchestrator")
        #expect(labels.worktreeLabel == "/repo-track-11")
        #expect(labels.branchLabel == "feature/track-11")
        #expect(labels.confidence == .confirmed)
        #expect(labels.joinKeys == [
            "agent:track-11",
            "branch:feature/track-11",
            "codex-log:/logs/track-11.jsonl",
            "conversation:codex-conversation-1",
            "cwd:/repo-track-11",
            "label:agent-session-model",
            "request-session:cliproxy-session-1",
            "role:orchestrator",
            "tmux:muxy-track-11",
        ])
    }
}
