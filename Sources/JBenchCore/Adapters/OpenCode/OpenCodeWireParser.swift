import Foundation

/// A small, intentionally tolerant parser for OpenCode's unversioned SSE payloads.
/// It preserves every original event in `AdapterEvent.rawJSON`; these values are only
/// the display and metrics subset that JBench can prove from the event itself.
enum OpenCodeWireParser {
    static func serverURL(from line: String) -> URL? {
        let pattern = #"https?://[^\s]+"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(line[range]))
    }

    static func parseEvent(_ rawJSON: String) -> OpenCodeParsedEvent {
        guard let envelope = jsonObject(rawJSON) else {
            return .init(kind: .activity, text: "Unparseable OpenCode event.")
        }
        // OpenCode v1.18.18 sends SSE envelopes as { directory, payload }. Keep
        // accepting direct events for stored fixtures and older server shapes.
        let root = envelope["payload"] as? [String: Any] ?? envelope
        guard let type = string(in: root, paths: [["type"], ["event"]]) else {
            return .init(kind: .activity, text: "Unparseable OpenCode event.")
        }
        let loweredType = type.lowercased()
        if loweredType.contains("session.error") || loweredType.hasSuffix(".error") {
            return .init(kind: .failed, text: string(in: root, paths: [["properties", "error", "message"], ["properties", "message"], ["error", "message"], ["message"]]))
        }
        if loweredType == "session.idle" || (loweredType.contains("session.status") && string(in: root, paths: [["properties", "status", "type"], ["status", "type"], ["properties", "status"], ["status"]])?.lowercased() == "idle") {
            return .init(kind: .completed)
        }
        if loweredType.contains("permission") {
            let permissionID = string(in: root, paths: [["properties", "id"], ["properties", "permission", "id"], ["permission", "id"], ["id"]])
            let category = string(in: root, paths: [["properties", "permission", "type"], ["properties", "type"], ["properties", "permission"], ["permission", "type"]])
            let summary = string(in: root, paths: [["properties", "permission", "description"], ["properties", "description"], ["properties", "title"]])
            let targetPath = string(in: root, paths: [["properties", "permission", "path"], ["properties", "path"], ["properties", "permission", "file"]])
            return .init(kind: .permission, permissionID: permissionID, permissionCategory: category, permissionSummary: summary, targetPath: targetPath)
        }
        if loweredType.contains("message.part.updated") {
            let partType = string(in: root, paths: [["properties", "part", "type"], ["part", "type"]])?.lowercased()
            if partType == "text" {
                let delta = string(in: root, paths: [["properties", "delta"], ["properties", "part", "text"], ["properties", "part", "delta"], ["delta"]])
                return .init(kind: .textDelta, text: delta)
            }
        }
        if loweredType.contains("message.updated") {
            let model = string(in: root, paths: [["properties", "info", "model"], ["properties", "info", "modelID"], ["properties", "message", "model"]])
            let provider = string(in: root, paths: [["properties", "info", "provider"], ["properties", "info", "providerID"], ["properties", "message", "provider"]])
            let observedModel = [provider, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
            let observed = ObservedSettings(model: observedModel.isEmpty ? .unavailable : .init(observedModel, provenance: .harnessReported))
            let metrics = metrics(in: root)
            if !observedModel.isEmpty { return .init(kind: .observed, observed: observed, metrics: metrics) }
            if metrics != nil { return .init(kind: .metrics, metrics: metrics) }
        }
        return .init(kind: .activity, text: type)
    }

    static func catalogEntries(from rawJSON: String, source: String = "OpenCode GET /provider") -> [ModelCatalogEntry] {
        guard let root = jsonObject(rawJSON) else { return [] }
        var entries: [ModelCatalogEntry] = []
        visitModels(root) { provider, modelID, displayName, reasoning in
            let nativeID = provider.isEmpty ? modelID : "\(provider)/\(modelID)"
            entries.append(.init(harness: .openCode, nativeModelID: nativeID, displayName: displayName, nativeReasoningValues: reasoning, discoverySource: source))
        }
        return entries
    }

    static func string(in rawJSON: String, paths: [[String]]) -> String? {
        guard let root = jsonObject(rawJSON) else { return nil }
        return string(in: root, paths: paths)
    }

    static func version(from rawJSON: String) -> String? {
        string(in: rawJSON, paths: [["version"], ["data", "version"], ["properties", "version"]])
    }

    static func authenticationStatus(from rawJSON: String, statusCode: Int) -> AuthenticationStatus {
        guard (200..<300).contains(statusCode) else { return statusCode == 401 || statusCode == 403 ? .missing : .unknown }
        guard let root = jsonObject(rawJSON) else { return .unknown }
        let values = flattenedStrings(in: root).map { $0.lowercased() }
        if values.contains(where: { ["connected", "authenticated", "ready", "valid"].contains($0) }) { return .ready }
        if values.contains(where: { ["missing", "unauthenticated", "disconnected", "invalid"].contains($0) }) { return .missing }
        return .unknown
    }

    private static func metrics(in root: [String: Any]) -> AttemptMetrics? {
        let input = int(in: root, paths: [["properties", "info", "tokens", "input"], ["properties", "info", "tokens", "inputTokens"], ["properties", "info", "inputTokens"]])
        let output = int(in: root, paths: [["properties", "info", "tokens", "output"], ["properties", "info", "tokens", "outputTokens"], ["properties", "info", "outputTokens"]])
        let cost = decimal(in: root, paths: [["properties", "info", "cost"], ["properties", "info", "cost", "total"]])
        guard input != nil || output != nil || cost != nil else { return nil }
        return AttemptMetrics(
            inputTokens: input,
            outputTokens: output,
            tokenProvenance: input != nil || output != nil ? .harnessReported : .unavailable,
            cost: cost,
            costProvenance: cost == nil ? .unavailable : .harnessReported
        )
    }

    private static func jsonObject(_ rawJSON: String) -> [String: Any]? {
        guard let data = rawJSON.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    fileprivate static func string(in root: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var current: Any = root
            for component in path {
                guard let dictionary = current as? [String: Any], let next = dictionary[component] else { current = NSNull(); break }
                current = next
            }
            if let value = current as? String { return value }
            if let value = current as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func int(in root: [String: Any], paths: [[String]]) -> Int? {
        for path in paths {
            var current: Any = root
            for component in path {
                guard let dictionary = current as? [String: Any], let next = dictionary[component] else { current = NSNull(); break }
                current = next
            }
            if let number = current as? NSNumber { return number.intValue }
            if let string = current as? String, let number = Int(string) { return number }
        }
        return nil
    }

    private static func decimal(in root: [String: Any], paths: [[String]]) -> Decimal? {
        for path in paths {
            var current: Any = root
            for component in path {
                guard let dictionary = current as? [String: Any], let next = dictionary[component] else { current = NSNull(); break }
                current = next
            }
            if let number = current as? NSNumber { return number.decimalValue }
            if let string = current as? String { return Decimal(string: string) }
        }
        return nil
    }

    private static func visitModels(_ value: Any, inheritedProvider: String = "", visit: (String, String, String?, [String]) -> Void) {
        if let dictionary = value as? [String: Any] {
            let provider = string(in: dictionary, paths: [["id"], ["providerID"], ["provider"]]) ?? inheritedProvider
            if let models = dictionary["models"] as? [String: Any] {
                for (modelID, metadata) in models {
                    let displayName = (metadata as? [String: Any]).flatMap { string(in: $0, paths: [["name"], ["displayName"]]) }
                    let reasoning = (metadata as? [String: Any]).flatMap { $0["reasoning"] as? [String] } ?? []
                    visit(provider, modelID, displayName, reasoning)
                }
            }
            if let models = dictionary["models"] as? [[String: Any]] {
                for metadata in models {
                    guard let modelID = string(in: metadata, paths: [["id"], ["modelID"]]) else { continue }
                    let displayName = string(in: metadata, paths: [["name"], ["displayName"]])
                    let reasoning = metadata["reasoning"] as? [String] ?? []
                    visit(provider, modelID, displayName, reasoning)
                }
            }
            for child in dictionary.values { visitModels(child, inheritedProvider: provider, visit: visit) }
        } else if let array = value as? [Any] {
            for child in array { visitModels(child, inheritedProvider: inheritedProvider, visit: visit) }
        }
    }

    private static func flattenedStrings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(flattenedStrings) }
        if let array = value as? [Any] { return array.flatMap(flattenedStrings) }
        return []
    }
}

struct OpenCodeParsedEvent: Sendable {
    enum Kind: Sendable, Equatable { case textDelta, activity, observed, metrics, permission, completed, failed }
    var kind: Kind
    var text: String? = nil
    var observed: ObservedSettings? = nil
    var metrics: AttemptMetrics? = nil
    var permissionID: String? = nil
    var permissionCategory: String? = nil
    var permissionSummary: String? = nil
    var targetPath: String? = nil
    var isTerminal: Bool { kind == .completed || kind == .failed }
}
