import CryptoKit
import Foundation

public struct RepositorySnapshot: Codable, Sendable, Hashable {
    public var state: RepositoryState
    public var inspectedDirectory: String
    public var repositoryRoot: String?
    public var headCommit: String?
    public var inspectedAt: Date

    public init(state: RepositoryState, inspectedDirectory: String, repositoryRoot: String? = nil, headCommit: String? = nil, inspectedAt: Date = .now) {
        self.state = state
        self.inspectedDirectory = inspectedDirectory
        self.repositoryRoot = repositoryRoot
        self.headCommit = headCommit
        self.inspectedAt = inspectedAt
    }
}

public struct EditableRepositoryContext: Codable, Sendable, Hashable {
    public var originalDirectory: String
    public var repositoryRoot: String
    public var sourceCommit: String
    public var capturedAt: Date

    public init(originalDirectory: String, repositoryRoot: String, sourceCommit: String, capturedAt: Date = .now) {
        self.originalDirectory = originalDirectory
        self.repositoryRoot = repositoryRoot
        self.sourceCommit = sourceCommit
        self.capturedAt = capturedAt
    }
}

public struct WorktreeChange: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path + "|" + status }
    /// The two-character Git porcelain status without its trailing delimiter.
    public var status: String
    public var path: String
    public var originalPath: String?

    public init(status: String, path: String, originalPath: String? = nil) {
        self.status = status
        self.path = path
        self.originalPath = originalPath
    }
}

public struct WorktreeChanges: Codable, Sendable, Hashable {
    public var files: [WorktreeChange]
    public var patch: Data

    public init(files: [WorktreeChange], patch: Data) {
        self.files = files
        self.patch = patch
    }
}

public enum RepositoryServiceError: Error, LocalizedError, Sendable, Equatable {
    case missingDirectory(String)
    case notGitRepository(String)
    case repositoryIsDirty(String)
    case noHeadCommit(String)
    case repositoryChanged(expected: String, actual: String?)
    case unsafePath(String)
    case worktreeNotRegistered(UUID)
    case worktreeNotPending(UUID)
    case destinationExists(String)
    case destinationParentMissing(String)
    case cleanupUnverified(String)
    case attemptStillActive(UUID)

    public var errorDescription: String? {
        switch self {
        case .missingDirectory(let path): "Directory does not exist: \(path)"
        case .notGitRepository(let path): "Editable runs require a Git repository: \(path)"
        case .repositoryIsDirty(let path): "Editable runs require a clean Git repository: \(path)"
        case .noHeadCommit(let path): "Editable runs require a committed HEAD: \(path)"
        case .repositoryChanged(let expected, let actual): "Repository changed after this run started. Expected \(expected); found \(actual ?? "no HEAD")."
        case .unsafePath(let path): "Refusing unsafe worktree path: \(path)"
        case .worktreeNotRegistered(let id): "Worktree \(id) is not registered to this JBench session."
        case .worktreeNotPending(let id): "Worktree \(id) is no longer available for this action."
        case .destinationExists(let path): "Destination already exists: \(path)"
        case .destinationParentMissing(let path): "Destination parent does not exist: \(path)"
        case .cleanupUnverified(let path): "Git reported removal but the owned worktree still exists: \(path)"
        case .attemptStillActive(let id): "Attempt \(id) is not terminal or its owned process is still running."
        }
    }
}

/// Git inspection and worktree lifecycle support. Each operation passes fixed Git arguments directly, never via a shell.
public actor RepositoryService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func inspect(directory: URL) throws -> RepositorySnapshot {
        let directory = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return RepositorySnapshot(state: .missing, inspectedDirectory: directory.path)
        }

        guard let root = try? gitOutput(["-C", directory.path, "rev-parse", "--show-toplevel"]) else {
            return RepositorySnapshot(state: .nonGit, inspectedDirectory: directory.path)
        }
        let rootURL = URL(filePath: root).standardizedFileURL
        guard let head = try? gitOutput(["-C", rootURL.path, "rev-parse", "--verify", "HEAD"]) else {
            return RepositorySnapshot(state: .dirtyGit, inspectedDirectory: directory.path, repositoryRoot: rootURL.path)
        }
        let status = try gitResult(["-C", rootURL.path, "status", "--porcelain=v1", "-z"])
        return RepositorySnapshot(
            state: status.standardOutput.isEmpty ? .cleanGit : .dirtyGit,
            inspectedDirectory: directory.path,
            repositoryRoot: rootURL.path,
            headCommit: head
        )
    }

    /// Captures the immutable commit used for all editable attempts in a run.
    public func prepareEditableRun(directory: URL) throws -> EditableRepositoryContext {
        let snapshot = try inspect(directory: directory)
        guard snapshot.state != .missing else { throw RepositoryServiceError.missingDirectory(snapshot.inspectedDirectory) }
        guard snapshot.state != .nonGit else { throw RepositoryServiceError.notGitRepository(snapshot.inspectedDirectory) }
        guard snapshot.state == .cleanGit else { throw RepositoryServiceError.repositoryIsDirty(snapshot.repositoryRoot ?? snapshot.inspectedDirectory) }
        guard let root = snapshot.repositoryRoot, let head = snapshot.headCommit else { throw RepositoryServiceError.noHeadCommit(snapshot.inspectedDirectory) }
        return EditableRepositoryContext(originalDirectory: snapshot.inspectedDirectory, repositoryRoot: root, sourceCommit: head)
    }

    /// Blocks reruns when the selected source no longer resolves to the same clean Git commit.
    public func revalidateEditableRun(_ context: EditableRepositoryContext) throws {
        let snapshot = try inspect(directory: URL(filePath: context.originalDirectory))
        guard snapshot.state == .cleanGit else {
            throw RepositoryServiceError.repositoryIsDirty(snapshot.repositoryRoot ?? context.originalDirectory)
        }
        guard snapshot.repositoryRoot == URL(filePath: context.repositoryRoot).standardizedFileURL.path else {
            throw RepositoryServiceError.notGitRepository(context.originalDirectory)
        }
        guard snapshot.headCommit == context.sourceCommit else {
            throw RepositoryServiceError.repositoryChanged(expected: context.sourceCommit, actual: snapshot.headCommit)
        }
    }

    public func worktreeChanges(at worktree: URL) throws -> WorktreeChanges {
        let worktree = worktree.standardizedFileURL
        let status = try gitResult(["-C", worktree.path, "status", "--porcelain=v1", "-z"])
        let files = parsePorcelain(status.standardOutput)
        var patch = try gitResult(["-C", worktree.path, "diff", "--binary", "HEAD"]).standardOutput
        let untracked = files.filter { $0.status == "??" }
        for file in untracked {
            let path = worktree.appending(path: file.path).standardizedFileURL
            guard path.path.hasPrefix(worktree.path + "/"), fileManager.fileExists(atPath: path.path) else { continue }
            let addition = try gitResult(
                ["diff", "--binary", "--no-index", "/dev/null", path.path],
                acceptedExitStatuses: [0, 1]
            ).standardOutput
            patch.append(addition)
        }
        return WorktreeChanges(files: files, patch: patch)
    }

    private func gitResult(_ arguments: [String], acceptedExitStatuses: Set<Int32> = [0]) throws -> CommandResult {
        try SystemCommand.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: arguments,
            acceptedExitStatuses: acceptedExitStatuses
        )
    }

    private func gitOutput(_ arguments: [String]) throws -> String {
        try gitResult(arguments).outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parsePorcelain(_ data: Data) -> [WorktreeChange] {
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        var changes: [WorktreeChange] = []
        while index < fields.count {
            let field = fields[index]
            guard field.count >= 4 else { index += 1; continue }
            let prefix = String(field.prefix(3))
            let status = String(prefix.prefix(2))
            let path = String(field.dropFirst(3))
            let renamedOrCopied = status.contains("R") || status.contains("C")
            let originalPath = renamedOrCopied && index + 1 < fields.count ? fields[index + 1] : nil
            changes.append(WorktreeChange(status: status, path: path, originalPath: originalPath))
            index += renamedOrCopied ? 2 : 1
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Creates and disposes the only worktrees JBench is permitted to mutate.
public actor EditableWorktreeService {
    private let repository: RepositoryService
    private let ownedRoot: URL
    private let fileManager: FileManager
    private var records: [UUID: WorktreeRecord] = [:]
    private var resolutionAuthorizations: Set<UUID> = []

    public init(repository: RepositoryService, ownedRoot: URL, fileManager: FileManager = .default) throws {
        self.repository = repository
        self.ownedRoot = ownedRoot.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.ownedRoot, withIntermediateDirectories: true)
    }

    public func createWorktree(for attemptID: UUID, context: EditableRepositoryContext) async throws -> WorktreeRecord {
        try await repository.revalidateEditableRun(context)
        let destination = ownedRoot.appending(path: "attempt-\(attemptID.uuidString)", directoryHint: .isDirectory).standardizedFileURL
        try validateOwnedPath(destination)
        guard !fileManager.fileExists(atPath: destination.path) else { throw RepositoryServiceError.destinationExists(destination.path) }
        _ = try SystemCommand.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", context.repositoryRoot, "worktree", "add", "--detach", destination.path, context.sourceCommit]
        )
        guard fileManager.fileExists(atPath: destination.path) else { throw RepositoryServiceError.cleanupUnverified(destination.path) }
        let record = WorktreeRecord(
            attemptID: attemptID,
            originalRepositoryPath: context.repositoryRoot,
            sourceCommit: context.sourceCommit,
            ownedWorktreePath: destination.path
        )
        records[record.id] = record
        return record
    }

    public func record(_ id: UUID) -> WorktreeRecord? { records[id] }

    /// Re-registers a persisted worktree after app relaunch. This intentionally
    /// accepts only pending records that Git still associates with this original
    /// repository and recorded source commit; transferred worktrees are never
    /// adopted back into JBench ownership.
    @discardableResult
    public func restore(_ record: WorktreeRecord) async throws -> WorktreeRecord {
        guard record.disposition == .pending else { throw RepositoryServiceError.worktreeNotPending(record.id) }
        let worktreeURL = URL(filePath: record.ownedWorktreePath).standardizedFileURL
        try validateOwnedPath(worktreeURL)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: worktreeURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RepositoryServiceError.missingDirectory(worktreeURL.path)
        }

        let sourceRepository = URL(filePath: record.originalRepositoryPath).standardizedFileURL
        let snapshot = try await repository.inspect(directory: sourceRepository)
        guard snapshot.repositoryRoot == sourceRepository.path else {
            throw RepositoryServiceError.notGitRepository(sourceRepository.path)
        }
        try ensureGitRegisters(record, expectedCommit: record.sourceCommit)

        if let existing = records[record.id], existing != record {
            throw RepositoryServiceError.worktreeNotRegistered(record.id)
        }
        records[record.id] = record
        return record
    }

    public func collectChanges(for id: UUID) async throws -> WorktreeChanges {
        guard var record = records[id] else { throw RepositoryServiceError.worktreeNotRegistered(id) }
        guard record.disposition == .pending else { throw RepositoryServiceError.worktreeNotPending(id) }
        try validateOwnedPath(URL(filePath: record.ownedWorktreePath))
        try ensureGitRegisters(record, expectedCommit: record.sourceCommit)
        let changes = try await repository.worktreeChanges(at: URL(filePath: record.ownedWorktreePath))
        record.changedFileCount = changes.files.count
        records[id] = record
        return changes
    }

    /// Authorizes Keep or Discard only after the matching attempt is terminal and
    /// every recorded owned PID has exited (or has been safely rejected as reused).
    public func authorizeResolution(_ id: UUID, after attempt: AgentAttempt) throws {
        guard let record = records[id], record.attemptID == attempt.id, attempt.state.isTerminal else {
            throw RepositoryServiceError.attemptStillActive(attempt.id)
        }
        let owned = attempt.ownership
        if Self.identityStillMatches(pid: owned.processID, serialized: owned.processIdentity)
            || Self.identityStillMatches(pid: owned.serverProcessID, serialized: owned.serverIdentity) {
            throw RepositoryServiceError.attemptStillActive(attempt.id)
        }
        resolutionAuthorizations.insert(id)
    }

    /// Writes an exact binary Git patch. It refuses to overwrite a user file.
    public func exportPatch(for id: UUID, to destination: URL) async throws -> URL {
        guard var record = records[id] else { throw RepositoryServiceError.worktreeNotRegistered(id) }
        guard record.disposition == .pending else { throw RepositoryServiceError.worktreeNotPending(id) }
        let destination = try validateUserDestination(destination)
        let changes = try await collectChanges(for: id)
        try changes.patch.write(to: destination, options: [.withoutOverwriting])
        record.patchReference = destination.path
        record.changedFileCount = changes.files.count
        records[id] = record
        return destination
    }

    /// Transfers the registered worktree with Git's move operation; it never copies or overwrites a target.
    public func keep(_ id: UUID, at destination: URL) async throws -> WorktreeRecord {
        guard var record = records[id] else { throw RepositoryServiceError.worktreeNotRegistered(id) }
        guard record.disposition == .pending else { throw RepositoryServiceError.worktreeNotPending(id) }
        guard resolutionAuthorizations.contains(id) else { throw RepositoryServiceError.attemptStillActive(record.attemptID) }
        let source = URL(filePath: record.ownedWorktreePath).standardizedFileURL
        try validateOwnedPath(source)
        try ensureGitRegisters(record, expectedCommit: record.sourceCommit)
        let destination = try validateUserDestination(destination)
        _ = try SystemCommand.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", record.originalRepositoryPath, "worktree", "move", source.path, destination.path]
        )
        guard fileManager.fileExists(atPath: destination.path), !fileManager.fileExists(atPath: source.path) else {
            throw RepositoryServiceError.cleanupUnverified(destination.path)
        }
        record.disposition = .transferred
        record.transferredPath = destination.path
        record.cleanupVerified = true
        records[id] = record
        resolutionAuthorizations.remove(id)
        return record
    }

    /// Discards only a still-pending worktree underneath the JBench-owned root.
    public func discard(_ id: UUID) throws -> WorktreeRecord {
        guard let record = records[id] else { throw RepositoryServiceError.worktreeNotRegistered(id) }
        guard record.disposition == .pending else { throw RepositoryServiceError.worktreeNotPending(id) }
        guard resolutionAuthorizations.contains(id) else { throw RepositoryServiceError.attemptStillActive(record.attemptID) }
        return try discardRegistered(record)
    }

    /// Removes a worktree allocated during atomic preparation before its harness
    /// process was ever started. Runtime callers must use `authorizeResolution`.
    public func discardUnstarted(_ id: UUID) throws -> WorktreeRecord {
        guard let record = records[id] else { throw RepositoryServiceError.worktreeNotRegistered(id) }
        guard record.disposition == .pending else { throw RepositoryServiceError.worktreeNotPending(id) }
        return try discardRegistered(record)
    }

    private func discardRegistered(_ existing: WorktreeRecord) throws -> WorktreeRecord {
        var record = existing
        let id = record.id
        let source = URL(filePath: record.ownedWorktreePath).standardizedFileURL
        try validateOwnedPath(source)
        try ensureGitRegisters(record, expectedCommit: record.sourceCommit)
        _ = try SystemCommand.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", record.originalRepositoryPath, "worktree", "remove", "--force", source.path]
        )
        guard !fileManager.fileExists(atPath: source.path) else { throw RepositoryServiceError.cleanupUnverified(source.path) }
        record.disposition = .discarded
        record.cleanupVerified = true
        records[id] = record
        resolutionAuthorizations.remove(id)
        return record
    }

    private nonisolated static func identityStillMatches(pid: Int32?, serialized: String) -> Bool {
        guard let pid, pid > 0, let current = OwnedProcessService.identity(for: pid) else { return false }
        return serialized.isEmpty || current.serialized == serialized
    }

    private func validateOwnedPath(_ path: URL) throws {
        let path = path.standardizedFileURL
        guard path.path.hasPrefix(ownedRoot.path + "/"), path.path != ownedRoot.path else {
            throw RepositoryServiceError.unsafePath(path.path)
        }
    }

    private func validateUserDestination(_ destination: URL) throws -> URL {
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else { throw RepositoryServiceError.destinationParentMissing(parent.path) }
        guard !fileManager.fileExists(atPath: destination.path) else { throw RepositoryServiceError.destinationExists(destination.path) }
        guard destination.path != "/", !destination.path.isEmpty else { throw RepositoryServiceError.unsafePath(destination.path) }
        return destination
    }

    private func ensureGitRegisters(_ record: WorktreeRecord, expectedCommit: String) throws {
        let expected = URL(filePath: record.ownedWorktreePath).resolvingSymlinksInPath().standardizedFileURL.path
        let lines = try SystemCommand.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", record.originalRepositoryPath, "worktree", "list", "--porcelain"]
        ).outputText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var currentPath: String?
        var currentHead: String?
        for line in lines + [""] {
            if line.isEmpty {
                defer { currentPath = nil; currentHead = nil }
                guard let currentPath else { continue }
                let resolved = URL(filePath: currentPath).resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == expected else { continue }
                guard currentHead == expectedCommit else {
                    throw RepositoryServiceError.repositoryChanged(expected: expectedCommit, actual: currentHead)
                }
                return
            }
            if line.hasPrefix("worktree ") { currentPath = String(line.dropFirst("worktree ".count)) }
            if line.hasPrefix("HEAD ") { currentHead = String(line.dropFirst("HEAD ".count)) }
        }
        throw RepositoryServiceError.worktreeNotRegistered(record.id)
    }
}

public struct FilesystemFingerprint: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable { case file, directory, symbolicLink }
    public var id: String { relativePath }
    public var relativePath: String
    public var kind: Kind
    public var digest: String?
    public var linkTarget: String?
    public var posixPermissions: Int?

    public init(relativePath: String, kind: Kind, digest: String? = nil, linkTarget: String? = nil, posixPermissions: Int? = nil) {
        self.relativePath = relativePath
        self.kind = kind
        self.digest = digest
        self.linkTarget = linkTarget
        self.posixPermissions = posixPermissions
    }
}

public struct FilesystemSentinelSnapshot: Codable, Sendable, Hashable {
    public var rootPath: String
    public var capturedAt: Date
    public var entries: [FilesystemFingerprint]

    public init(rootPath: String, capturedAt: Date = .now, entries: [FilesystemFingerprint]) {
        self.rootPath = rootPath
        self.capturedAt = capturedAt
        self.entries = entries
    }
}

public struct FilesystemSentinelVerification: Codable, Sendable, Hashable {
    public var isUnchanged: Bool { added.isEmpty && removed.isEmpty && modified.isEmpty }
    public var added: [String]
    public var removed: [String]
    public var modified: [String]

    public init(added: [String], removed: [String], modified: [String]) {
        self.added = added
        self.removed = removed
        self.modified = modified
    }
}

/// OpenCode has no native read-only attestation. This sentinel gives a before/after proof of filesystem content and tree shape.
public enum OpenCodeReadOnlySentinel {
    public static func capture(directory: URL, fileManager: FileManager = .default) throws -> FilesystemSentinelSnapshot {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RepositoryServiceError.missingDirectory(root.path)
        }
        var entries: [FilesystemFingerprint] = []
        let options: FileManager.DirectoryEnumerationOptions = []
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: options) else {
            throw RepositoryServiceError.missingDirectory(root.path)
        }
        for case let url as URL in enumerator {
            guard let relative = relativePath(of: url, under: root), !relative.isEmpty else {
                throw RepositoryServiceError.unsafePath(url.path)
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let permissions = (try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            if values.isSymbolicLink == true {
                entries.append(FilesystemFingerprint(relativePath: relative, kind: .symbolicLink, linkTarget: try fileManager.destinationOfSymbolicLink(atPath: url.path), posixPermissions: permissions))
            } else if values.isDirectory == true {
                entries.append(FilesystemFingerprint(relativePath: relative, kind: .directory, posixPermissions: permissions))
            } else {
                entries.append(FilesystemFingerprint(relativePath: relative, kind: .file, digest: try digest(url), posixPermissions: permissions))
            }
        }
        return FilesystemSentinelSnapshot(rootPath: root.path, entries: entries.sorted { $0.relativePath < $1.relativePath })
    }

    public static func verify(_ snapshot: FilesystemSentinelSnapshot, fileManager: FileManager = .default) throws -> FilesystemSentinelVerification {
        let current = try capture(directory: URL(filePath: snapshot.rootPath), fileManager: fileManager)
        let before = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.relativePath, $0) })
        let after = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.relativePath, $0) })
        let added = after.keys.filter { before[$0] == nil }.sorted()
        let removed = before.keys.filter { after[$0] == nil }.sorted()
        let modified: [String] = before.keys.compactMap { key -> String? in
            guard let current = after[key], current != before[key] else { return nil }
            return key
        }.sorted()
        return FilesystemSentinelVerification(added: added, removed: removed, modified: modified)
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Handles macOS's `/var` and `/private/var` aliases without relying on a string prefix.
    private static func relativePath(of url: URL, under root: URL) -> String? {
        let rootComponents = root.pathComponents.filter { $0 != "/" }
        let itemComponents = url.pathComponents.filter { $0 != "/" }
        guard !rootComponents.isEmpty, itemComponents.count > rootComponents.count else { return nil }
        for index in 0...(itemComponents.count - rootComponents.count) {
            let candidate = Array(itemComponents[index..<(index + rootComponents.count)])
            if candidate == rootComponents {
                return itemComponents.dropFirst(index + rootComponents.count).joined(separator: "/")
            }
        }
        return nil
    }
}
