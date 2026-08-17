import Foundation

public struct CommandResult: Sendable, Hashable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(status: Int32, standardOutput: Data, standardError: Data) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var errorText: String { String(decoding: standardError, as: UTF8.self) }
}

public enum SystemCommandError: Error, LocalizedError, Sendable, Equatable {
    case executableMissing(String)
    case unexpectedExit(executable: String, status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path): "Required executable is missing: \(path)"
        case .unexpectedExit(let executable, let status, let message):
            "\(executable) exited with status \(status): \(message)"
        }
    }
}

/// Runs a fixed executable with an argument array. It never invokes a shell.
public enum SystemCommand {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        acceptedExitStatuses: Set<Int32> = [0]
    ) throws -> CommandResult {
        let executable = executable.standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SystemCommandError.executableMissing(executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory?.standardizedFileURL
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let result = CommandResult(
            status: process.terminationStatus,
            standardOutput: output.fileHandleForReading.readDataToEndOfFile(),
            standardError: error.fileHandleForReading.readDataToEndOfFile()
        )
        guard acceptedExitStatuses.contains(result.status) else {
            let message = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SystemCommandError.unexpectedExit(
                executable: executable.path,
                status: result.status,
                message: message.isEmpty ? result.outputText.trimmingCharacters(in: .whitespacesAndNewlines) : message
            )
        }
        return result
    }
}
