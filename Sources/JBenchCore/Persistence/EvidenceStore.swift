import Foundation

public struct RawEvidenceRecord: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var attemptID: UUID
    public var eventType: String
    /// The adapter's retained native JSON. JBench does not destructively normalize it.
    public var rawJSON: String
    public init(timestamp: Date = .now, attemptID: UUID, eventType: String, rawJSON: String) { self.timestamp = timestamp; self.attemptID = attemptID; self.eventType = eventType; self.rawJSON = rawJSON }
}

public actor EvidenceStore {
    public let rootDirectory: URL
    private let encoder: JSONEncoder

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    public func makeRunDirectory(runID: UUID) throws -> URL {
        let directory = rootDirectory.appending(path: runID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    public func append(_ record: RawEvidenceRecord, runID: UUID) throws -> String {
        let directory = try makeRunDirectory(runID: runID)
        let filename = "\(record.attemptID.uuidString).jsonl"
        let url = directory.appending(path: filename)
        var line = try encoder.encode(record)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } else {
            try line.write(to: url, options: [.atomic])
        }
        return filename
    }

    public func records(runID: UUID, attemptID: UUID) throws -> [RawEvidenceRecord] {
        let url = rootDirectory.appending(path: runID.uuidString, directoryHint: .isDirectory).appending(path: "\(attemptID.uuidString).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try text.split(separator: "\n").map { try decoder.decode(RawEvidenceRecord.self, from: Data($0.utf8)) }
    }

    /// Reports the exact directory. Destructive cleanup is deliberately owned by the worktree/history layer.
    public func evidenceDirectory(runID: UUID) -> URL { rootDirectory.appending(path: runID.uuidString, directoryHint: .isDirectory) }

    public func evidenceFiles(runID: UUID) -> [URL] {
        let directory = evidenceDirectory(runID: runID)
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.path < $1.path }
    }

    /// Removes only this run's evidence, and only when the caller has an explicit confirmation.
    /// Worktrees are not under this store and are never touched here.
    @discardableResult
    public func deleteEvidence(runID: UUID, confirmed: Bool) throws -> Bool {
        guard confirmed else { throw JBenchCoreError.storage("Evidence deletion requires explicit confirmation.") }
        let directory = evidenceDirectory(runID: runID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        try FileManager.default.removeItem(at: directory)
        return true
    }
}
