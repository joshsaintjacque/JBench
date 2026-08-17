import Foundation
import Testing
@testable import JBenchCore

struct RepositoryServiceTests {
    @Test func inspectionDistinguishesNonGitCleanAndDirtyDirectories() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let service = RepositoryService()

        let nonGit = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nonGit, withIntermediateDirectories: true)
        #expect(try await service.inspect(directory: nonGit).state == .nonGit)

        let clean = try await service.inspect(directory: fixture.repository)
        #expect(clean.state == .cleanGit)
        #expect(clean.headCommit != nil)

        try Data("changed".utf8).write(to: fixture.repository.appending(path: "file.txt"))
        #expect(try await service.inspect(directory: fixture.repository).state == .dirtyGit)
    }

    @Test func editableContextRejectsChangedSourceAndCreatesIsolatedWorktree() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = RepositoryService()
        let context = try await repository.prepareEditableRun(directory: fixture.repository)
        let service = try EditableWorktreeService(repository: repository, ownedRoot: fixture.root.appending(path: "owned", directoryHint: .isDirectory))
        let attemptID = UUID()
        let record = try await service.createWorktree(for: attemptID, context: context)
        let worktree = URL(filePath: record.ownedWorktreePath)
        #expect(worktree.path != fixture.repository.path)
        try Data("new file".utf8).write(to: worktree.appending(path: "new.txt"))

        let changes = try await service.collectChanges(for: record.id)
        #expect(changes.files.contains(where: { $0.status == "??" && $0.path == "new.txt" }))
        #expect(String(decoding: changes.patch, as: UTF8.self).contains("new.txt"))

        let patch = fixture.root.appending(path: "attempt.patch")
        #expect(try await service.exportPatch(for: record.id, to: patch) == patch)
        #expect(FileManager.default.fileExists(atPath: patch.path))

        try await service.authorizeResolution(record.id, after: terminalAttempt(for: record))
        let discarded = try await service.discard(record.id)
        #expect(discarded.disposition == .discarded)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))

        try Data("next".utf8).write(to: fixture.repository.appending(path: "next.txt"))
        try fixture.git(["add", "next.txt"])
        try fixture.git(["commit", "-m", "advance source"])
        await #expect(throws: RepositoryServiceError.self) { try await repository.revalidateEditableRun(context) }
    }

    @Test func sentinelReportsAddedRemovedAndModifiedFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let retained = directory.url.appending(path: "retained.txt")
        let removed = directory.url.appending(path: "removed.txt")
        try Data("before".utf8).write(to: retained)
        try Data("removed".utf8).write(to: removed)
        let snapshot = try OpenCodeReadOnlySentinel.capture(directory: directory.url)
        try Data("after".utf8).write(to: retained)
        try FileManager.default.removeItem(at: removed)
        try Data("added".utf8).write(to: directory.url.appending(path: "added.txt"))

        let verification = try OpenCodeReadOnlySentinel.verify(snapshot)
        #expect(!verification.isUnchanged)
        #expect(verification.added == ["added.txt"])
        #expect(verification.removed == ["removed.txt"])
        #expect(verification.modified == ["retained.txt"])
    }

    @Test func keepMovesOnlyTheRegisteredOwnedWorktreeToAnEmptyDestination() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = RepositoryService()
        let context = try await repository.prepareEditableRun(directory: fixture.repository)
        let service = try EditableWorktreeService(repository: repository, ownedRoot: fixture.root.appending(path: "owned", directoryHint: .isDirectory))
        let record = try await service.createWorktree(for: UUID(), context: context)
        let source = URL(filePath: record.ownedWorktreePath)
        let destination = fixture.root.appending(path: "kept-worktree", directoryHint: .isDirectory)

        try await service.authorizeResolution(record.id, after: terminalAttempt(for: record))
        let kept = try await service.keep(record.id, at: destination)
        #expect(kept.disposition == .transferred)
        #expect(kept.transferredPath == destination.path)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        await #expect(throws: RepositoryServiceError.self) { try await service.discard(record.id) }
    }

    @Test func pendingWorktreeRestoresAfterRelaunchAndCanExportThenDiscard() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = RepositoryService()
        let context = try await repository.prepareEditableRun(directory: fixture.repository)
        let ownedRoot = fixture.root.appending(path: "owned", directoryHint: .isDirectory)
        let firstLaunch = try EditableWorktreeService(repository: repository, ownedRoot: ownedRoot)
        let record = try await firstLaunch.createWorktree(for: UUID(), context: context)
        let worktree = URL(filePath: record.ownedWorktreePath)
        try Data("relaunch change".utf8).write(to: worktree.appending(path: "relaunch.txt"))

        let relaunched = try EditableWorktreeService(repository: repository, ownedRoot: ownedRoot)
        #expect(try await relaunched.restore(record) == record)
        let patch = fixture.root.appending(path: "relaunch.patch")
        #expect(try await relaunched.exportPatch(for: record.id, to: patch) == patch)
        #expect(FileManager.default.fileExists(atPath: patch.path))
        try await relaunched.authorizeResolution(record.id, after: terminalAttempt(for: record))
        #expect(try await relaunched.discard(record.id).disposition == .discarded)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))

        var transferred = record
        transferred.disposition = .transferred
        let otherLaunch = try EditableWorktreeService(repository: repository, ownedRoot: ownedRoot)
        await #expect(throws: RepositoryServiceError.self) { try await otherLaunch.restore(transferred) }
    }

    @Test func ownedProcessIsTerminatedOnlyAfterIdentityCheck() async throws {
        let service = OwnedProcessService()
        let record = try await service.launch(executable: URL(filePath: "/bin/sleep"), arguments: ["30"], label: "repository-test")
        let result = await service.terminate(record.id)
        #expect(result == .terminatedGracefully || result == .terminatedWithFallback)
        #expect(await service.records().isEmpty)
    }

    @Test func ownedProcessTerminationStopsItsDescendantProcessGroup() async throws {
        let service = OwnedProcessService()
        let record = try await service.launch(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 30 & wait"],
            label: "process-tree-test"
        )
        try await Task.sleep(for: .milliseconds(150))
        let listing = try SystemCommand.run(executable: URL(filePath: "/bin/ps"), arguments: ["-axo", "pid=,pgid="]).outputText
        let memberCount = listing.split(separator: "\n").filter { line in
            line.split(whereSeparator: \.isWhitespace).dropFirst().first == Substring(String(record.identity.processID))
        }.count
        #expect(memberCount >= 2)

        let result = await service.terminate(record.id)
        #expect(result == .terminatedGracefully || result == .terminatedWithFallback)
        #expect(!OwnedProcessLauncher.groupIsRunning(record.identity.processID))
    }
}

private func terminalAttempt(for record: WorktreeRecord) -> AgentAttempt {
    var attempt = AgentAttempt(id: record.attemptID, agentRunID: UUID(), number: 1, requested: .init(harness: .fake, model: "fixture"))
    attempt.state = .completed
    attempt.endedAt = .now
    return attempt
}

private final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "JBenchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class GitFixture: @unchecked Sendable {
    let root: URL
    let repository: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "JBenchGit-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = root.appending(path: "repository", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init"])
        try git(["config", "user.email", "jbench-tests@example.invalid"])
        try git(["config", "user.name", "JBench Tests"])
        try Data("initial".utf8).write(to: repository.appending(path: "file.txt"))
        try git(["add", "file.txt"])
        try git(["commit", "-m", "initial"])
    }

    func git(_ arguments: [String]) throws {
        _ = try SystemCommand.run(executable: URL(filePath: "/usr/bin/git"), arguments: ["-C", repository.path] + arguments)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
