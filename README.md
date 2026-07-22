# Codeness

Codeness is a native macOS supervisor for one persistent pair of Codex sessions working in one Git repository window. An implementer produces review-sized work units, a reviewer examines each unit, the implementer fixes only those review findings, and a lightweight relay prepares conservative handoffs between the phases.

## Requirements

- macOS 15 or newer on Apple silicon
- Xcode 27
- XcodeGen
- A current `codex` CLI with App Server support
- An OpenAI API key in a JSON file for the handoff relay; the default is `OPENAI_API_KEY` in `~/.api-keys`

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

The exact folder selected in the Open panel is the Codeness workspace and the working directory for both Codex sessions. Selecting a nested folder does not silently replace it with the parent Git root. Different subfolders of one Git working tree can therefore be opened as independent Codeness windows with separate session pairs and histories.

Repository folders are never opened as `NSDocument` file URLs. Codeness owns ordinary `NSWindow` controllers plus its own Open Recent and restoration state, so AppKit's document autosave and safe-save machinery has no repository document it could write, replace, move, or delete. File > Save persists only Codeness metadata under Application Support.

An unstarted repository window shows its activity configuration directly in the main area: a multiline Goal plus separate Implement, Review, and Fix prompt templates. The Goal may describe work directly, point the agents at a specification file or folder, or combine both. Codeness supplies the complete text to every turn in a clearly delimited `THE GOAL` context block. The Review template must contain `{{implementation_output}}`; the Fix template must contain `{{review_output}}`. Application Settings controls the prompt and four model/reasoning defaults copied into a brand-new repository window. Each window keeps an independent, editable copy of its model settings, so changing global defaults never alters an existing window. You may accept or edit the suggested prompts before clicking Start; the Goal and prompts become read-only while that activity exists.

Application Settings also owns the optional Codex executable path because every repository window uses one shared App Server process. An empty value enables automatic discovery. A non-empty value is authoritative and is applied only after it has been verified and the shared server has restarted successfully; active turns prevent that restart instead of leaving the UI and process out of sync.

Each work unit is a strict three-turn group: Implement, Review, then Fix. The Fix turn addresses only review findings and never starts the next work unit. If more work remains, the next group begins with a separate Implement turn. Even an implementation-complete claim receives its final Review and Fix before the activity completes. A paused or completed activity remains visible so every run transcript can be revisited. **Start Over** archives that Codeness activity under Application Support, clears its old session IDs, and returns the same window to editable configuration with the previous Goal and prompts prefilled. Repository files and per-window model settings are unchanged. There is still exactly one current activity and one session pair per repository window.

Each repository keeps two persistent App Server threads. Implement and Fix use the implementer thread but may use different per-turn model and reasoning settings; Review uses the reviewer thread. The configured relay model receives only the completed turn's final answer and a dynamic description of the recipient's next job. It returns a strict structured envelope containing a conservatively filtered handoff, an explicit workflow disposition, and a concrete run label of at most 48 characters. Completed rows use that label in the sidebar instead of remaining generically named Implement, Review, or Fix. There is deliberately no target summary length or compression ratio; uncertain content is retained. If the relay fails, the workflow pauses and lets you retry, edit the handoff, or pass the source final through unchanged.

The sidebar groups each Implement/Review/Fix cycle optically as a work unit; retries remain in the work unit whose phase they retry. Only the run rows are selectable. The current live row carries a spinner. Selecting a run shows a reasoning-first semantic transcript. Reasoning, Actions, and Diagnostics can be shown or hidden independently; the recommended default hides successful action chatter while retaining failures. Once the exact final answer exists, it moves into a separate, independently scrollable lower pane—the source sent to the handoff model—so it remains readable while you scroll through earlier reasoning above. Successful MCP results and successful command output remain suppressed, while raw recovery events are still stored in Application Support. When the selected live transcript is still scrolled to the bottom, Codeness follows automatically to the next run. Selecting an older run or scrolling upward disables that automatic switch until you return to the live transcript and its bottom.

Closing a window with active work asks Codeness to steer the agent toward the nearest coherent stopping point. A progress sheet lets you keep waiting or use **Interrupt Now**, the eager equivalent of Ctrl-C. The window closes only after the terminal turn state and a typed resume checkpoint have been saved. Quitting applies the same foreground-only process to all active repository windows and then stops the app-owned Codex App Server; nothing continues in the background. Reopened windows remain paused until you explicitly click Resume. Codeness reconnects the saved implementer and reviewer thread IDs, then recovers an interrupted pass, retries only a pending handoff, or starts the already-known next phase as appropriate.

Each repository also restores its window frame, sidebar geometry and visibility, selected run, per-run transcript reading position, follow-at-bottom state, and Pause After Current setting. **File > Save** (`⌘S`) explicitly flushes this state, although normal changes are autosaved continuously.

The relay always uses the official `https://api.openai.com/v1/responses` endpoint. Its model and reasoning effort use the same selectors as Implement, Review, and Fix. The relay's API-key JSON file and JSON key also remain configurable per repository; the endpoint itself is intentionally not exposed as a preference.

The toolbar can pause after the current handoff, steer or interrupt a running turn, jump back to the live run without disturbing an older selected run, and configure Implement, Review, Fix, and Handoff model/effort choices independently through one consistent four-row selector. App Server approval and user-input requests are surfaced in the repository window and queued if more than one arrives before the first is answered or auto-resolved.

Codeness does not create worktrees, stash changes, commit, reset, or write its own files into the target repository. It stores orchestration metadata, open-window restoration, window and transcript view state, transcripts, and raw recovery logs under `~/Library/Application Support/Codeness`. App-wide preferences remain ordinary macOS preferences.
