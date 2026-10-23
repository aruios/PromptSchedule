//
//  SessionScanner.swift
//  PromptSchedule
//

import Foundation

/// Finds interactive Claude Code sessions by scanning the process table.
nonisolated enum SessionScanner {
    /// Sub-commands and flags that mark a `claude` process as non-interactive
    /// (daemon helpers, headless `-p` runs such as our own reframing).
    private static let excludedTokens: Set<String> = [
        "-p", "--print", "daemon", "bg-spare", "bg-pty-host", "--bg-spare", "--bg-pty-host",
    ]

    static func scan() async -> [ClaudeSession] {
        guard let ps = try? await Shell.run("/bin/ps", ["-axo", "pid=,tty=,args="]) else { return [] }

        var sessions: [ClaudeSession] = []
        for line in ps.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let tty = String(parts[1])
            // "??" means no controlling terminal, so there's no tab to type into.
            guard tty != "??" else { continue }

            let tokens = parts[2].split(separator: " ").map(String.init)
            guard let command = tokens.first,
                  URL(fileURLWithPath: command).lastPathComponent == "claude",
                  excludedTokens.isDisjoint(with: tokens.dropFirst())
            else { continue }

            sessions.append(ClaudeSession(pid: pid, tty: "/dev/\(tty)"))
        }

        let cwds = await workingDirectories(for: sessions.map(\.pid))
        for index in sessions.indices {
            sessions[index].cwd = cwds[sessions[index].pid]
        }
        return sessions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Looks up each process's working directory with a single `lsof` call.
    private static func workingDirectories(for pids: [Int32]) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let result = try? await Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", list]) else {
            return [:]
        }

        // -F output: "p<pid>" starts a process record, "n<path>" is the file name.
        var map: [Int32: String] = [:]
        var current: Int32?
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("p") {
                current = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = current {
                map[pid] = String(line.dropFirst())
            }
        }
        return map
    }

    /// Whether the process is still alive and still attached to the same terminal.
    static func isAlive(pid: Int32, tty: String) async -> Bool {
        guard let result = try? await Shell.run("/bin/ps", ["-o", "tty=", "-p", String(pid)]),
              result.status == 0
        else { return false }
        let current = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "/dev/\(current)" == tty
    }
}
