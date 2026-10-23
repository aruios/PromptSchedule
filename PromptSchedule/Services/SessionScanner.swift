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

    private struct ProcessInfoRow {
        var ppid: Int32
        var tty: String
        var args: String
    }

    static func scan() async -> [ClaudeSession] {
        guard let ps = try? await Shell.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,args="]) else { return [] }

        var table: [Int32: ProcessInfoRow] = [:]
        for line in ps.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            table[pid] = ProcessInfoRow(ppid: ppid, tty: String(parts[2]), args: String(parts[3]))
        }

        var sessions: [ClaudeSession] = []
        for (pid, row) in table {
            // "??" means no controlling terminal, so there's no tab to type into.
            guard row.tty != "??" else { continue }
            let tokens = row.args.split(separator: " ").map(String.init)
            guard let command = tokens.first,
                  URL(fileURLWithPath: command).lastPathComponent == "claude",
                  excludedTokens.isDisjoint(with: tokens.dropFirst())
            else { continue }

            var session = ClaudeSession(pid: pid, tty: "/dev/\(row.tty)")
            session.terminal = terminalKind(for: pid, in: table)
            if let info = SessionStatusReader.read(pid: pid) {
                session.status = info.status
                session.statusUpdatedAt = info.statusUpdatedAt
                session.sessionId = info.sessionId
                session.cwd = info.cwd
            }
            sessions.append(session)
        }

        // Fall back to lsof for sessions without a status file.
        let missing = sessions.filter { $0.cwd == nil }.map(\.pid)
        if !missing.isEmpty {
            let cwds = await workingDirectories(for: missing)
            for index in sessions.indices where sessions[index].cwd == nil {
                sessions[index].cwd = cwds[sessions[index].pid]
            }
        }
        return sessions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Walks up the parent chain to see which terminal hosts the process.
    /// tmux wins over the outer terminal, since the tty belongs to a tmux pane.
    private static func terminalKind(for pid: Int32, in table: [Int32: ProcessInfoRow]) -> TerminalKind {
        var current = table[pid]?.ppid ?? 1
        var hops = 0
        while current > 1, let row = table[current], hops < 32 {
            let executable = URL(fileURLWithPath: row.args.split(separator: " ").first.map(String.init) ?? "")
                .lastPathComponent
            if executable.hasPrefix("tmux") { return .tmux }
            if row.args.contains("iTerm") { return .iTerm }
            if row.args.contains("Terminal.app") { return .terminal }
            current = row.ppid
            hops += 1
        }
        return .unsupported
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
