# Codeness

Codeness is a native macOS supervisor for configurable coding-agent workflows in a Git repository window. Every step can independently use Codex or Claude, choose that provider’s model and reasoning effort, run in native read-only Plan mode, and request the provider’s Fast mode. A configured coordinator prepares conservative handoffs and decides when a repeating workflow has satisfied its full goal.

## Requirements

- macOS 15 or newer on Apple silicon
- Xcode 27
- XcodeGen
- At least one of:
  - `codex` CLI 0.145.0 or later, with App Server support
  - Claude Code CLI 2.1.220 or later

OpenAI API credentials are not required for new configurable workflows. They remain supported only so activities created by older Codeness versions can resume their legacy relay.

## Build

```sh
xcodegen generate
xcodebuild -project Codeness.xcodeproj -scheme Codeness -destination 'platform=macOS' build
xcodebuild -project Codeness.xcodeproj -scheme Codeness -destination 'platform=macOS' test
```

The canonical completion build is deliberately quiet and installs the verified Release bundle locally:

```sh
./scripts/build-quiet.sh
```

It stages and verifies the signed product, replaces `/Applications/Codeness.app`, and verifies the installed bundle before reporting success.

The generated Xcode project is intentionally ignored. Project settings live in `project.yml`.

## Workflow

On launch, Codeness restores the repository folders that were open when it quit. If there are none, it immediately presents the standard folder Open panel; cancelling leaves the app running without an otherwise-empty launcher window. File > Open Repository and Open Recent create and manage ordinary repository windows, and reopening an already-open folder focuses its existing window.

The exact folder selected in the Open panel is the Codeness workspace and the working directory for every configured agent step. Selecting a nested folder does not silently replace it with the parent Git root. Different subfolders of one Git working tree can therefore be opened as independent Codeness windows with separate sessions and histories.

Repository folders are never opened as `NSDocument` file URLs. Codeness owns ordinary `NSWindow` controllers plus its own Open Recent and restoration state, so AppKit's document autosave and safe-save machinery has no repository document it could write, replace, move, or delete. File > Save persists only Codeness metadata under Application Support.

An unstarted repository window shows a multiline Goal and a reusable workflow. The Goal may describe work directly, point the agents at a specification file or folder, or combine both. Codeness supplies the complete text to every turn in a clearly delimited `THE GOAL` context block. The selected library workflow is copied into the activity, where its steps and targets can be customized without changing the reusable original.

Application Settings owns independently optional Codex and Claude executable paths. Empty values enable automatic discovery. A non-empty value is authoritative and is applied only after the CLI has been verified and its provider has restarted successfully; active turns for that provider prevent a restart. Codex-only and Claude-only installations remain usable when the other CLI is absent.

Workflows have three ordered sections:

- **Before loop** steps run once. A read-only Plan step normally belongs here.
- **Repeating loop** steps all run in order. Only after its final step does the coordinator decide whether the full goal is complete or another complete cycle is required.
- **After completion** steps run once after the loop is declared complete.

The bundled workflow library contains **Implement / Review / Fix**, **Code / Review**, and **Plan + Implement / Review / Fix** presets. Application Settings can edit or reset a bundled preset, duplicate it, or create and delete custom workflows. Each workflow stores its step names, instructions, topology, coordinator instructions, and all agent targets. A target consists of provider, arbitrary model identifier or known alias, optional effort, Standard or read-only Plan mode, and Standard or Fast speed.

Each step owns a persistent provider session lineage. Its session is reused each time that step repeats. Changing effort or speed while an activity is paused keeps the lineage; changing provider, model, or mode starts a new lineage so incompatible context is never silently resumed. The workflow’s topology, names, and instructions are frozen after the activity starts. A paused or completed activity remains visible so every run transcript can be revisited. **Start Over** archives the activity under Application Support, clears its old agent sessions, and returns the same window to editable configuration with the previous Goal and workflow prefilled. Repository files are unchanged.

The configured coordinator target can itself be Codex or Claude with its own model, effort, mode, and speed. It receives only a completed step’s final answer plus the full-goal and next-step context. It returns a strict structured envelope containing a conservatively filtered handoff, an explicit workflow outcome, and a concrete run label. Completion returned anywhere except the last repeating step is normalized to Continue. If coordination fails or reports Blocked, Failed, or Unclear, the workflow pauses and lets the user retry or supply an edited handoff.

Codex runs through its shared App Server. Claude runs through its streaming JSON CLI protocol, including session resume, partial output, usage, approvals, questions, steering, and interruption. Plan mode uses each CLI’s native read-only behavior. Fast mode is resolved from provider capabilities at run time: Codeness does not persist a hidden service-tier identifier or silently substitute another model.

Codex models and service tiers come from App Server’s live model catalog. Claude model aliases, resolved model names, supported effort levels, and Fast eligibility come from Claude’s initialize handshake. The bundled Claude entries are only a startup fallback if that read-only discovery handshake is unavailable.

The sidebar groups runs as Before Loop, Cycle N, and After Completion; retries remain in their original cycle. Only run rows are selectable. The current live row carries a spinner. Selecting a run shows a reasoning-first semantic transcript. Reasoning, Actions, and Diagnostics can be shown or hidden independently; the recommended default hides successful action chatter while retaining failures. Once the exact final answer exists, it moves into a separate, independently scrollable lower pane—the source sent to the coordinator—so it remains readable while earlier reasoning is inspected. Successful tool output remains suppressed, while append-only transcripts and token-usage checkpoints are stored for crash recovery. When the selected live transcript is still at the bottom, Codeness follows automatically to the next run. Selecting an older run or scrolling upward disables that automatic switch until the live transcript’s bottom is restored.

Closing a window with active work asks Codeness to steer the active provider toward the nearest coherent stopping point. A progress sheet lets you keep waiting or use **Interrupt Now**, the eager equivalent of Ctrl-C. The window closes only after the terminal turn state and a typed resume checkpoint have been saved. Quitting applies the same foreground-only process to all active repository windows and then stops all app-owned providers; nothing continues in the background. Reopened windows remain paused until Resume is explicitly selected. Codeness reconnects the saved step session, recovers an interrupted run without blindly replaying completed edits, retries only a pending handoff, or starts the already-known next step as appropriate.

Each repository also restores its window frame, sidebar geometry and visibility, selected run, per-run transcript reading position, follow-at-bottom state, and Pause After Current setting. **File > Save** (`⌘S`) explicitly flushes this state, although normal changes are autosaved continuously.

Activities saved by older Codeness versions retain their original Implement / Review / Fix state machine, two Codex threads, and OpenAI Responses API relay configuration. This compatibility path is preserved for recovery but is no longer used when creating an activity.

The toolbar can pause after the current handoff, steer or interrupt a running turn, jump back to the live run without disturbing an older selected run, and—while paused—change provider, model, effort, mode, and speed for future steps. Codex and Claude approval and user-input requests are surfaced through the same repository interaction sheet and queued if more than one arrives before the first is answered or resolved.

Codeness does not create worktrees, stash changes, commit, reset, or write its own files into the target repository. It stores orchestration metadata, open-window restoration, window and transcript view state, transcripts, and raw recovery logs under `~/Library/Application Support/Codeness`. App-wide preferences remain ordinary macOS preferences.
