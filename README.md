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
- **Done notifications** – a notification with Claude's reply when a session finishes your prompt.
- **iTerm2 and tmux sessions** – in addition to Terminal.app.
- **Menu bar quick send** and a global shortcut, **⌃⌥⌘P**, to send from anywhere.

Premium is currently a simple on/off switch; licensing comes later.

## How sending works

- **Terminal.app / iTerm2** – selects the tab whose tty matches the session, pastes the prompt
  (bracketed paste keeps multi-line prompts together) and presses Return. Your clipboard is
  restored afterwards.
- **tmux** – pastes straight into the pane with `tmux paste-buffer -p`; no focus change needed.

Idle / busy status and the last reply come from the files Claude Code keeps in
`~/.claude/sessions/` and `~/.claude/projects/`.

## Requirements

- macOS 26.5+, Xcode 26
- Claude Code CLI installed (`claude` in `~/.local/bin`, Homebrew, or on your PATH)

On first send macOS asks for permission to control **Terminal** / **iTerm2** and **System Events**
(Automation) and for **Accessibility** access. App Sandbox is disabled because the app runs
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
