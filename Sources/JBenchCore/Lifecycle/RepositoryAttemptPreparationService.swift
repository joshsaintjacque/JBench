import Foundation

/// Connects the coordinator's attempt lifecycle to Git-safe editable worktrees.
/// The recorded commit is rechecked immediately before every allocation, including retries.
public actor RepositoryAttemptPreparationService: AttemptPreparationService {
    private let repository: RepositoryService
    private let worktrees: EditableWorktreeService

    public init(repository: RepositoryService, worktrees: EditableWorktreeService) {
        self.repository = repository
        self.worktrees = worktrees
    }

    public func validate(draft: RunDraft) async throws {
        guard draft.executionMode == .editable else { return }
        let context = try await repository.prepareEditableRun(directory: URL(filePath: draft.directoryPath))
        guard context.sourceCommit == draft.sourceCommit else {
            throw RepositoryServiceError.repositoryChanged(expected: draft.sourceCommit ?? "no recorded source commit", actual: context.sourceCommit)
        }
    }

    public func prepare(_ request: AttemptPreparationRequest) async throws -> AttemptPreparation {
        guard request.executionMode == .editable else { return AttemptPreparation(directoryPath: request.originalDirectoryPath) }
        let current = try await repository.prepareEditableRun(directory: URL(filePath: request.originalDirectoryPath))
        guard let recordedCommit = request.sourceCommit else { throw RepositoryServiceError.noHeadCommit(request.originalDirectoryPath) }
        guard current.sourceCommit == recordedCommit else {
            throw RepositoryServiceError.repositoryChanged(expected: recordedCommit, actual: current.sourceCommit)
        }
        let context = EditableRepositoryContext(originalDirectory: current.originalDirectory, repositoryRoot: current.repositoryRoot, sourceCommit: recordedCommit)
        let record = try await worktrees.createWorktree(for: request.attemptID, context: context)
        return AttemptPreparation(directoryPath: record.ownedWorktreePath, lifecycle: .init(worktree: record))
    }

    public func abandon(_ preparation: AttemptPreparation) async -> String? {
        guard let record = preparation.lifecycle.worktree else { return nil }
        do {
            _ = try await worktrees.discardUnstarted(record.id)
            return nil
        } catch {
            return "Could not discard unstarted worktree \(record.ownedWorktreePath): \(error.localizedDescription)"
        }
    }
}
