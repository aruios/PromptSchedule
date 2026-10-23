//
//  Shell.swift
//  PromptSchedule
//

import Foundation

nonisolated struct ShellResult: Sendable {
    var status: Int32
    var output: String
    var error: String
}

nonisolated enum ShellError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

nonisolated enum Shell {
    /// Runs an executable off the main thread and collects stdout/stderr.
    static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ShellResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }
            if let environment { process.environment = environment }
            process.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()

            // Drain stderr concurrently so a chatty process can't block on a full pipe.
            let errTask = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = await errTask.value
            process.waitUntilExit()

            return ShellResult(
                status: process.terminationStatus,
                output: String(decoding: outData, as: UTF8.self),
                error: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }
}
