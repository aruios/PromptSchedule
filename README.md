# PromptSchedule

A small macOS app for queueing prompts and sending them to one or more running
[Claude Code](https://claude.com/claude-code) sessions.

## Features

### Free
- **Session picker** – lists the interactive `claude` sessions running in Terminal.app, with a
  live idle / busy dot; select one or several.
- **Prompt queue** – add prompts to a table and send them in order. Each target session has its
  own status (queued / sending / sent / failed) and failed sends can be retried.
- **Reframe ✨** – rewrites a rough prompt into a clearer one using `claude -p`, shown side by side
  with the original so you can edit, accept or keep the original.

### Premium (switch at the top of the window)
- **Autopilot** – sends queued prompts automatically. Each session gets its next prompt only once
  Claude has finished the previous one, so you can line up work and walk away.
- **Scheduling** – send at a set time, once or every hour / day / weekday / week.
- **Prompt templates** – reusable prompts with `{{placeholders}}`. `{{folder}}`, `{{branch}}`,
  `{{cwd}}`, `{{date}}` and `{{time}}` are filled in per session when sent; any other placeholder
  is asked for when the template is used.
- **Reframe styles** – Concise, Step-by-step plan, Bug report, or your own custom instructions.
- **Done notifications** – a notification with the result note when a session finishes your prompt,
  with Show Result and Follow Up buttons.
- **iTerm2 and tmux sessions** – in addition to Terminal.app.
- **Menu bar quick send** and a global shortcut, **⌃⌥⌘P**, to send from anywhere.
- **Task results** – each prompt is followed until Claude finishes. The queue's Result column
  shows a short note on the outcome (Done / Needs your input / Waiting for permission /
  Interrupted); click it for Claude's full reply, with Copy, Show in Terminal and Follow Up.
  Results come from Claude Code's transcripts, survive restarts and follow continued sessions.
  Optional: AI-written notes (Claude Haiku via `claude -p`) and Claude Code `Stop` /
  `Notification` hooks for instant results — both in Settings (⌘,).

Premium is currently a simple on/off switch; licensing comes later.

## How sending works

Prompts are written straight into the session's input in the background, wrapped in
bracketed-paste markers so a multi-line prompt arrives as one message, then submitted.
The terminal is never brought to the front.

- **Terminal.app** – `do script … in <tab>` on the tab whose tty matches the session.
- **iTerm2** – `write text` on the matching session.
- **tmux** – `tmux paste-buffer -p` into the pane, then Enter.

Idle / busy status and the last reply come from the files Claude Code keeps in
`~/.claude/sessions/` and `~/.claude/projects/`.

## Requirements

- macOS 26.5+, Xcode 26
- Claude Code CLI installed (`claude` in `~/.local/bin`, Homebrew, or on your PATH)

On first send macOS asks once for permission to control **Terminal** / **iTerm2** (Automation).
Prompts are delivered in the background: the terminal stays where it is, and the clipboard and
keyboard aren't touched. App Sandbox is disabled because the app runs
`ps`, `lsof`, `osascript`, `tmux` and `claude`, so it is distributed outside the Mac App Store.

## Building a release

```sh
Scripts/release.sh
```

Archives the app and creates `build/release/PromptSchedule-<version>.dmg`. With a
**Developer ID Application** certificate and a saved `notarytool` profile it also signs,
notarizes and staples the .dmg so it can be sold and downloaded; see the top of the script.
Without them it makes a local test build.

`Scripts/make_icon.swift` regenerates the app icon artwork.
