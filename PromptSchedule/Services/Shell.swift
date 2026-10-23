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
    /// Collects a process's output from the reader threads.
    private final class Output: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
        var timedOut = false
    }

    /// Runs an executable and collects stdout/stderr without blocking any thread
    /// of the Swift concurrency pool.
    ///
    /// Completion comes from `terminationHandler`, not `waitUntilExit()`: the
    /// latter spins a run loop that background threads don't service, and could
    /// hang forever even after the process had exited.
    /// The process is killed after `timeout` seconds so one stuck command can't
    /// stall the caller.
    static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) async throws -> ShellResult {
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

        let output = Output()
        let group = DispatchGroup()

        return try await withCheckedThrowingContinuation { continuation in
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Drain both pipes concurrently so a chatty process can't block on a full pipe.
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                output.stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                output.stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    output.timedOut = true
                    process.terminate()
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                if output.timedOut {
                    let name = URL(fileURLWithPath: executable).lastPathComponent
                    continuation.resume(throwing: ShellError.failed("\(name) timed out after \(Int(timeout)) seconds."))
                    return
                }
                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    output: String(decoding: output.stdout, as: UTF8.self),
                    error: String(decoding: output.stderr, as: UTF8.self)
                ))
            }
        }
    }
}
