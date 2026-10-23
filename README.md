# PromptSchedule

A small macOS app for queueing prompts and sending them to one or more running
[Claude Code](https://claude.com/claude-code) sessions in Terminal.app.

## Features

- **Session picker** – lists the interactive `claude` sessions running in Terminal tabs
  (refreshed every few seconds); select one or several.
- **Prompt queue** – add prompts to a table, then send them in order. Each target session
  has its own status (queued / sending / sent / failed) and failed sends can be retried.
- **Reframe ✨** – rewrites a rough prompt into a clearer, better-structured one using
  `claude -p`, shown side by side with the original so you can edit, accept or keep the original.
- The queue is saved with SwiftData and survives restarts.

## How sending works

The app finds the Terminal tab whose tty matches the session, pastes the prompt
(bracketed paste keeps multi-line prompts together) and presses Return. Your clipboard
is restored afterwards. Prompts are delivered one at a time.

## Requirements

- macOS 26.5+, Xcode 26
- Claude Code CLI installed (`claude` in `~/.local/bin`, Homebrew, or on your PATH)
- Sessions must run in **Terminal.app**

On first send macOS will ask for permission to control **Terminal** and **System Events**
(Automation) and for **Accessibility** access. App Sandbox is disabled because the app
runs `ps`, `lsof`, `osascript` and `claude`.
