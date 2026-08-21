import Foundation
import SQLite3

public struct HistoryDeletionPreview: Sendable, Hashable {
    public let runID: UUID
    public let title: String
    public let evidenceDirectory: String
    public let evidenceFiles: [String]
    public let worktrees: [WorktreeRecord]
    public let pendingWorktrees: [WorktreeRecord]
    public let transferredWorktrees: [WorktreeRecord]
    public let canDelete: Bool
    public let refusalReason: String?

    public init(runID: UUID, title: String, evidenceDirectory: String, evidenceFiles: [String], worktrees: [WorktreeRecord]) {
        self.runID = runID; self.title = title; self.evidenceDirectory = evidenceDirectory; self.evidenceFiles = evidenceFiles
        self.worktrees = worktrees
        self.pendingWorktrees = worktrees.filter { $0.disposition == .pending }
        self.transferredWorktrees = worktrees.filter { $0.disposition == .transferred }
        self.canDelete = self.pendingWorktrees.isEmpty
        self.refusalReason = self.pendingWorktrees.isEmpty ? nil : "Resolve every pending worktree with Keep or Discard before deleting this history record."
    }
}

public struct HistoryDeletionConfirmation: Sendable, Hashable {
    public let runIDs: Set<UUID>
    public let deleteEvidence: Bool
    public init(runIDs: Set<UUID>, deleteEvidence: Bool = false) { self.runIDs = runIDs; self.deleteEvidence = deleteEvidence }
}

public struct HistorySearch: Sendable, Hashable {
    public var text: String?
    public var directoryPath: String?
    public var harness: HarnessKind?
    public var model: String?
    public var verdictOnly: Bool?
    public var from: Date?
    public var to: Date?
    public init(text: String? = nil, directoryPath: String? = nil, harness: HarnessKind? = nil, model: String? = nil, verdictOnly: Bool? = nil, from: Date? = nil, to: Date? = nil) { self.text = text; self.directoryPath = directoryPath; self.harness = harness; self.model = model; self.verdictOnly = verdictOnly; self.from = from; self.to = to }
}

public actor SQLiteHistoryStore {
    private let database: OpaquePointer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            throw JBenchCoreError.storage("Could not open the local history database.")
        }
        sqlite3_busy_timeout(pointer, 5000)
        database = pointer
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            // Preserve the exact binary Date value. Decimal JSON numbers can
            // round during repeated persistence, which breaks stable equality.
            let bits = date.timeIntervalSinceReferenceDate.bitPattern
            try container.encode("jbench-date-v1:\(String(format: "%016llx", bits))")
        }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) { return Date(timeIntervalSince1970: timestamp) }
            let value = try container.decode(String.self)
            if value.hasPrefix("jbench-date-v1:"),
               let bits = UInt64(value.dropFirst("jbench-date-v1:".count), radix: 16) {
                return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
            }
            if let date = Self.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid persisted date: \(value)")
        }
        try Self.execute(database, "PRAGMA journal_mode = WAL")
        try Self.execute(database, "PRAGMA foreign_keys = ON")
        try Self.execute(database, "PRAGMA busy_timeout = 5000")
        try Self.migrate(database)
    }

    public func savePreset(_ preset: Preset) throws {
        let data = try encoder.encode(preset)
        try upsert(table: "presets", id: preset.id, blob: data, updatedAt: preset.updatedAt)
    }

    public func presets() throws -> [Preset] {
        try queryBlobs("SELECT body FROM presets ORDER BY updated_at DESC").map { try decoder.decode(Preset.self, from: $0) }
    }

    public func deletePreset(id: UUID) throws { try delete(table: "presets", id: id) }

    public func saveRun(_ run: BenchmarkRun) throws {
        try saveRun(run, worktrees: [])
    }

    /// Saves a run and any worktrees created while preparing its current attempts
    /// in one SQLite transaction.
    public func saveRun(_ run: BenchmarkRun, worktrees: [WorktreeRecord]) throws {
        let attemptIDs = Set(run.agents.flatMap(\.attempts).map(\.id))
        guard worktrees.allSatisfy({ attemptIDs.contains($0.attemptID) }) else {
            throw JBenchCoreError.storage("A worktree must belong to an attempt in the run being saved.")
        }
        guard Set(worktrees.map(\.id)).count == worktrees.count else {
            throw JBenchCoreError.storage("A run cannot save the same worktree record more than once.")
        }
        let runData = try encoder.encode(run)
        try Self.execute(database, "BEGIN IMMEDIATE")
        do {
            let statement = "INSERT INTO runs(id, title, prompt, directory_path, created_at, state, body) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title, prompt=excluded.prompt, directory_path=excluded.directory_path, created_at=excluded.created_at, state=excluded.state, body=excluded.body"
            try bindAndStep(statement, values: [.text(run.id.uuidString), .text(run.title), .text(run.prompt), .text(run.directoryPath), .double(run.createdAt.timeIntervalSince1970), .text(run.state.rawValue), .blob(runData)])
            var currentAttemptIDs: [String] = []
            for agent in run.agents {
                for attempt in agent.attempts {
                    let data = try encoder.encode(attempt)
                    currentAttemptIDs.append(attempt.id.uuidString)
                    try bindAndStep("INSERT INTO attempts(id, run_id, agent_run_id, number, state, harness, body) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET run_id=excluded.run_id, agent_run_id=excluded.agent_run_id, number=excluded.number, state=excluded.state, harness=excluded.harness, body=excluded.body", values: [.text(attempt.id.uuidString), .text(run.id.uuidString), .text(agent.id.uuidString), .integer(Int64(attempt.number)), .text(attempt.state.rawValue), .text(attempt.requested.harness.rawValue), .blob(data)])
                }
            }
            try deleteObsoleteAttempts(for: run.id, keeping: currentAttemptIDs)
            for record in worktrees { try saveWorktreeRecord(record) }
            try bindAndStep("DELETE FROM judge_votes WHERE run_id = ?", values: [.text(run.id.uuidString)])
            for vote in run.judgeVotes { try upsertJudgeVote(vote) }
            try Self.execute(database, "COMMIT")
        } catch {
            _ = try? Self.execute(database, "ROLLBACK")
            throw error
        }
    }

    public func run(id: UUID) throws -> BenchmarkRun? {
        guard let data = try queryBlobs("SELECT body FROM runs WHERE id = ?", bindings: [.text(id.uuidString)]).first else { return nil }
        return try decoder.decode(BenchmarkRun.self, from: data)
    }

    public func search(_ search: HistorySearch = .init()) throws -> [BenchmarkRun] {
        var clauses: [String] = []
        var bindings: [Binding] = []
        if let text = search.text, !text.isEmpty { clauses.append("(title LIKE ? OR prompt LIKE ?)"); bindings += [.text("%\(text)%"), .text("%\(text)%")] }
        if let directoryPath = search.directoryPath { clauses.append("directory_path = ?"); bindings.append(.text(directoryPath)) }
        if let from = search.from { clauses.append("created_at >= ?"); bindings.append(.double(from.timeIntervalSince1970)) }
        if let to = search.to { clauses.append("created_at <= ?"); bindings.append(.double(to.timeIntervalSince1970)) }
        if search.verdictOnly == true { clauses.append("EXISTS (SELECT 1 FROM verdicts WHERE verdicts.run_id = runs.id)") }
        if search.verdictOnly == false { clauses.append("NOT EXISTS (SELECT 1 FROM verdicts WHERE verdicts.run_id = runs.id)") }
        if let harness = search.harness { clauses.append("EXISTS (SELECT 1 FROM attempts WHERE attempts.run_id = runs.id AND harness = ?)"); bindings.append(.text(harness.rawValue)) }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let decoded = try queryBlobs("SELECT body FROM runs\(whereClause) ORDER BY created_at DESC", bindings: bindings).map { try decoder.decode(BenchmarkRun.self, from: $0) }
        guard let model = search.model, !model.isEmpty else { return decoded }
        return decoded.filter { run in run.agents.contains { $0.requested.model.localizedCaseInsensitiveContains(model) } }
    }

    /// Legacy guard: callers must use the confirmation-bearing deletion API.
    public func deleteRun(id: UUID) throws {
        if let preview = try deletionPreview(for: id), !preview.canDelete { throw JBenchCoreError.storage(preview.refusalReason ?? "Pending worktree requires resolution.") }
        throw JBenchCoreError.storage("History deletion requires an explicit confirmation preview.")
    }

    public func saveWorktree(_ record: WorktreeRecord) throws {
        try saveWorktreeRecord(record)
    }

    private func saveWorktreeRecord(_ record: WorktreeRecord) throws {
        let body = try encoder.encode(record)
        try bindAndStep("INSERT INTO worktrees(id, run_id, attempt_id, disposition, body) SELECT ?, a.run_id, ?, ?, ? FROM attempts a WHERE a.id = ? ON CONFLICT(id) DO UPDATE SET disposition=excluded.disposition, body=excluded.body", values: [.text(record.id.uuidString), .text(record.attemptID.uuidString), .text(record.disposition.rawValue), .blob(body), .text(record.attemptID.uuidString)])
    }

    public func worktrees(for runID: UUID) throws -> [WorktreeRecord] {
        try queryBlobs("SELECT body FROM worktrees WHERE run_id = ? ORDER BY id", bindings: [.text(runID.uuidString)]).map { try decoder.decode(WorktreeRecord.self, from: $0) }
    }

    public func worktree(id: UUID) throws -> WorktreeRecord? {
        try queryBlobs("SELECT body FROM worktrees WHERE id = ?", bindings: [.text(id.uuidString)]).first.map { try decoder.decode(WorktreeRecord.self, from: $0) }
    }

    public func deletionPreview(for runID: UUID) throws -> HistoryDeletionPreview? {
        guard let run = try run(id: runID) else { return nil }
        let evidenceURL = URL(fileURLWithPath: run.rawEvidenceDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: evidenceURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))?.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.path).sorted() ?? []
        return HistoryDeletionPreview(runID: run.id, title: run.title, evidenceDirectory: evidenceURL.path, evidenceFiles: files, worktrees: try worktrees(for: runID))
    }

    public func deletionPreviews(for filter: HistorySearch = .init()) throws -> [HistoryDeletionPreview] {
        try search(filter).compactMap { run in
            let evidenceURL = URL(fileURLWithPath: run.rawEvidenceDirectory)
            let files = (try? FileManager.default.contentsOfDirectory(at: evidenceURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))?.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.path).sorted() ?? []
            return HistoryDeletionPreview(runID: run.id, title: run.title, evidenceDirectory: evidenceURL.path, evidenceFiles: files, worktrees: (try? worktrees(for: run.id)) ?? [])
        }
    }

    /// Deletes database records after preview approval. Filesystem worktrees are deliberately left for the repository service.
    /// A pending worktree always blocks deletion, including delete-all.
    public func deleteRun(id: UUID, confirmation: HistoryDeletionConfirmation, evidenceStore: EvidenceStore? = nil) async throws {
        guard confirmation.runIDs.contains(id) else { throw JBenchCoreError.storage("This deletion was not explicitly confirmed.") }
        guard let preview = try deletionPreview(for: id) else { return }
        guard preview.canDelete else { throw JBenchCoreError.storage(preview.refusalReason ?? "Pending worktree requires resolution.") }
        if confirmation.deleteEvidence {
            guard let evidenceStore else { throw JBenchCoreError.storage("An EvidenceStore is required to delete associated evidence.") }
            _ = try await evidenceStore.deleteEvidence(runID: id, confirmed: true)
        }
        try delete(table: "runs", id: id)
    }

    public func deleteAll(confirmation: HistoryDeletionConfirmation, evidenceStore: EvidenceStore? = nil) async throws {
        let previews = try deletionPreviews()
        let ids = Set(previews.map(\.runID))
        guard confirmation.runIDs == ids else { throw JBenchCoreError.storage("Delete-all confirmation does not match the current history.") }
        if let blocked = previews.first(where: { !$0.canDelete }) { throw JBenchCoreError.storage(blocked.refusalReason ?? "Pending worktree requires resolution.") }
        for preview in previews { try await deleteRun(id: preview.runID, confirmation: confirmation, evidenceStore: evidenceStore) }
    }

    public func saveVerdict(_ verdict: Verdict) throws { try upsert(table: "verdicts", id: verdict.id, blob: encoder.encode(verdict), updatedAt: verdict.recordedAt, additionalID: verdict.runID) }
    public func verdict(for runID: UUID) throws -> Verdict? { try queryBlobs("SELECT body FROM verdicts WHERE run_id = ? ORDER BY recorded_at DESC LIMIT 1", bindings: [.text(runID.uuidString)]).first.map { try decoder.decode(Verdict.self, from: $0) } }
    public func saveJudgeVote(_ vote: JudgeVote) throws { try upsertJudgeVote(vote) }
    public func judgeVotes(for runID: UUID) throws -> [JudgeVote] { try queryBlobs("SELECT body FROM judge_votes WHERE run_id = ? ORDER BY recorded_at ASC", bindings: [.text(runID.uuidString)]).map { try decoder.decode(JudgeVote.self, from: $0) } }

    private enum Binding { case text(String), integer(Int64), double(Double), blob(Data) }
    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
    private func upsert(table: String, id: UUID, blob: Data, updatedAt: Date, additionalID: UUID? = nil) throws {
        if table == "verdicts" {
            try bindAndStep("INSERT INTO verdicts(id, run_id, recorded_at, body) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET run_id=excluded.run_id, recorded_at=excluded.recorded_at, body=excluded.body", values: [.text(id.uuidString), .text(additionalID!.uuidString), .double(updatedAt.timeIntervalSince1970), .blob(blob)])
        } else {
            try bindAndStep("INSERT INTO presets(id, updated_at, body) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at, body=excluded.body", values: [.text(id.uuidString), .double(updatedAt.timeIntervalSince1970), .blob(blob)])
        }
    }
    private func delete(table: String, id: UUID) throws { try bindAndStep("DELETE FROM \(table) WHERE id = ?", values: [.text(id.uuidString)]) }
    /// Worktree resolution uses its attempt ID after a run is saved again. Keep
    /// those backing rows while pruning attempts no longer present in the run.
    private func deleteObsoleteAttempts(for runID: UUID, keeping attemptIDs: [String]) throws {
        let placeholders = Array(repeating: "?", count: attemptIDs.count).joined(separator: ", ")
        let retainedClause = attemptIDs.isEmpty ? "" : " AND id NOT IN (\(placeholders))"
        let statement = "DELETE FROM attempts WHERE run_id = ?\(retainedClause) AND id NOT IN (SELECT attempt_id FROM worktrees WHERE run_id = ?)"
        let values = [.text(runID.uuidString)] + attemptIDs.map(Binding.text) + [.text(runID.uuidString)]
        try bindAndStep(statement, values: values)
    }
    private func queryBlobs(_ sql: String, bindings: [Binding] = []) throws -> [Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Self.error(database) }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var results: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            results.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
        return results
    }
    private func bindAndStep(_ sql: String, values: [Binding]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Self.error(database) }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(database) }
    }
    private func bind(_ values: [Binding], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1); let result: Int32
            switch value {
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transientDestructor) }
            case .integer(let integer): result = sqlite3_bind_int64(statement, index, integer)
            case .double(let double): result = sqlite3_bind_double(statement, index, double)
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transientDestructor) }
            }
            guard result == SQLITE_OK else { throw Self.error(database) }
        }
    }
    private static var transientDestructor: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private static func error(_ database: OpaquePointer) -> JBenchCoreError { .storage(String(cString: sqlite3_errmsg(database))) }
    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            throw JBenchCoreError.storage(message)
        }
    }
    private static func migrate(_ database: OpaquePointer) throws {
        try execute(database, "CREATE TABLE IF NOT EXISTS migrations(version INTEGER PRIMARY KEY)")
        try execute(database, "CREATE TABLE IF NOT EXISTS presets(id TEXT PRIMARY KEY, updated_at REAL NOT NULL, body BLOB NOT NULL)")
        try execute(database, "CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, title TEXT NOT NULL, prompt TEXT NOT NULL, directory_path TEXT NOT NULL, created_at REAL NOT NULL, state TEXT NOT NULL, body BLOB NOT NULL)")
        try execute(database, "CREATE INDEX IF NOT EXISTS runs_search_idx ON runs(created_at DESC, directory_path)")
        try execute(database, "CREATE TABLE IF NOT EXISTS attempts(id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, agent_run_id TEXT NOT NULL, number INTEGER NOT NULL, state TEXT NOT NULL, harness TEXT NOT NULL, body BLOB NOT NULL)")
        try execute(database, "CREATE INDEX IF NOT EXISTS attempts_run_harness_idx ON attempts(run_id, harness)")
        try execute(database, "CREATE TABLE IF NOT EXISTS verdicts(id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, recorded_at REAL NOT NULL, body BLOB NOT NULL)")
        try execute(database, "CREATE INDEX IF NOT EXISTS verdicts_run_idx ON verdicts(run_id)")
        try execute(database, "CREATE TABLE IF NOT EXISTS judge_votes(id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, recorded_at REAL NOT NULL, body BLOB NOT NULL)")
        try execute(database, "CREATE INDEX IF NOT EXISTS judge_votes_run_idx ON judge_votes(run_id)")
        try execute(database, "CREATE TABLE IF NOT EXISTS worktrees(id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, attempt_id TEXT NOT NULL, disposition TEXT NOT NULL, body BLOB NOT NULL)")
        try execute(database, "CREATE INDEX IF NOT EXISTS worktrees_run_idx ON worktrees(run_id)")
        try execute(database, "INSERT OR IGNORE INTO migrations(version) VALUES(1)")
    }

    private func upsertJudgeVote(_ vote: JudgeVote) throws {
        try bindAndStep("INSERT INTO judge_votes(id, run_id, recorded_at, body) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET run_id=excluded.run_id, recorded_at=excluded.recorded_at, body=excluded.body", values: [.text(vote.id.uuidString), .text(vote.runID.uuidString), .double(vote.recordedAt.timeIntervalSince1970), .blob(try encoder.encode(vote))])
    }
}
