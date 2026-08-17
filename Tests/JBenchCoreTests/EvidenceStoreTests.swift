import Foundation
import Testing
@testable import JBenchCore

struct EvidenceStoreTests {
    @Test func appendsDurableJSONLinesPerAttempt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-evidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(rootDirectory: root)
        let runID = UUID(); let attemptID = UUID()
        try await store.append(.init(attemptID: attemptID, eventType: "delta", rawJSON: #"{"text":"one"}"#), runID: runID)
        try await store.append(.init(attemptID: attemptID, eventType: "complete", rawJSON: #"{"ok":true}"#), runID: runID)
        let records = try await store.records(runID: runID, attemptID: attemptID)
        #expect(records.map(\.eventType) == ["delta", "complete"])
        #expect(records.first?.rawJSON == #"{"text":"one"}"#)
    }
}
