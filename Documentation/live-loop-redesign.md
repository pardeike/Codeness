# Goal-directed orchestration

Status: implemented in Codeness

Origin: UnityBridge intervention, 2026-08-27

## Decision

Codeness starts from one user goal instead of a predefined process. It prepares a working goal, chooses an ordered set of agents and their memory policies, routes each completed turn, reviews strategy periodically, and checks completion against the original goal.

The user configures no template, role preset, or per-repository model matrix. Provider, model, cost, memory, and authority restrictions belong in the goal.

## Product language

The interface uses five connected terms:

- **Goal:** the user's definition of success, restrictions, and authority.
- **Agents:** the visible set of bounded responsibilities Codeness prepared.
- **Turn:** one agent execution.
- **Round:** one pass through every recurring agent.
- **Memory:** the provider conversation an agent retains, shares, or recreates.

The interface says **agent change**, not revision. It does not expose the internal strategic or local-routing roles. Codeness is the subject in explanations: “Codeness reviews the strategy” and “Codeness prepares the next handoff.”

Older source types retain names such as `LiveTeam*`, `member`, `cycle`, and `revision` for persisted compatibility. They are implementation vocabulary, not product copy. Old fixed-process types remain only to decode and adapt saved documents.

## Internal architecture

Two control agents have deliberately different authority. Their source names are retained here because this is an engineering document:

| Internal role | Responsibility | May change strategy? | Sees the user goal? |
| --- | --- | --- | --- |
| Overseer | Creates the working goal and agents, reviews strategy, audits completion | Yes | Yes |
| Coordinator | Evaluates one completed turn and prepares the next local action | No | No |
| Agent | Performs one bounded responsibility | No | No |

The Overseer acts like the strategic controller. It may change the working goal, agent order and responsibilities, targets, schedules, and memory policies. At the same decision point, it may conclude that the fixed user goal is satisfied and the correct setup has no agents because no work remains; that completes the activity. It cannot change the user goal or invent authority absent from it.

The Coordinator is the local manager. It receives the working goal, the completed result, bounded recent handoffs, and the proposed next agent. It may continue, retry once, request a strategy review, or suggest that the goal may be complete. Strategy and completion suggestions always go to the Overseer; the Coordinator cannot set the activity to Paused or Completed. Its response schema contains no strategy edit or final-completion field.

This separation is the main feedback-loop control. Frequent local handoffs cannot repeatedly reinterpret the task. Strategy changes happen only in the less frequent control path that can compare evidence with the original goal.

## User interaction contract

The user creates or opens a project, defines the fixed goal, pauses or resumes work, steers an active agent, and edits the fixed goal. Codeness owns working goals, stage choices, agent setup, routing, review cadence, and completion judgment. After completion, Start Over archives the Codeness activity and returns to the goal editor without changing repository contents.

File > New Project asks for a folder name and location, creates that empty folder, initializes Git, and opens its goal editor. Opening an existing folder also initializes Git when the folder is not already in a repository.

## Start

The first screen contains one question, one goal editor, and Start. A short caption reminds the user to include provider, model, cost, or memory limits.

After Start:

1. Codeness saves the goal.
2. The Overseer creates the first working goal and smallest useful agent setup.
3. Codeness validates and saves that entire setup before creating an agent session.
4. The first eligible agent begins.

Malformed control output leaves the activity paused with the goal intact. Codeness does not invent a fallback setup.

The first control turn must choose a target before any model can interpret the goal. Codeness recognizes one unambiguous, non-negated provider or exact model identifier and uses it for that first turn. Otherwise it uses the first ready target. This is intentionally a small convenience, not a general language-policy parser.

## Agent setup

Each saved setup contains:

- one working goal;
- an ordered list of agents;
- one target and bounded responsibility per agent;
- a target and policy for local work routing;
- a target for future strategy and completion reviews;
- one schedule and one memory policy per agent;
- a reason for the strategy; and
- an identity-based checkpoint naming the next agent.

Schedules are:

- **Once:** retire after one accepted turn.
- **Every round:** remain eligible on each subsequent pass.

A completed Once agent becomes eligible again only if its own responsibility or the working goal changes. Unrelated agent changes do not replay it.

## Normal operation

After each agent turn, Codeness saves the result before asking for the next handoff. The local-routing decision is then saved before Codeness starts another turn. These are separate durability barriers.

The normal path is:

```text
agent turn
    |
    v
saved result
    |
    v
local routing: continue, retry, strategy review, or completion check
    |
    v
saved routing decision
    |
    v
next agent turn or Overseer review
```

One local retry is allowed. Repeated failure becomes strategy evidence rather than an unlimited retry loop. Because only the Overseer sees the fixed user goal, it alone chooses the next internal stage and decides when no work remains.

## Strategy cadence and feedback limits

Strategy review occurs:

- at initial setup;
- after the user changes the goal;
- when local routing requests it;
- after two failures by the same agent;
- when no agent can run;
- after three rounds or twelve agent turns, whichever comes first, provided ten minutes have passed since the previous strategy review; and
- before completion.

Automatic strategy changes apply only between turns. A running turn retains the exact assignment, working goal, and memory binding it started with.

Pause lets the running agent finish and saves the local-routing handoff, but it does not start an Overseer review from that handoff. Any pending strategy or completion review becomes the durable Resume checkpoint and runs only after the user resumes.

The turn list marks each applied strategy revision with a compact chapter divider before the affected agent turns. Its Info popover shows the structural summary, reason, and evidence. This is a transparency surface, not an approval point.

Elapsed time is a cooldown, never a trigger. Codeness has no strategy-review timer. Fast rounds keep accumulating until the next turn boundary after the cooldown expires. A goal change, repeated failure, unrunnable setup, or completion claim bypasses the periodic cooldown because waiting cannot improve those decisions. The round limit, turn limit, cooldown, and repeated-failure threshold are internal orchestration values, not another user-facing settings form.

The user may change the fixed goal at any time. A running agent finishes against its immutable assignment, then the Overseer revises the strategy against the changed goal before another agent starts.

## Memory choices

| Product choice | Behavior | Normal use |
| --- | --- | --- |
| Own memory | Reuse one private provider conversation | Long-running implementation or specialist work |
| Fresh every turn | Start a new conversation each time | Independent review or audit |
| Shared memory | Reuse one conversation across compatible agents | Closely coupled responsibilities that benefit from shared context |

Shared memory requires the same provider and model. Autonomous agents always use normal execution mode because independent reviewers still need test, shell, and desktop-tool access. Codeness never merges, clones, or forks provider histories. Moving an agent into a shared group adopts that group's conversation. Moving it out starts a new private conversation.

Session-level instructions are role-neutral because several compatible agents may use one shared conversation. Every turn supplies the current agent name, responsibility, working goal, round, and handoff. Implementation and independent review do not share by default.

The two control roles use fresh bounded invocations. Their durable memory is Codeness state, not a long provider conversation.

## Completion

Local routing can only suggest that the goal may be complete. Codeness then activates the Overseer with the fixed user goal and bounded durable evidence, using the same strategic decision point that can keep or replace the agents.

The Overseer may:

- keep the current agents;
- replace the working goal or agent setup;
- complete the activity when the fixed user goal is satisfied and no agents are needed.

This makes stopping the loop a strategic setup decision owned by the only control role that sees the fixed user goal. Older saved completion-review checkpoints remain recoverable, but new work does not create them.

The user can pause and later resume at a durable checkpoint. Working goals, agent instructions, handoffs, strategies, and stage gates are project documents that the Overseer may revise; they cannot create a user-approval requirement. Older saved strategy-direction pauses are repaired to an autonomous Overseer checkpoint without presenting a direction alert.

## Existing documents

Active documents from the fixed-process version adapt automatically on open:

1. Codeness pauses scheduling.
2. The old configuration, cursor, sessions, goal, and bounded evidence are supplied once to the strategic control path.
3. Codeness validates and saves the resulting agents.
4. The old active configuration fields are removed.
5. The document remains paused until Resume.

There is no migration choice, offer, or button. If no usable goal exists, Codeness asks only for the goal. A failed attempt preserves the old paused activity and Resume retries adaptation; it never falls back to new work through the old engine.

An old conversation is retained only when the agent identity, responsibility, target, and Own-memory policy remain compatible. Completed and cancelled old activities remain readable history.

## Removed product surface

The prototype deletes:

- built-in process JSON and its catalog loader;
- process and prompt-template editors;
- restore-built-in controls;
- repository role/model presets;
- manual agent, memory, strategy-review, and review-before-apply controls;
- process choice at activity start; and
- migration buttons and persisted migration-request flags.

The Settings window now contains only agent-provider discovery, the optional OpenAI-compatible endpoint, and transcript presentation.

## Persistence and recovery

- A turn owns an immutable launch setup, agent snapshot, working goal, and memory binding.
- A pending goal or automatic agent change becomes authoritative only after it is saved.
- A crash during a turn recovers against that turn's launch snapshot.
- A removed active agent may finish because its running turn owns the old snapshot.
- Provider sessions are released only when no saved turn, checkpoint, or agent references them.
- Codeness never silently combines two saved setups or provider histories.
- Reopening active work pauses it until the user resumes.

New goal-only records omit irrelevant legacy prompt defaults and false completion fields. Existing saved control text is normalized on load so old internal role names do not leak back into the interface. User goals and agent results are never rewritten.

## Isolated prototype

The development build is deliberately separate from production:

- app: `/Applications/Codeness Prototype.app`;
- bundle ID: `ap.codeness.prototype`;
- state: `/Users/ap/Library/Application Support/Codeness Prototype`; and
- no `.codeness` document registration.

The prototype build script refuses to replace the app while it is running. The production app and `/Users/ap/Library/Application Support/Codeness` were not rebuilt, quit, edited, or relaunched during prototype work.

## Demo evidence

The first goal-only demo asked for a native Go maze-chase game while leaving the graphics library open and restricting every Codeness agent to Codex `gpt-5.6-terra`.

The builder selected Ebitengine, implemented the app and deterministic logic tests, built a native Apple-silicon bundle, and launched it. A fresh reviewer found a real defect the builder missed: one enemy started inside a wall. It fixed the start tile, added a regression test, reran focused and full Go tests, rebuilt, and relaunched the app. Local routing nominated completion and a fresh completion audit accepted it.

The automated evidence was independently rechecked: `go test ./...`, race detection, `go vet`, and `make build` passed. A native 640×682 macOS window was observed and then quit. Keyboard movement and complete win, loss, and restart interaction were not manually proved.

The test found four important weaknesses:

1. The initial structured-output schema made a nullable field optional instead of required-with-null. Codex rejected it correctly. The schema and error propagation are fixed and tested.
2. The first prototype had a hidden Terra preference for the initial control turn. Every saved target happened to use Terra, but that did not prove the goal caused the choice. The hidden default was removed and explicit, negated, and absent-model cases are tested.
3. The builder contacted the public Go module proxy despite “do not use external services” and omitted that fact from its report. Prompts now demand disclosure and positive evidence for prohibitions, but this remains soft enforcement.
4. A later read-only compliance agent could not inspect Codeness's own target and session records. It correctly refused to certify Terra-only history or absence of publication. A bounded read-only control-evidence surface remains future work.

A manual strategy review then replaced the completed builder and reviewer with one fresh compliance agent, proving that the agent setup can change substantially without a template. That review also found and fixed a decoding issue: Keep and Pause now ignore stray strategy fields; only an explicit strategy-change action can alter the setup.

A second demo deliberately reused the same 2D repository with a new, ambiguous “make it 3D” goal. Codeness expanded the goal into genuine real-time 3D acceptance criteria and chose a persistent build agent plus a fresh independent reviewer. The builder replaced the flat presentation with a perspective renderer, built a native bundle, and successfully used BrrainzTools to launch and interact with it. This proves that ordinary prototype agent sessions received the expected shell environment and desktop tooling.

The independent reviewer then exposed two Codeness defects. It was assigned Codex Plan mode, which made the turn read-only and prevented Go from creating work directories, GUI launch from obtaining a usable window context, and `command -v brrainztools` from finding the desktop tool. This was not a shell-setup regression: the prototype App Server had `/Users/ap/Scripts` on `PATH`, and the standard-mode builder used the same BrrainzTools executable successfully. Autonomous target selection and editing now omit Plan mode, saved active Plan targets normalize to Standard, and their read-only provider sessions are discarded before reuse.

Codex nevertheless completed the review as a `plan` item and found a concrete unreachable objective tile. Codeness had accepted only final agent messages, so it displayed the completed review as Failed with “Codex turn ended with status completed.” Plan items are now accepted as terminal output when no agent message exists. The exact persisted failure shape repairs on open to a paused, handoff-pending result without replaying the reviewer or hiding the finding.

The user's pause did succeed: the activity and pause flag were durable and no turn remained active. The misleading Failed badge came from terminal-output classification, not from continued work. The 3D goal remains incomplete because the review found a real game defect and current-bundle interaction evidence was stale. That is a valid review outcome, not a failed review turn.

## Honest assessment

Removing predefined processes is the right product direction. It makes Codeness simpler to start, lets long work adapt, and turns the successful UnityBridge intervention into a normal capability. Separating strategic control from local routing is essential; without it, every handoff could rewrite strategy and create a feedback loop.

The current prototype is not ready to replace production without further work:

- Model, authority, and action restrictions are mostly natural-language policy. The first-target selector handles only one clear provider or exact model. Important prohibitions still need independently observable evidence or hard enforcement.
- An ambiguous goal can be expanded aggressively. The 3D demo working goal added audio, settings, menus, icon, packaging, and exhaustive interaction checks from “everything such an app should have.” That may be sensible, but it also shows how easily Codeness can manufacture scope.
- A poor strategic controller can choose too many agents, the wrong working goal, or needless reviews. Change history and churn limits make this visible but do not remove judgment risk.
- Round-based review can still be too frequent when agents finish almost instantly. A ten-minute cooldown now rate-limits only automatic periodic review; the useful value needs measurement from real runs.
- Control invocations add cost even for one-agent tasks.
- The first demo's two worker sessions reported roughly 902,000 and 579,000 cumulative tokens. Much of that is provider-global context, skills, and tool history rather than Codeness handoffs. Dynamic agents do not solve provider-level context loading.
- Saved decisions improve explainability, but the same goal can still produce a different setup on another run.
- Shared memory weakens independence and should remain rare.
- `RepositoryCoordinator.swift` has absorbed too much live-orchestration logic. The prototype works, but this file should be split by responsibility before production adoption.
- The UI overlap reported on the second demo came from macOS scroll-edge material covering the transcript header. Forcing a hard edge stopped the original overlap but produced a large blank material strip. The final prototype disables the transcript's top edge effect and gives the compact header its own stable background. Live capture shows the complete header during both completed and running turns.
- Successful steering messages are now recorded in the ordered transcript. They appear as indented accent-colored `You steered` blocks, remain visible when routine reasoning is hidden, and return subsequent agent output to normal styling. Failed sends do not create a transcript entry.

The highest-value next work is not more configuration. It is better evidence: a small read-only activity record for audit agents, measured strategy-review outcomes, and hard enforcement only for restrictions that repeatedly prove too important for prompt interpretation.

## Non-goals

This prototype does not add parallel agents, branches, dependency graphs, nested loops, a visual graph editor, a prompt language, or arbitrary agent code. One ordered set of agents with Once and Every-round schedules is enough to test the core design.
