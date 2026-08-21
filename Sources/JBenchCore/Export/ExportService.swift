import CryptoKit
import Foundation

/// A file copied into a portable evidence bundle.
public struct ExportedFile: Codable, Sendable, Hashable {
    public let path: String
    public let sha256: String
    public let byteCount: Int

    public init(path: String, sha256: String, byteCount: Int) {
        self.path = path; self.sha256 = sha256; self.byteCount = byteCount
    }
}

/// The manifest written to `run-manifest.json` in a portable bundle.
/// Every path in this manifest is relative to the bundle directory.
public struct PortableEvidenceManifest: Codable, Sendable, Hashable {
    public let formatVersion: Int
    public let exportedAt: Date
    public let run: BenchmarkRun
    public let evidence: [ExportedFile]
    public let patches: [ExportedFile]
    public let verdict: Verdict?

    public init(formatVersion: Int = 1, exportedAt: Date = .now, run: BenchmarkRun, evidence: [ExportedFile], patches: [ExportedFile], verdict: Verdict? = nil) {
        self.formatVersion = formatVersion; self.exportedAt = exportedAt; self.run = run
        self.evidence = evidence; self.patches = patches; self.verdict = verdict
    }
}

public struct EvidenceBundleExport: Sendable, Hashable {
    public let directory: URL
    public let reportURL: URL
    public let manifestURL: URL
    public let files: [ExportedFile]

    public init(directory: URL, reportURL: URL, manifestURL: URL, files: [ExportedFile]) {
        self.directory = directory; self.reportURL = reportURL; self.manifestURL = manifestURL; self.files = files
    }
}

/// Renders reports and copies the run's referenced evidence without touching source data.
public struct ExportService: Sendable {
    public init() {}

    /// Creates a unique directory below `destination` and writes `report.md` there.
    public func exportMarkdownReport(_ run: BenchmarkRun, verdict: Verdict? = nil, to destination: URL) throws -> URL {
        let directory = try makeUniqueDirectory(below: destination, title: run.title)
        let report = directory.appendingPathComponent("report.md")
        try render(run, verdict: verdict).write(to: report, atomically: true, encoding: .utf8)
        return report
    }

    /// Creates a unique, portable directory containing a report, manifest, raw JSONL,
    /// and any explicitly supplied patch files.
    public func exportEvidenceBundle(_ run: BenchmarkRun, verdict: Verdict? = nil, patches: [URL] = [], to destination: URL) throws -> EvidenceBundleExport {
        let directory = try makeUniqueDirectory(below: destination, title: run.title)
        let evidenceDirectory = directory.appendingPathComponent("evidence", isDirectory: true)
        let patchesDirectory = directory.appendingPathComponent("patches", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: patchesDirectory, withIntermediateDirectories: false)

        var copiedEvidence: [ExportedFile] = []
        var usedEvidenceNames = Set<String>()
        var portableRun = run
        portableRun.rawEvidenceDirectory = "evidence"
        for agentIndex in portableRun.agents.indices {
            for attemptIndex in portableRun.agents[agentIndex].attempts.indices {
                var attempt = portableRun.agents[agentIndex].attempts[attemptIndex]
                guard let reference = attempt.rawEventFile, !reference.isEmpty else { continue }
                let source = try resolveEvidence(reference, root: URL(fileURLWithPath: run.rawEvidenceDirectory, isDirectory: true))
                let outputName = uniqueEvidenceName(preferred: "\(attempt.id.uuidString).jsonl", usedNames: &usedEvidenceNames)
                let relative = "evidence/\(outputName)"
                let output = evidenceDirectory.appendingPathComponent(outputName)
                try copyRegularFile(source, to: output)
                copiedEvidence.append(try fileRecord(relativePath: relative, at: output))
                attempt.rawEventFile = outputName
                portableRun.agents[agentIndex].attempts[attemptIndex] = attempt
            }
        }
        for voteIndex in portableRun.judgeVotes.indices {
            var vote = portableRun.judgeVotes[voteIndex]
            guard let reference = vote.rawEvidenceFile, !reference.isEmpty else { continue }
            let source = try resolveEvidence(reference, root: URL(fileURLWithPath: run.rawEvidenceDirectory, isDirectory: true))
            let outputName = uniqueEvidenceName(preferred: "judge-\(vote.id.uuidString).jsonl", usedNames: &usedEvidenceNames)
            let relative = "evidence/\(outputName)"
            let output = evidenceDirectory.appendingPathComponent(outputName)
            try copyRegularFile(source, to: output)
            copiedEvidence.append(try fileRecord(relativePath: relative, at: output))
            vote.rawEvidenceFile = outputName
            portableRun.judgeVotes[voteIndex] = vote
        }

        var copiedPatches: [ExportedFile] = []
        for patch in patches {
            let source = patch.standardizedFileURL
            guard source.isFileURL, FileManager.default.fileExists(atPath: source.path) else {
                throw JBenchCoreError.storage("Patch file does not exist: \(patch.path)")
            }
            let safeName = "\(UUID().uuidString)-\(source.lastPathComponent)"
            let output = patchesDirectory.appendingPathComponent(safeName)
            try copyRegularFile(source, to: output)
            copiedPatches.append(try fileRecord(relativePath: "patches/\(safeName)", at: output))
        }

        let reportURL = directory.appendingPathComponent("report.md")
        try render(run, verdict: verdict).write(to: reportURL, atomically: true, encoding: .utf8)
        let manifestURL = directory.appendingPathComponent("run-manifest.json")
        let manifest = PortableEvidenceManifest(run: portableRun, evidence: copiedEvidence, patches: copiedPatches, verdict: verdict)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return EvidenceBundleExport(directory: directory, reportURL: reportURL, manifestURL: manifestURL, files: copiedEvidence + copiedPatches)
    }

    private func render(_ run: BenchmarkRun, verdict: Verdict?) -> String {
        var output = "# \(run.title)\n\n"
        output += "- **Run ID:** `\(run.id.uuidString)`\n- **Created:** \(date(run.createdAt))\n- **State:** `\(run.state.rawValue)`\n- **Execution mode:** `\(run.executionMode.rawValue)`\n- **Directory:** `\(run.directoryPath)`\n- **Repository:** `\(run.repositoryState.rawValue)`\n- **Source commit:** `\(run.sourceCommit ?? "Unavailable")`\n\n"
        output += "## Prompt\n\n```text\n\(run.prompt.replacingOccurrences(of: "```", with: "``\\u{200B}`"))\n```\n\n"
        output += "## Lanes\n\n"
        for (index, lane) in run.agents.sorted(by: { $0.displayOrder < $1.displayOrder }).enumerated() {
            let attempt = lane.attempts.last
            let observedModel = observed(attempt?.observed.model) ?? "Unavailable"
            let observedReasoning = observed(attempt?.observed.reasoning) ?? "Unavailable"
            let harnessVersion = observed(attempt?.observed.harnessVersion) ?? run.harnessVersions[lane.requested.harness] ?? "Unavailable"
            let protocolVersion = run.integrationProtocolVersions?[lane.requested.harness] ?? "Unavailable"
            output += "### Lane \(index + 1): \(lane.requested.harness.rawValue) / \(lane.requested.model)\n\n"
            output += "- **State:** `\(lane.state.rawValue)`\n- **Requested model:** `\(lane.requested.model)`\n- **Requested reasoning:** `\(lane.requested.reasoning ?? "Unavailable")`\n- **Observed model:** \(observedModel)\n- **Observed reasoning:** \(observedReasoning)\n- **Harness version:** \(harnessVersion)\n- **Integration protocol:** \(protocolVersion)\n"
            if let metrics = attempt?.metrics { output += metricsText(metrics) }
            if let error = attempt?.errorMessage { output += "- **Error:** \(error)\n" }
            output += "\n#### Response\n\n\(attempt?.finalResponse.isEmpty == false ? attempt!.finalResponse : "_(No response)_")\n\n"
        }
        if !run.judgeConfigurations.isEmpty || !run.judgeVotes.isEmpty {
            output += renderAIJudges(run)
        }
        output += "## Verdict\n\n"
        if let verdict { output += "- **Winner:** `\(verdict.winningAgentRunID?.uuidString ?? "None")`\n- **Note:** \(verdict.note ?? "None")\n" } else { output += "No manual verdict recorded.\n" }
        return output
    }

    private func renderAIJudges(_ run: BenchmarkRun) -> String {
        var output = "## AI Judges\n\n"
        if run.judgeConfigurations.isEmpty {
            output += "No AI judges configured.\n\n"
        } else {
            for judge in run.judgeConfigurations {
                output += "### \(judge.name)\n\n"
                output += "- **Harness:** `\(judge.harness.rawValue)`\n- **Model:** `\(judge.model)`\n- **Reasoning:** `\(judge.reasoning ?? "Unavailable")`\n"
                if let steering = judge.steeringPrompt, !steering.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output += "- **Steering guidance:**\n\n```text\n\(steering.replacingOccurrences(of: "```", with: "``\\u{200B}`"))\n```\n"
                } else {
                    output += "- **Steering guidance:** None\n"
                }
                output += "\n"
            }
        }

        if run.judgeVotes.isEmpty {
            output += "No AI judge votes recorded.\n\n"
            return output
        }

        output += "### Votes\n\n"
        for vote in run.judgeVotes {
            output += "#### \(vote.judge.name)\n\n"
            if let error = vote.errorMessage, !error.isEmpty {
                output += "- **Error:** \(error)\n- **Timestamp:** \(date(vote.recordedAt))\n\n"
                continue
            }
            let actualCandidate = vote.winningAgentRunID.flatMap { id in run.agents.first(where: { $0.id == id }) }
            let candidateDescription: String
            if let actualCandidate {
                candidateDescription = "`\(actualCandidate.requested.harness.rawValue)` / `\(actualCandidate.requested.model)`"
            } else {
                candidateDescription = "Unavailable"
            }
            output += "- **Blind candidate:** `\(vote.winningBlindLabel ?? "Unavailable")`\n- **Resolved candidate:** \(candidateDescription)\n- **Reason:** \(vote.reasoning ?? "Unavailable")\n- **Timestamp:** \(date(vote.recordedAt))\n\n"
        }
        return output
    }

    private func metricsText(_ metrics: AttemptMetrics) -> String {
        "- **Metrics:** elapsed \(metric(metrics.elapsedSeconds, provenance: metrics.elapsedProvenance)); input tokens \(metric(metrics.inputTokens, provenance: metrics.tokenProvenance)); output tokens \(metric(metrics.outputTokens, provenance: metrics.tokenProvenance)); cost \(metric(metrics.cost, provenance: metrics.costProvenance))\n"
    }

    private func metric<T>(_ value: T?, provenance: MetricProvenance) -> String { "\(value.map(String.init(describing:)) ?? "Unavailable") (\(provenance.rawValue))" }
    private func observed(_ value: ObservedValue?) -> String? { guard let value, let text = value.value else { return nil }; return "`\(text)` (\(value.provenance.rawValue))" }
    private func date(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func makeUniqueDirectory(below destination: URL, title: String) throws -> URL {
        let fm = FileManager.default; let parent = destination.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // `fileExists(_:isDirectory:)` does not update the flag when the
            // path was absent, so verify the newly-created parent explicitly.
            guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory) else {
                throw JBenchCoreError.storage("Could not create export destination.")
            }
        }
        guard isDirectory.boolValue else { throw JBenchCoreError.storage("Export destination is not a directory.") }
        let slug = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        for _ in 0..<3 {
            let folder = parent.appendingPathComponent("JBench-\(slug.isEmpty ? "run" : slug)-\(UUID().uuidString)", isDirectory: true)
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: false); return folder } catch { continue }
        }
        throw JBenchCoreError.storage("Could not create a unique export directory.")
    }

    private func resolveEvidence(_ reference: String, root: URL) throws -> URL {
        let candidate = (reference.hasPrefix("/") ? URL(fileURLWithPath: reference) : root.appendingPathComponent(reference)).standardizedFileURL
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { throw JBenchCoreError.storage("Evidence reference escapes its run directory.") }
        return candidate
    }
    private func copyRegularFile(_ source: URL, to output: URL) throws {
        var isDirectory: ObjCBool = false; let fm = FileManager.default
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { throw JBenchCoreError.storage("Evidence file is missing or not regular: \(source.path)") }
        guard !fm.fileExists(atPath: output.path) else { throw JBenchCoreError.storage("Export would overwrite an existing file.") }
        try fm.copyItem(at: source, to: output)
    }
    private func fileRecord(relativePath: String, at url: URL) throws -> ExportedFile {
        let data = try Data(contentsOf: url); return ExportedFile(path: relativePath, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: data.count)
    }
    private func uniqueEvidenceName(preferred: String, usedNames: inout Set<String>) -> String {
        guard usedNames.contains(preferred) else { usedNames.insert(preferred); return preferred }
        let base = String(preferred.dropLast(".jsonl".count))
        var suffix = 2
        while usedNames.contains("\(base)-\(suffix).jsonl") { suffix += 1 }
        let name = "\(base)-\(suffix).jsonl"
        usedNames.insert(name)
        return name
    }
}
