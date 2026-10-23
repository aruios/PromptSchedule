//
//  PromptScheduleTests.swift
//  PromptScheduleTests
//
//  Created by Arun Madasamy on 10/23/26.
//

import Foundation
import Testing
@testable import PromptSchedule

// MARK: - Transcript fixtures

/// Builds transcript lines shaped like Claude Code's `.jsonl` entries.
private enum Line {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func ts(_ seconds: Double) -> String {
        start.addingTimeInterval(seconds).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
            .replacingOccurrences(of: "+0000", with: "Z")
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func prompt(_ text: String, at s: Double, sidechain: Bool = false) -> String {
        json(["type": "user", "timestamp": ts(s), "isSidechain": sidechain,
              "message": ["role": "user", "content": text]])
    }

    static func toolResult(at s: Double) -> String {
        json(["type": "user", "timestamp": ts(s),
              "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]])
    }

    static func assistant(_ text: String?, toolUse: Bool = false, stop: String?, at s: Double, sidechain: Bool = false) -> String {
        var blocks: [[String: Any]] = []
        if let text { blocks.append(["type": "text", "text": text]) }
        if toolUse { blocks.append(["type": "tool_use", "name": "Bash", "input": [:] as [String: Any]]) }
        var message: [String: Any] = ["role": "assistant", "content": blocks]
        if let stop { message["stop_reason"] = stop }
        return json(["type": "assistant", "timestamp": ts(s), "isSidechain": sidechain, "message": message])
    }

    static func duration(_ ms: Int, at s: Double) -> String {
        json(["type": "system", "subtype": "turn_duration", "durationMs": ms, "timestamp": ts(s)])
    }

    static func queued(_ text: String, at s: Double) -> String {
        json(["type": "queue-operation", "operation": "enqueue", "content": text, "timestamp": ts(s)])
    }

    static func continued(to id: String, at s: Double) -> String {
        json(["type": "continued-in", "continuedInSessionId": id, "timestamp": ts(s)])
    }
}

// MARK: - TranscriptReader

struct TranscriptReaderTests {
    let prompt = "Fix the build errors in this project\nand run the tests."
    var key: String { TranscriptReader.promptKey(for: prompt) }
    let sentAt = Line.start.addingTimeInterval(100)

    @Test func finishedTurnReturnsFinalReplyAndDuration() {
        let lines = [
            Line.prompt("an earlier prompt", at: 10),
            Line.assistant("Earlier answer.", stop: "end_turn", at: 20),
            Line.prompt(prompt, at: 101),
            Line.assistant("Let me build it.", toolUse: true, stop: "tool_use", at: 105),
            Line.toolResult(at: 130),
            Line.assistant("Fixed 3 errors. All 42 tests pass.", stop: "end_turn", at: 140),
            Line.duration(39_000, at: 141),
        ]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines)
        #expect(turn.promptSeen)
        #expect(turn.finished)
        #expect(!turn.pendingToolUse)
        #expect(turn.reply == "Fixed 3 errors. All 42 tests pass.")
        #expect(turn.durationMs == 39_000)
    }

    @Test func runningToolCallIsNotFinished() {
        let lines = [
            Line.prompt(prompt, at: 101),
            Line.assistant("Running the tests.", toolUse: true, stop: "tool_use", at: 105),
        ]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines)
        #expect(turn.promptSeen)
        #expect(!turn.finished)
        #expect(turn.pendingToolUse)
    }

    @Test func laterPromptEndsOurTurn() {
        let lines = [
            Line.prompt(prompt, at: 101),
            Line.assistant("Done with the build.", stop: "end_turn", at: 110),
            Line.prompt("something the user typed next", at: 200),
            Line.assistant("Unrelated answer.", stop: "end_turn", at: 210),
        ]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines)
        #expect(turn.finished)
        #expect(turn.reply == "Done with the build.")
    }

    @Test func promptInClaudesQueueIsSeenButNotStarted() {
        let lines = [
            Line.prompt("the user's own long task", at: 50),
            Line.queued(prompt, at: 101),
            Line.assistant("Still on the user's task.", toolUse: true, stop: "tool_use", at: 120),
        ]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines)
        #expect(turn.promptSeen)
        #expect(!turn.finished)
        #expect(turn.reply == nil)
    }

    @Test func missingPromptIsNotSeen() {
        let lines = [Line.prompt("a different prompt", at: 101), Line.assistant("Hi.", stop: "end_turn", at: 102)]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines)
        #expect(!turn.promptSeen)
        #expect(!turn.finished)
    }

    @Test func subagentEntriesAreIgnored() {
        let lines = [
            Line.prompt(prompt, at: 101),
            Line.assistant("Delegating.", toolUse: true, stop: "tool_use", at: 102),
            Line.assistant("Subagent finished its part.", stop: "end_turn", at: 110, sidechain: true),
        ]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines)
        #expect(!turn.finished)
        #expect(turn.pendingToolUse)
    }

    @Test func cutWindowTracksFromItsStart() {
        // Our prompt scrolled out of the tail window; everything left is after the send.
        let lines = [
            Line.toolResult(at: 300),
            Line.assistant("Refactor complete.", stop: "end_turn", at: 310),
        ]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines, windowIsCut: true)
        #expect(turn.finished)
        #expect(turn.reply == "Refactor complete.")
    }

    @Test func followsContinuedSessions() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = projects.appendingPathComponent("-Users-me-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projects) }

        try (Line.prompt("old", at: 1) + "\n" + Line.continued(to: "bbb", at: 2) + "\n")
            .write(to: folder.appendingPathComponent("aaa.jsonl"), atomically: true, encoding: .utf8)
        try (Line.continued(to: "ccc", at: 3) + "\n")
            .write(to: folder.appendingPathComponent("bbb.jsonl"), atomically: true, encoding: .utf8)
        try (Line.prompt(prompt, at: 101) + "\n" + Line.assistant("All good.", stop: "end_turn", at: 102) + "\n")
            .write(to: folder.appendingPathComponent("ccc.jsonl"), atomically: true, encoding: .utf8)

        let url = TranscriptReader.transcriptURL(sessionId: "aaa", in: projects)
        #expect(url?.lastPathComponent == "ccc.jsonl")

        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, sessionId: "aaa", in: projects)
        #expect(turn?.finished == true)
        #expect(turn?.reply == "All good.")
    }

    @Test func continuedFileFindsOurPromptAfterAnother() {
        let lines = [
            Line.prompt("the user's own prompt", at: 101),
            Line.assistant("Their answer.", stop: "end_turn", at: 102),
            Line.prompt(prompt, at: 103),
            Line.assistant("Our answer.", stop: "end_turn", at: 104),
        ]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines, startsTracking: true)
        #expect(turn.reply == "Our answer.")
    }

    @Test func continuedFileWithoutOurPromptTracksFromTheTop() {
        // Our prompt is in the previous file; the continuation holds the rest of the turn.
        let lines = [
            Line.assistant("Continuing the refactor.", toolUse: true, stop: "tool_use", at: 120),
            Line.toolResult(at: 130),
            Line.assistant("Refactor finished.", stop: "end_turn", at: 140),
            Line.prompt("a later prompt", at: 200),
            Line.assistant("Later answer.", stop: "end_turn", at: 210),
        ]
        let turn = TranscriptReader.turn(promptKey: key, sentAt: sentAt, lines: lines, startsTracking: true)
        #expect(turn.finished)
        #expect(turn.reply == "Refactor finished.")
    }

    @Test func promptKeyIgnoresWhitespaceDifferences() {
        #expect(TranscriptReader.promptKey(for: "Fix  the\nbuild") == TranscriptReader.promptKey(for: "Fix the build"))
    }
}

// MARK: - NoteMaker

struct NoteMakerTests {
    @Test func stripsMarkdownAndUsesFirstParagraph() {
        let reply = """
        **Fixed** the `login` crash in [AuthView](AuthView.swift) and all tests pass now.

        ## Details
        - changed one line
        """
        #expect(NoteMaker.quickNote(from: reply) == "Fixed the login crash in AuthView and all tests pass now.")
    }

    @Test func shortOpenerIsJoinedWithNextParagraph() {
        #expect(NoteMaker.quickNote(from: "Done.\n\nThe build is clean and 12 tests pass.")
            == "Done. The build is clean and 12 tests pass.")
    }

    @Test func codeBlocksTablesAndHeadingsAreSkipped() {
        let reply = """
        # Summary
        ```swift
        let x = 1
        ```
        | a | b |
        Updated the parser to handle empty lines.
        """
        #expect(NoteMaker.quickNote(from: reply) == "Updated the parser to handle empty lines.")
    }

    @Test func longNotesStopAtASentenceEnd() {
        let reply = "I rewrote the scheduler so repeating prompts keep their last result until the next run starts. "
            + "Then I also updated every view that shows schedules, added tests for weekdays and DST, and cleaned up old code paths."
        let note = NoteMaker.quickNote(from: reply)
        #expect(note == "I rewrote the scheduler so repeating prompts keep their last result until the next run starts.")
    }

    @Test func longNotesWithoutSentencesCutAtAWord() {
        let note = NoteMaker.truncate(String(repeating: "word ", count: 60))
        #expect(note.hasSuffix("…"))
        #expect(note.count <= NoteMaker.maxLength)
        #expect(!note.contains("wor…"))
    }

    @Test func emptyOrSymbolOnlyRepliesGiveNoNote() {
        #expect(NoteMaker.quickNote(from: "") == nil)
        #expect(NoteMaker.quickNote(from: "```\ncode only\n```") == nil)
    }
}

// MARK: - Saved data and helpers

struct ModelTests {
    @Test func targetsSavedBeforeResultTrackingStillLoad() throws {
        let old = #"[{"pid":73648,"tty":"/dev/ttys006","name":"chasal · ttys006","state":"sent"}]"#
        let targets = try JSONDecoder().decode([PromptTarget].self, from: Data(old.utf8))
        #expect(targets.count == 1)
        #expect(targets[0].state == .sent)
        #expect(targets[0].outcome == nil)
        #expect(!targets[0].isTracking)
    }

    @Test func trackingDoesNotDependOnDeliveryState() throws {
        let json = #"{"pid":1,"tty":"/dev/ttys001","name":"x","state":"queued","sentAt":0}"#
        let target = try JSONDecoder().decode(PromptTarget.self, from: Data(json.utf8))
        #expect(target.isTracking)
    }

    @Test func templateValuesAreInsertedLiterally() {
        let filled = TemplateEngine.fill("Open {{file}} now", with: ["file": #"$HOME/a\b {{x}}.swift"#])
        #expect(filled == #"Open $HOME/a\b {{x}}.swift now"#)
    }

    @Test func weekdayRepeatSkipsTheWeekend() throws {
        let calendar = Calendar.current
        let friday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9)))
        let now = friday.addingTimeInterval(3600)
        let next = try #require(RepeatRule.weekdays.next(after: friday, now: now))
        #expect(calendar.component(.weekday, from: next) == 2) // Monday
        #expect(calendar.component(.hour, from: next) == 9)
    }
}
