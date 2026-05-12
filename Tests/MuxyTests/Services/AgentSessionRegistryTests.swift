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

    @Test("derives stale log risk only for live tmux-backed running sessions")
    func staleLogRequiresLiveTmuxSessionWhenTmuxReferenceExists() throws {
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
              "id": "alive",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "tool_active",
              "tmux_session": "alive-tmux",
              "cwd": "/repo/alive",
              "codex_log": "stale.jsonl"
            },
            {
              "id": "dead",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "tool_active",
              "tmux_session": "dead-tmux",
              "cwd": "/repo/dead",
              "codex_log": "stale.jsonl"
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            baseURL: tempDir,
            now: Date(timeIntervalSince1970: 1_000),
            staleLogInterval: 300,
            tmuxSessionChecker: { $0 == "alive-tmux" }
        )

        #expect(snapshot.session(id: "alive")?.riskFlags.contains(.staleLog) == true)
        #expect(snapshot.session(id: "dead")?.riskFlags.contains(.staleLog) == false)
    }

    @Test("future log timestamps from clock skew are not stale")
    func futureLogTimestampDoesNotLookStale() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureLog = tempDir.appendingPathComponent("future.jsonl")
        try "{}\n".write(to: futureLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000)],
            ofItemAtPath: futureLog.path
        )

        let fixture = """
        {
          "sessions": [
            {
              "id": "clock-skewed",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "tool_active",
              "tmux_session": "live-tmux",
              "cwd": "/repo/skewed",
              "codex_log": "future.jsonl"
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            baseURL: tempDir,
            now: Date(timeIntervalSince1970: 1_000),
            staleLogInterval: 300,
            tmuxSessionChecker: { $0 == "live-tmux" }
        )

        let session = try #require(snapshot.session(id: "clock-skewed"))
        #expect(!session.riskFlags.contains(.staleLog))
        #expect(!session.riskFlags.contains(.missingLog))
    }

    @Test("malformed registry data fails closed")
    func malformedRegistryDataFailsClosed() {
        let malformed = Data("""
        {
          "sessions": [
            {
              "id": "broken",
              "updated_at": "not a date"
            }
          ]
        }
        """.utf8)

        #expect(throws: (any Error).self) {
            _ = try AgentSessionRegistryParser.parseFixture(data: malformed)
        }
    }

    @Test("derives prompt and tool proof from Codex log marker")
    func derivesProofFromCodexLogMarker() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let log = tempDir.appendingPathComponent("codex.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"TRACK-12-MARKER"}]}}
        {"type":"response_item","payload":{"type":"function_call","name":"exec_command"}}
        """.write(to: log, atomically: true, encoding: .utf8)

        let fixture = """
        {
          "sessions": [
            {
              "id": "track-12",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "unverified",
              "codex_log": "codex.jsonl",
              "last_prompt_marker": "TRACK-12-MARKER"
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            baseURL: tempDir,
            now: Date(timeIntervalSince1970: 2_000)
        )

        let session = try #require(snapshot.session(id: "track-12"))
        #expect(session.proofStatus == .toolActive)
        #expect(!session.riskFlags.contains(.unverifiedPromptReceipt))
    }

    @Test("does not treat plain assistant text as tool proof")
    func plainTextAfterPromptMarkerIsNotToolProof() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let log = tempDir.appendingPathComponent("codex.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"TRACK-12-MARKER"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"I might use exec_command or apply_patch later."}]}}
        """.write(to: log, atomically: true, encoding: .utf8)

        let fixture = """
        {
          "sessions": [
            {
              "id": "track-12",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "unverified",
              "codex_log": "codex.jsonl",
              "last_prompt_marker": "TRACK-12-MARKER"
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            baseURL: tempDir
        )

        let session = try #require(snapshot.session(id: "track-12"))
        #expect(session.proofStatus == .promptDelivered)
        #expect(!session.riskFlags.contains(.unverifiedPromptReceipt))
    }

    @Test("attribution-only loads do not derive file-backed proof")
    func deriveFileRisksFalseSkipsFileBackedProof() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"TRACK-12-MARKER"}]}}
        {"type":"response_item","payload":{"type":"function_call","name":"exec_command"}}
        """.write(to: tempDir.appendingPathComponent("codex.jsonl"), atomically: true, encoding: .utf8)
        try "done".write(to: tempDir.appendingPathComponent("FINAL_REPORT.md"), atomically: true, encoding: .utf8)

        let fixture = """
        {
          "sessions": [
            {
              "id": "track-12",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "unverified",
              "codex_log": "codex.jsonl",
              "final_report": "FINAL_REPORT.md",
              "last_prompt_marker": "TRACK-12-MARKER"
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            baseURL: tempDir,
            deriveFileRisks: false
        )

        let session = try #require(snapshot.session(id: "track-12"))
        #expect(session.proofStatus == .unverified)
        #expect(session.riskFlags.contains(.unverifiedPromptReceipt))
        #expect(session.riskFlags.contains(.unvalidatedFinalReport))
        #expect(!session.riskFlags.contains(.missingLog))
    }

    @Test("cached registry loads share synchronous file and process probes")
    func cachedLoadsShareRegistrySnapshot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try "{}\n".write(to: tempDir.appendingPathComponent("active.jsonl"), atomically: true, encoding: .utf8)

        let registryURL = tempDir.appendingPathComponent("agent-sessions.json")
        try """
        {
          "sessions": [
            {
              "id": "track-12",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "tool_active",
              "worktree_path": "dirty-repo",
              "codex_log": "active.jsonl"
            }
          ]
        }
        """.write(to: registryURL, atomically: true, encoding: .utf8)

        var dirtyCheckCount = 0
        let registry = AgentSessionRegistry(
            fileURL: registryURL,
            dirtyWorktreeChecker: { _ in
                dirtyCheckCount += 1
                return true
            },
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let first = try registry.loadCachedSnapshot(maxAge: 10)
        let second = try registry.loadCachedSnapshot(maxAge: 10)

        #expect(first.session(id: "track-12")?.riskFlags.contains(.dirtyWorktree) == true)
        #expect(second.session(id: "track-12")?.riskFlags.contains(.dirtyWorktree) == true)
        #expect(dirtyCheckCount == 1)
    }

    @Test("derives dirty worktree risk from checker")
    func dirtyWorktreeRisk() throws {
        let fixture = """
        {
          "sessions": [
            {
              "id": "dirty",
              "role": "conductor",
              "status": "running",
              "proof_status": "tool_active",
              "worktree_path": "dirty-repo",
              "codex_log": "active.jsonl"
            },
            {
              "id": "clean",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "tool_active",
              "worktree_path": "clean-repo",
              "codex_log": "active.jsonl"
            }
          ]
        }
        """
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try "{}\n".write(to: tempDir.appendingPathComponent("active.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            baseURL: tempDir,
            now: Date(timeIntervalSince1970: 2_000),
            dirtyWorktreeChecker: { $0.hasSuffix("dirty-repo") }
        )

        let dirty = try #require(snapshot.session(id: "dirty"))
        #expect(dirty.riskFlags.contains(.dirtyWorktree))

        let clean = try #require(snapshot.session(id: "clean"))
        #expect(!clean.riskFlags.contains(.dirtyWorktree))
    }

    @Test("derives shared worktree risk for nested cwd paths in the same worktree")
    func nestedSharedWorktreeRisk() throws {
        let fixture = """
        {
          "sessions": [
            {
              "id": "orchestrator",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "tool_active",
              "worktree_path": "/repo/worktree",
              "codex_log": "/tmp/active.jsonl"
            },
            {
              "id": "worker",
              "parent_id": "orchestrator",
              "role": "worker",
              "status": "running",
              "proof_status": "tool_active",
              "cwd": "/repo/worktree/Sources/Feature",
              "codex_log": "/tmp/active.jsonl"
            },
            {
              "id": "sibling",
              "role": "orchestrator",
              "status": "running",
              "proof_status": "tool_active",
              "worktree_path": "/repo/worktree-sibling",
              "codex_log": "/tmp/active.jsonl"
            }
          ]
        }
        """

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            now: Date(timeIntervalSince1970: 2_000),
            deriveFileRisks: false
        )

        #expect(snapshot.session(id: "orchestrator")?.riskFlags.contains(.sharedWorktree) == true)
        #expect(snapshot.session(id: "worker")?.riskFlags.contains(.sharedWorktree) == true)
        #expect(snapshot.session(id: "sibling")?.riskFlags.contains(.sharedWorktree) == false)
    }

    @Test("loads more than one hundred registry sessions with deduplicated process probes")
    func largeRegistryLoadStaysFast() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try "{}\n".write(to: tempDir.appendingPathComponent("active.jsonl"), atomically: true, encoding: .utf8)

        var records = [
            """
            {
              "id": "conductor",
              "role": "conductor",
              "title": "Large conductor",
              "status": "running",
              "proof_status": "tool_active",
              "worktree_path": "large-worktree",
              "codex_log": "active.jsonl"
            }
            """,
        ]
        for orchestratorIndex in 0 ..< 10 {
            records.append("""
            {
              "id": "orchestrator-\(orchestratorIndex)",
              "parent_id": "conductor",
              "role": "orchestrator",
              "title": "Orchestrator \(orchestratorIndex)",
              "status": "running",
              "proof_status": "prompt_delivered",
              "worktree_path": "large-worktree",
              "codex_log": "active.jsonl"
            }
            """)
            for workerIndex in 0 ..< 12 {
                records.append("""
                {
                  "id": "worker-\(orchestratorIndex)-\(workerIndex)",
                  "parent_id": "orchestrator-\(orchestratorIndex)",
                  "role": "worker",
                  "title": "Worker \(orchestratorIndex)-\(workerIndex)",
                  "status": "complete",
                  "proof_status": "validated",
                  "worktree_path": "large-worktree",
                  "codex_log": "active.jsonl"
                }
                """)
            }
        }
        let fixture = Data("{\"sessions\":[\(records.joined(separator: ","))]}".utf8)
        var dirtyProbeCount = 0
        var tmuxProbeCount = 0
        let startedAt = Date()

        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: fixture,
            baseURL: tempDir,
            now: Date(timeIntervalSince1970: 2_000),
            dirtyWorktreeChecker: { _ in
                dirtyProbeCount += 1
                return false
            },
            tmuxSessionChecker: { _ in
                tmuxProbeCount += 1
                return false
            }
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(snapshot.sessions.count == 131)
        #expect(snapshot.roots.map(\.id) == ["conductor"])
        #expect(snapshot.roots.first?.children.count == 10)
        #expect(snapshot.roots.first?.flattened.count == 131)
        #expect(dirtyProbeCount == 1)
        #expect(tmuxProbeCount == 0)
        #expect(elapsed < 2)
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
