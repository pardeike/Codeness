<div align="center">
  <img src="Sources/CodenessApp/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="112" height="112" alt="Codeness app icon">
  <h1>Codeness</h1>
  <p><strong>Supervise repeatable Codex, Claude, and OpenAI-compatible workflows from one native macOS window.</strong></p>
  <p>Give Codeness a goal, choose a workflow, and let specialized agent sessions implement, review, and refine the work until the whole goal is complete.</p>
</div>

![A completed Implement, Review, and Fix workflow in Codeness](Documentation/codeness-workflow.png)

Codeness is a workflow supervisor—not another coding agent. It coordinates your locally installed Codex and Claude Code CLIs and can also call any configured OpenAI-compatible Chat Completions endpoint inside the work folder you choose. Each step's session stays alive across cycles, with one place to follow, pause, steer, and resume the work.

## Why Codeness?

- **Use the right agent for each step.** Mix Codex, Claude, and an OpenAI-compatible endpoint, models, reasoning effort, native read-only Plan mode, and Fast mode within one workflow.
- **Build review into the process.** Run an implementation/review/fix loop until a coordinator determines that the complete goal—not merely the latest task—is finished.
- **Keep the work observable.** Inspect reasoning, actions, diagnostics, final answers, handoffs, timing, and token usage for every run.
- **Pause without losing the thread.** Persistent step sessions, saved checkpoints, and crash recovery make long-running work practical.
- **Stay in control of the repository.** Codeness does not create worktrees, stash, commit, reset, or add orchestration files to your project.

## How it works

A workflow has up to three ordered sections:

```text
Before loop (once)     Repeating loop                         After completion (once)
┌───────────────┐      ┌───────────────────────────────┐      ┌───────────────────────┐
│ Plan          │ ───▶ │ Implement → Review → Fix  ↻   │ ───▶ │ Finalize, report, …   │
└───────────────┘      └───────────────────────────────┘      └───────────────────────┘
```

After every step, a configurable coordinator creates a conservative handoff for the next agent. At the end of a repeating cycle, it decides whether the full goal is complete, another cycle is needed, or the workflow should pause for your input.

Codeness includes three ready-to-use workflows:

| Workflow | Shape | Good for |
| --- | --- | --- |
| **Implement / Review / Fix** | Implement → Review → Fix ↻ | Careful, iterative development with a dedicated correction pass |
| **Code / Review** | Code → Review ↻ | A leaner alternation between implementation and read-only inspection |
| **Plan + Implement / Review / Fix** | Plan → (Implement → Review → Fix) ↻ | Larger work that benefits from a read-only planning pass first |

Every bundled workflow can be edited, duplicated, or used as the starting point for a custom workflow.

The current template model freezes workflow structure after an activity starts. A design proposal replaces it for
new activities with a fixed user goal, an overseer-created working goal, and a live ordered loop that can change at
safe boundaries while work is running. See [Live loop editing redesign](Documentation/live-loop-redesign.md).

## Get started

### Requirements

To run Codeness:

- macOS 15 or newer on Apple silicon
- At least one supported agent:
  - `codex` 0.145.0 or newer, with App Server support
  - Claude Code with the stream-JSON initialization protocol used by Codeness
  - An OpenAI-compatible Chat Completions endpoint and model. Configure its endpoint and optional JSON API-key source in Settings. Codeness supplies the OpenCode-style core tools `bash`, `read`, `glob`, `grep`, `edit`, and `write`; Plan mode advertises only the read-only subset.

To build Codeness from source, you also need Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38.0 or newer. The canonical Release install additionally requires a Developer ID Application certificate for team `W65292CD8T` and a `notarytool` Keychain profile. The default profile is `brrainz-notary`.

Codeness uses the existing authentication of each CLI. OpenAI-compatible credentials are read from the configured JSON key file and property, or can be omitted for an unauthenticated local endpoint; Codeness does not store the key itself.

### Permission preflight

Choose **Codeness → Check Permissions…** to review the macOS capabilities a workflow may use. Opening the window, returning to Codeness, and selecting **Refresh** perform passive checks only. A confirmed capability shows a disabled **Granted** or **Verified** button. A macOS permission prompt can appear only after you explicitly select **Request Access** for Accessibility or Screen Recording. A previously denied screen-recording request opens the matching Privacy & Security pane because macOS will not prompt for it again.

The preflight is deliberately conservative:

- Full Disk Access is shown as **Access Verified** only when Codeness can open a protected probe file without reading it. Every other result is **Not Verified**, because macOS does not expose a precise status API.
- Files & Folders is granted on demand for individual protected locations.
- Accessibility and Screen Recording use precise public status and request APIs.
- System Audio Recording is a separate privacy service. macOS does not expose a public status or generic request API for it, so Codeness links to its own Privacy & Security pane without treating a screen grant as proof of audio access.
- Automation is managed separately for each target app. Developer Tools and App Management must be verified in System Settings.

Only grant capabilities needed by your workflows. Codeness does not preflight or request microphone, camera, contacts, calendars, notifications, input monitoring, or local-network access.

If System Settings asks to reopen Codeness after a privacy change, do that before starting a long unsupervised workflow.

### Build and install

```sh
git clone https://github.com/pardeike/Codeness.git
cd Codeness
./scripts/build-quiet.sh
open /Applications/Codeness.app
```

The build script generates the Xcode project, creates a hardened Release build with its Apple Events entitlement, re-signs it with the Keychain's Developer ID and a trusted timestamp, submits it to Apple's notary service, staples the accepted ticket, verifies it with Gatekeeper, and then installs it at `/Applications/Codeness.app`. The installed app is replaced only after all pre-installation checks pass. Debug builds continue to use development signing. The generated `.xcodeproj` is intentionally ignored; project settings live in `project.yml`.

Use `CODENESS_CODESIGN_IDENTITY` to select a different Developer ID identity and `CODENESS_NOTARY_PROFILE` to select a different saved `notarytool` profile. If either item lives outside the user's Keychain search list, provide its Keychain path through `CODENESS_CODESIGN_KEYCHAIN` or `CODENESS_NOTARY_KEYCHAIN`. Credentials and Keychain passwords are never stored in the repository or passed on the command line.

### Run your first workflow

1. Open Codeness and choose the folder in which the agents should work. Git is optional.
2. Describe the complete outcome in **Goal**. You can also point to a specification file or folder.
3. Pick a bundled workflow.
4. Optionally choose **Customize…** to change steps, providers, models, modes, effort, or speed.
5. Select **Start** and follow the runs in the sidebar.

The folder you select is used exactly as chosen—it is not silently replaced by a parent Git root. This makes it possible to open different subfolders of the same working tree as independent Codeness workspaces.

## During a run

Each workflow step owns a persistent provider session. When the step repeats, its existing lineage resumes with the context it has already accumulated.

- The sidebar groups runs by **Before Loop**, cycle, and **After Completion**.
- Each run exposes a reasoning-first transcript with independently hideable reasoning, actions, and diagnostics.
- The final answer appears in a separate pane and is the source passed to the coordinator.
- **Pause After Current** stops cleanly after the current handoff.
- You can steer or interrupt an active turn, then resume from the saved checkpoint.
- While paused, you can adjust the provider, model, effort, mode, and speed of future steps.
- Agent tool and file operations run without approval prompts in both Standard and Plan mode. Genuine questions and other user-input requests still appear in the native interaction sheet.

Changing only effort or speed preserves a step's session lineage. Changing its provider, model, or mode starts a new lineage so incompatible context is never silently resumed.

## Customize workflows

Open **Codeness → Settings** to manage reusable workflows, agent executable paths, and the OpenAI-compatible endpoint. You can also set its display name—for example, `Koala`—so it is shown in provider labels throughout the app. Automatic CLI discovery is used when an executable path is empty; a configured path is authoritative after Codeness verifies it and restarts that provider. API keys are read from the configured JSON key file and property, or authentication can be omitted for local endpoints. OpenAI-compatible tool loops are stopped only after the same command and output repeat 16 times without new activity; any new activity resets that detector.

Every step and coordinator target can independently configure:

| Setting | Options |
| --- | --- |
| Provider | Codex, Claude, or OpenAI-compatible |
| Model | A discovered model or an explicit model identifier |
| Effort | Any effort level supported by that model |
| Mode | Standard or native read-only Plan mode |
| Speed | Standard or provider-supported Fast mode |

Codex models and service tiers come from the running App Server's model catalog. Claude aliases, resolved models, effort levels, and Fast eligibility are discovered through Claude Code's initialization handshake. OpenAI-compatible model identifiers are entered directly because model catalogs and capabilities vary by server.

## Repository and data boundaries

Codeness itself does not create worktrees, stash changes, commit, reset, or write orchestration files into the selected repository. Agent processes and compatible-provider tools are not sandboxed: the selected repository is their initial working directory, but Standard-mode agents can run commands and access absolute paths with the same account-level access as Codeness. Plan mode removes mutating compatible-provider tools.

Workflow state, transcripts, recovery logs, and window state are stored under:

```text
~/Library/Application Support/Codeness
```

App-wide preferences use the standard macOS preferences system. **File → Save** flushes Codeness metadata only; it never treats the repository as a document to replace or safe-save.

### Moving a workspace to another Mac

Choose **File → Export Workspace…** to create a single Finder-native `.codeness` file. If work is running, Codeness first pauses it at a coherent checkpoint. The file contains the workspace's goal, workflow, run history, transcripts, recovery checkpoints, and window state. It does not contain the selected repository, provider authentication, CLI installations, or app-wide preferences.

On the other Mac, double-click the file or choose **File → Import Workspace…**. Codeness automatically uses the original repository path when that folder exists; otherwise it asks you to locate the repository. Imported work opens paused, and provider sessions start fresh because provider session identifiers are local to the exporting Mac. If Codeness state already exists for the selected repository, it asks before replacement and first saves the existing state as another `.codeness` file under `~/Library/Application Support/Codeness/Import Backups`.

## Recovery and lifecycle

Codeness continuously saves enough state to recover long-running activities:

- Closing a window with active work first asks the provider to stop at the nearest coherent point.
- **Interrupt Now** provides an eager stop when waiting is not appropriate.
- A window closes only after the terminal turn state and resume checkpoint are saved.
- Quitting applies the same process to all active repository windows and stops app-owned providers; work never continues invisibly in the background.
- Reopened activities remain paused until you explicitly resume them.
- **Start Over** archives the old activity, clears its agent sessions, and returns to an editable copy of the previous goal and workflow. Repository files remain untouched.

Repository windows, sidebar geometry, selected runs, transcript reading positions, and follow-at-bottom state are restored between launches.

<details>
<summary><strong>Coordinator and handoff details</strong></summary>

The coordinator can use Codex, Claude, or an OpenAI-compatible provider with its own model, effort, mode, and speed. It receives the completed step's final answer together with the full goal and next-step context, then returns a structured result containing:

- a conservatively filtered handoff;
- the workflow outcome; and
- a concrete label for the completed run.

A completion result is honored only after the final repeating step. Coordination failures and Blocked, Failed, or Unclear outcomes pause the workflow so you can retry or provide an edited handoff.

</details>

<details>
<summary><strong>Provider and transcript details</strong></summary>

Codex communicates through its shared App Server. Claude uses its streaming JSON CLI protocol, including session resume, partial output, usage, approvals, questions, steering, and interruption. OpenAI-compatible providers use Chat Completions, keep session history locally, and expose the OpenCode-style core tool vocabulary, including unrestricted Standard-mode shell execution for builds and tests.

Successful tool chatter is suppressed by default while failures remain visible. Append-only transcripts and token-usage checkpoints are retained for crash recovery. Selecting an older run or scrolling away from the bottom disables automatic following until you return to the live transcript.

Fast mode is resolved from current provider capabilities at run time. Codeness does not persist a hidden service-tier identifier or silently substitute a different model.

</details>

<details>
<summary><strong>Compatibility with older activities</strong></summary>

Activities created by older Codeness versions retain their original Implement / Review / Fix state machine, two Codex threads, and OpenAI Responses API relay configuration. That compatibility path exists only for recovery and is not used for new activities.

</details>

## Development

Generate the project, build, and run the test suite:

```sh
xcodegen generate
xcodebuild -project Codeness.xcodeproj -scheme Codeness -destination 'platform=macOS' build
./scripts/test-quiet.sh
```

Before considering a change complete, run the canonical Release build:

```sh
./scripts/build-quiet.sh
```

It must finish by installing and verifying `/Applications/Codeness.app`.
