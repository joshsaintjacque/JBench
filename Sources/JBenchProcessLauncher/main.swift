import Darwin
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: JBenchProcessLauncher executable [arguments...]\n".utf8))
    exit(64)
}

guard setpgid(0, 0) == 0 else {
    FileHandle.standardError.write(Data("JBenchProcessLauncher could not create an owned process group.\n".utf8))
    exit(71)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let executable = arguments[0]
var cArguments = arguments.map { strdup($0) }
cArguments.append(nil)
defer { cArguments.compactMap { $0 }.forEach { free($0) } }
execv(executable, &cArguments)
FileHandle.standardError.write(Data("JBenchProcessLauncher could not exec \(executable): \(String(cString: strerror(errno)))\n".utf8))
exit(72)
