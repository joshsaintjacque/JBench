import Darwin
import Foundation

/// Launches each harness as the leader of a dedicated process group. Descendants
/// inherit that group, so fallback shutdown can target one attempt's full tree.
public enum OwnedProcessLauncher {
    public struct Command: Sendable {
        public let executable: URL
        public let arguments: [String]
    }

    public static func command(executable: URL, arguments: [String]) -> Command {
        guard let launcher = launcherURL() else { return Command(executable: executable, arguments: arguments) }
        return Command(executable: launcher, arguments: [executable.path] + arguments)
    }

    public static func ownsProcessGroup(_ processID: Int32) -> Bool {
        processID > 0 && getpgid(processID) == processID
    }

    public static func groupIsRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        errno = 0
        if Darwin.kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    @discardableResult
    public static func signalGroup(_ processID: Int32, _ signal: Int32) -> Bool {
        guard ownsProcessGroup(processID) || groupIsRunning(processID) else { return false }
        return Darwin.kill(-processID, signal) == 0
    }

    private static func launcherURL() -> URL? {
        let fileManager = FileManager.default
        let bundleHelper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/JBenchProcessLauncher")
        if fileManager.isExecutableFile(atPath: bundleHelper.path) { return bundleHelper }
        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<5 {
            if let candidate = directory?.appending(path: "JBenchProcessLauncher"), fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
            directory = directory?.deletingLastPathComponent()
        }
        return nil
    }
}
