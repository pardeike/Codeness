# Live team redesign

Status: design proposal, not implemented

Origin: UnityBridge workflow intervention and follow-up review, 2026-08-27

## Terms

- **User goal:** The Board's fixed statement of success and authority.
- **Working goal:** The Overseer's stable brief for the current strategic phase.
- **Revision:** One saved version of the working goal, team, and session choices.
- **Safe boundary:** The point after an active agent turn is durably finished and before another one starts.
- **Session lineage:** The provider conversation history retained for future turns.

## Decision

Codeness should stop treating a workflow template as a frozen runtime program. A new activity starts with a user
goal and no predefined steps. A strategic Overseer inspects the goal, repository, available agents, and Codeness
state, then creates the first working goal and team.

The operating model is deliberately similar to a small company:

```text
Board                  Overseer                    Coordinator                  Team
User goal and       -> Strategy, working goal,  -> Local flow, handoffs,    -> Step work
authority              team, sessions, control     escalation                  and evidence
```

- The user is the Board. The user owns the fixed goal and grants authority.
- The Overseer is the CEO and Controller. It sees the user goal, sets strategy, designs the team, chooses session
  policy, audits progress, and confirms completion.
- The Coordinator is the team's manager. It runs after each worker, evaluates local results, prepares handoffs,
  and escalates strategic questions. It cannot redefine the work.
- Each step is a team member with a bounded responsibility.

The user and Overseer can add, remove, move, or edit team members while work is paused or running. An active turn
keeps the exact revision it started with. A new revision takes effect only at a safe boundary.

New activities do not use templates or presets. The legacy decoder and template UI remain temporarily so existing
activities can recover and perform a one-time migration.

This is a major persisted-workflow redesign. It should reuse existing providers, run records, routing,
interruption, and recovery mechanisms, but it must not be implemented as one large replacement.

## Why change it

The current template system starts workflows well and evolves them poorly.

A generic activity stores a complete `WorkflowTemplate`. Its cursor uses a section and array index. Codeness
permits instruction and target changes only while paused, and `RepositoryCoordinator.updateWorkflowPreferences`
rejects changes to workflow identity, names, sections, order, or membership through
`sameFrozenWorkflowTopology`. These restrictions make an index-based scheduler recoverable, but they preserve an
early organizational guess for the life of the activity.

The UnityBridge activity showed the cost. It reached 515 runs with persistent Prepare, Plan, Code, and Review
sessions. Product work was progressing, but repeated loops began improving a disposable audit verifier instead of
UnityBridge. Useful progress resumed only after an external intervention:

1. Pause at a durable checkpoint and quit Codeness.
2. Edit `workspace.json` directly.
3. Replace Prepare, Plan, Code, and Review with Deliver and Review.
4. Assign new step IDs and clear the old session map.
5. Compact the goal and repository state.
6. Reopen while paused, verify recovery, and resume.

The restart was safe, but the repair required knowledge of Codeness's private persistence format. Codeness should
make the same strategic intervention ordinary, visible, and recoverable.

Useful existing foundations include stable step IDs, explicit provider lineage, immutable run snapshots, durable
recovery checkpoints, the pre-start workflow editor, and the paused workflow preference editor. The redesign
changes ownership and scheduling identity around those foundations.

## Authority model

| Role | Sees | May decide | Must not decide |
| --- | --- | --- | --- |
| Board | Everything | User goal, authority, manual changes, approval policy | Agent implementation details unless desired |
| Overseer | User goal, working goal, team, sessions, bounded evidence | Strategy, team structure, session policy, strategic revisions, completion | User-goal amendments or new external authority |
| Coordinator | Working goal, current team, completed result, local history | Result label, next handoff, local retry or pause request, Overseer escalation | User goal, working-goal changes, team changes, session policy, completion |
| Team member | Working goal, own instructions, current handoff | Work and evidence within its responsibility | Strategy, team design, or overall completion |

Codeness enforces these boundaries through separate request and response schemas. Prompt wording alone is not an
authority boundary.

The Overseer and Coordinator are separate invocations with separate prompts. Neither is a visible loop step. The
Coordinator runs frequently. The Overseer intervenes at strategic boundaries.

## Goals and prompt visibility

The user goal states what success means and what the activity is allowed to do. Agents cannot edit it. A user
change creates a recorded Board amendment and triggers Overseer review before work continues.

Among agents, only the Overseer sees the full user goal. It creates a compact working goal that carries the current
scope, success condition, priorities, and every task-specific authority boundary needed by the team. The Board can
inspect the working goal and pin important constraints that the Overseer may not remove.

The working goal is intentionally stable. The Coordinator cannot edit it. The Overseer normally changes it only
when it changes the team, when the Board amends the user goal, or when a strategic milestone makes the old brief
obsolete. A goal-only change is allowed, but it requires an explicit strategic reason and creates a revision.

A team member receives:

```text
WORKING GOAL
The stable scope, success condition, and authority for this strategic phase.

YOUR RESPONSIBILITY
The step's instructions and stopping condition.

HANDOFF
The Coordinator's current local direction.
```

The Coordinator receives the working goal, team, active revision, completed result, bounded local history, and
the next scheduled member. It never receives the user goal.

The Overseer receives the user goal, working goal, team, session state, bounded Coordinator decisions, durable
work evidence, Board steering, and the strategic edit record. It judges strategy and completion against the user
goal, not against its own working goal.

## Starting without templates

Creating an activity asks for the user goal and starts with no working goal or team members. The Board does not
choose a template.

The Overseer runs in Bootstrap mode. It must return:

- a nonempty working goal;
- the smallest team that can make useful progress;
- a Coordinator target and narrow local operating policy;
- a bounded responsibility and stopping condition for each member;
- whether each member runs once or every cycle;
- an agent target and session policy for each member; and
- a short explanation visible to the Board.

Codeness validates and saves that result as revision 1 before creating a worker session. Invalid output leaves the
goal-only activity paused with Retry Overseer and Edit User Goal. There is no partial team or hidden fallback
template.

The product ships one general Overseer policy rather than a catalog of workflow prompts. New activities may
produce different teams because their goals and repositories differ. The saved revision and explanation make the
decision inspectable and reproducible as activity history.

## Live team model

An activity owns:

- the versioned user goal;
- any Board-pinned constraints that the working goal must preserve;
- the current working goal;
- one ordered list of team members;
- one Coordinator target and narrow operating policy;
- one Overseer target and strategic policy;
- a session policy for every team member;
- a current revision and at most one pending revision;
- an identity-based scheduling checkpoint;
- persistent and run-owned session slots; and
- run and edit history recording what each agent actually saw.

There are no Before Loop, Repeating Loop, or After Completion sections. Every member instead has one small run
policy:

```swift
enum StepRunPolicy: Codable, Equatable {
    case once
    case everyCycle
}
```

A Plan member can run once. Implement and Review can run every cycle. When final reporting becomes necessary, the
Overseer can insert a one-time Finalize member. This preserves useful one-time work without restoring workflow
sections or requiring the Overseer to remove a completed planning step.

One illustrative persisted shape is:

```swift
struct LiveTeamDefinition: Codable, Equatable {
    var revision: Int
    var workingGoal: String
    var members: [LiveTeamMember]
}

struct LiveTeamMember: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var instructions: String
    var target: AgentTarget
    var runPolicy: StepRunPolicy
    var sessionPolicy: SessionPolicy
}

enum SessionPolicy: Codable, Equatable {
    case ownMemory
    case sharedMemory(groupID: String)
    case freshEveryRun
}

struct LiveTeamCheckpoint: Codable, Equatable {
    var memberID: String
    var cycle: Int
    var revision: Int
}
```

The names are illustrative. The contracts matter more than these exact types.

## Normal operating cycle

The Coordinator, not the Overseer, manages ordinary flow.

1. Codeness launches the scheduled team member with the current durable revision.
2. The member works and returns a local result with evidence.
3. Codeness persists the completed run against its launch revision.
4. Any accepted Board revision activates at the safe boundary.
5. The Coordinator evaluates the result under the current working goal and team.
6. The Coordinator returns a label, bounded handoff, and local disposition.
7. Codeness either schedules the next eligible member, retries or pauses within policy, or invokes the Overseer.

The Coordinator response is narrow:

```swift
enum CoordinatorDisposition: Codable, Equatable {
    case continueTeam
    case retryCurrent
    case pause
    case requestOversight
    case completionCandidate
}

struct CoordinatorDecision: Codable, Equatable {
    var handoff: String
    var runLabel: String
    var disposition: CoordinatorDisposition
    var evidence: String
}
```

The Coordinator may judge whether one member fulfilled its responsibility. It may request one bounded retry when
the result is locally incomplete. It may pause on failure or ambiguity. It may signal that strategy should be
reviewed or that the working goal appears complete.

The Coordinator cannot return a working-goal update, team patch, session change, or final completion result. The
schema rejects those fields. This keeps frequent local coordination from becoming frequent strategic mutation.

## Overseer responsibilities

The Overseer is the strategic control agent. It runs in a fresh, bounded invocation and reads durable Codeness
state rather than accumulating an unbounded provider conversation.

It runs:

- once to Bootstrap a goal-only activity;
- once to Migrate an older template activity;
- after a Board amendment;
- when the Board selects Review Strategy Now;
- when the Coordinator requests oversight;
- at a periodic control review;
- when repeated failures or an unavailable agent make the team ineffective; and
- whenever the Coordinator reports a completion candidate.

In Strategic Review mode it may:

- keep the current strategy unchanged;
- update the working goal with a recorded reason;
- add, remove, reorder, or rewrite team members;
- change the Coordinator target or narrow local policy;
- change run or session policy;
- reset a session lineage;
- insert a one-time member for a required milestone;
- pause for Board direction; or
- send the unchanged team back to the Coordinator.

Each revision includes the problem observed, concrete evidence, expected improvement, and the revision it was
based on. Codeness validates it through the same transaction used for Board edits.

The Overseer policy is general:

- create the smallest team that can make useful progress;
- keep the working goal stable until strategy actually changes;
- give every member one bounded responsibility and stopping condition;
- preserve every user requirement and authority boundary;
- use one-time members for one-time work;
- remove or rewrite members whose output no longer changes a decision;
- choose the least shared session policy that preserves useful context;
- add a specialist only for a demonstrated missing responsibility;
- judge completion only against the user goal and durable evidence; and
- return no revision when the current team is working.

The UnityBridge acceptance case is a strategic review. The Overseer should have recognized repeated
procedure-only Review failures, replaced Prepare, Plan, Code, and Review with Deliver and Review, reset both
lineages, compacted the working goal, and selected the reusable audit runner as the next bounded milestone. The
Coordinator would then manage ordinary Deliver and Review handoffs without changing that strategy.

## Intervention cadence

The Coordinator runs after every worker. The Overseer does not.

Codeness controls when automatic strategic changes are legal. The initial policy is intentionally small:

- Run a periodic control review after three complete cycles or 12 worker turns without Overseer review, whichever
  comes first.
- Review earlier when the same member fails or remains blocked twice, an agent target becomes unavailable, the
  Coordinator requests oversight, or a completion candidate appears.
- Apply at most one automatic strategic revision per Overseer decision.
- Require one complete cycle under a strategic revision before another automatic revision, unless the team is
  unrunnable.
- After three automatic strategic revisions without durable progress evidence, pause for the Board.
- Allow Board edits and Review Strategy Now at any time.

These numbers are provisional product defaults, not proven truths. Codeness should record review frequency,
accepted and rejected proposals, undo rate, session resets, completion reversals, time, and token use. Real
activities should determine whether the defaults change.

A narrative claim by an agent is not enough to reset the no-progress counter. Codeness records the evidence used,
such as a durable repository change, accepted validation, resolved blocker, or explicit Board acknowledgment.

The first implementation does not need a semantic oscillation detector. The stable working goal, one-cycle
minimum, three-revision ceiling, visible history, and Board undo provide understandable limits without another
classifier.

## Completion

The Coordinator cannot complete an activity. It can only report `completionCandidate`.

Codeness then invokes the Overseer in fresh Completion Review mode. It receives the user goal, current strategy,
bounded run evidence, repository status, known validation, unresolved blockers, and Coordinator rationale. It
cannot modify the team during this invocation.

The Completion Review returns one of:

- `complete`, with evidence mapped to the user goal;
- `continue`, which returns control to Strategic Review if the team needs adjustment; or
- `pause`, when the Board must decide.

If completion requires a final report, cleanup, or release step, the Overseer does not weaken the goal or claim
completion. It returns `continue`, then Strategic Review inserts the required one-time member. A later completion
candidate starts a new fresh Completion Review.

This separates team management, strategy, and acceptance. The same configured provider may fill these roles, but
their prompts, state, and allowed responses remain distinct.

## Live edits and conflicts

The Board can edit the live team at any time. The Overseer can propose changes only during its allowed modes. An
active provider turn remains immutable.

Every edit contains a base revision. Codeness accepts it only when that base is still current. A stale edit is
rejected and shown against the newer revision instead of being silently merged.

Only one pending revision is stored, with these precedence rules:

- A Board edit may replace the Board's own pending edit after explicit confirmation.
- An automatic Overseer proposal never replaces a pending Board edit.
- If a Board edit arrives while an automatic proposal is pending, the Board chooses whether to discard or inspect
  the proposal.
- An automatic proposal based on an old revision is rejected.
- Codeness never merges two provider histories or two structural patches.

When a worker finishes, Codeness durably activates the accepted pending revision before asking the Coordinator to
route the result. The Coordinator receives the completed run's immutable member snapshot and the active revision.
If Strategic Review changes the team after that routing decision, Codeness asks the Coordinator to reconcile the
handoff under the new revision before launching another worker.

Edit effects are explicit:

| Edit | Active turn | Next safe boundary | Session effect |
| --- | --- | --- | --- |
| Rename or move member | Unchanged | Uses new definition | Preserved |
| Change effort or speed | Unchanged | Uses new target | Preserved when supported |
| Change instructions | Unchanged | Uses new instructions | Fresh lineage |
| Change provider, model, or mode | Unchanged | Uses new target | Fresh lineage |
| Change run or session policy | Unchanged | Uses new policy | Follows session rules |
| Add member | Unchanged | Becomes eligible | Created when first used |
| Remove inactive member | Unchanged | Removed | Released when no durable reference remains |
| Remove active member | Allowed to finish | Scheduling restarts at first eligible member | Released after run and routing finish |

## Session strategies

Session persistence is a strategic choice for each team member:

| Product name | Behavior | Typical use |
| --- | --- | --- |
| Own memory | One private persistent session across cycles | Stable implementer or specialist |
| Shared memory | Several compatible members use one persistent session | Closely coupled work that repeatedly reconstructs the same context |
| Fresh every run | Each execution starts without earlier provider conversation | Independent review, audit, or work biased by stale assumptions |

Today's behavior maps to Own memory for every member. Fully independent persistent members each use Own memory.
All members can share by joining one Shared-memory group.

Persistent state belongs to session slots rather than directly to member IDs. An Own-memory slot derives from one
member ID. A Shared-memory slot has a stable Codeness-generated group ID. A Fresh execution owns temporary session
state long enough to support interruption and crash recovery, then releases it after its run and Coordinator
handoff are durable.

The hard rules are:

- Shared members must use a compatible provider, model, and mode.
- Creating a shared group starts fresh. Codeness never merges existing histories.
- Joining an existing group adopts its lineage at the next execution.
- Leaving a group starts a fresh private lineage. Codeness never pretends to fork a conversation.
- Changing instructions or execution identity resets the affected Own lineage.
- Changing one Shared member's instructions resets the shared lineage unless the same revision first moves that
  member out of the group.
- Removing one member does not release a shared slot while another member or recoverable run references it.
- Import preserves member IDs, group IDs, policies, and revisions but clears machine-local provider session IDs.
- Loaded-session admission counts distinct persistent slots plus an active Fresh slot, not team members.

Own memory is the default. Fresh every run should be the normal choice for independent Review. The Overseer may
choose Shared memory only when roles are compatible and repeated evidence shows that context reconstruction is
wasteful. It must not automatically share implementation and independent Review.

The persisted model should support all three strategies, but delivery should be staged. Own and Fresh come first.
Shared memory remains manual or experimental until provider-specific tests prove reliable role switching.

The Overseer and Coordinator use fresh bounded control invocations in the first design. Codeness's durable state is
their memory. A persistent Coordinator session can be considered later only if real usage shows that reconstructing
local flow is costly.

## Persistence and recovery

The redesign must preserve these guarantees:

- A run owns an immutable member snapshot, session binding, working goal, and launch revision.
- Codeness acknowledges an edit only after the pending revision is durable.
- A crash before revision persistence leaves the previous revision authoritative.
- A crash during a run recovers that run against its launch revision.
- A pending revision remains pending until the run reaches a terminal state.
- A removed active member can recover because the run owns its snapshot.
- A Coordinator retry uses the revision that was active at its routing boundary.
- Strategic Review rerouting cannot reuse a stale Coordinator handoff.
- Provider sessions are released only after no durable run, checkpoint, or member references them.
- One-step undo restores the previous definition, not a provider conversation already released under its rules.

Keep a small append-only edit record with revision, time, actor, operation summary, evidence, and reason. Actors
are `board`, `overseer`, and `migration`. Run history records the exact definition each agent saw. Do not create a
general event-sourcing system or store a full team copy for every run.

## User interface

The activity window should make the hierarchy visible without turning it into an organization chart.

Show:

- the Board's user goal;
- the Overseer's current working goal and last strategic reason;
- the ordered team with once or every-cycle policy;
- the Coordinator and current local handoff;
- each member's target and Own, Shared, or Fresh session choice;
- active and pending revision state;
- Review Strategy Now and Review Changes First controls;
- one-step undo; and
- compact strategic edit history.

Ordinary users should see a simple team list. Run and session policy live in an advanced disclosure.

Saving during a run should say which revision the active member keeps and when the pending revision starts.
Removing the active member should say that its current turn finishes and scheduling restarts at the first eligible
member. Joining or resetting a Shared-memory group must name every affected member and whether existing context is
released.

## Migration

Migration is one Overseer intervention, not a fixed mapping from old sections to new members.

At a durable paused boundary, Codeness invokes Migrate mode once with:

- the user goal and amendments;
- old template, cursor, and recovery checkpoint;
- step IDs, targets, lineages, and established sessions;
- bounded recent runs, handoffs, failures, steering, and usage;
- repository and activity status; and
- pending Board changes.

The Overseer returns a working goal and complete live team revision. It may preserve an old step ID and Own-memory
lineage only when responsibility and execution identity remain compatible. Combining, splitting, rewriting, or
forming a new shared group starts fresh lineages. Migration never merges provider sessions.

Codeness validates the answer, maps the identity-based checkpoint, writes one migration record, and swaps runtime
state in one transaction. Existing runs and transcripts remain unchanged. Failure leaves the old activity paused
and authoritative.

A running activity offers Convert After Current. A paused activity offers Convert Now. Start Over creates a new
goal-only activity and lets Bootstrap design it. The legacy catalog can be deleted after migrated activity recovery
and retained legacy fixtures no longer require it.

## Honest risks and deliberate choices

This design is better suited to long autonomous work than frozen templates, but it is more powerful and less
predictable. Its safeguards must live in Codeness, not only in prompts.

The main risks are:

- The Overseer can translate the user goal poorly. Stable working goals, Board-visible constraints, fresh
  Completion Review, and manual override reduce this risk but do not eliminate it.
- Automatic strategy can churn. Separate Coordinator and Overseer roles, revision conflicts, one-cycle minimum,
  and a three-revision ceiling bound the damage.
- Shared context can erase independent judgment. Own and Fresh are safe defaults; Shared is staged and never the
  automatic Implement plus Review choice.
- Bootstrap is nondeterministic. Saved revisions make decisions inspectable, but identical goals may produce
  different teams.
- Migration and live editing touch persistence, recovery, sessions, and UI. This is a major rewrite and must ship
  in recoverable slices.

The design deliberately keeps one ordered team instead of adding branches, dependencies, nested loops, parallel
execution, or a visual graph. A one-time run policy covers setup and finalization without recreating workflow
sections.

## Implementation sequence

1. Add pure models and transition tests for user goal, working goal, live team revision, run policy, identity-based
   checkpoint, and stale-edit rejection. Keep existing activities unchanged.
2. Split Coordinator and Overseer request and response schemas. Prove that only the Overseer receives the user goal
   and that the Coordinator cannot return strategic fields.
3. Add goal-only Bootstrap and Board-visible revision 1. Keep automatic strategic editing off.
4. Add identity-based scheduling, once and every-cycle members, safe live Board edits, human precedence, recovery,
   and Coordinator rerouting after a revision.
5. Add Own memory, Fresh every run, explicit reset, slot admission, and delayed release.
6. Add completion candidates and fresh Completion Review.
7. Add automatic Strategic Review with the small cadence limits and Review Changes First.
8. Add one-shot migration for legacy activities and stop offering templates for new activities.
9. Add Shared memory as a manual experiment, then allow Overseer selection only after provider-specific evidence.
10. Remove legacy catalog code after migration and retained recovery fixtures no longer need it.

Each stage must survive focused interruption, persistence failure, routing retry, restart, and export or import
tests before the next stage changes authority.

## Acceptance scenarios

Focused tests must prove at least these cases:

- Bootstrap a goal-only activity. Only the Overseer request contains the user goal. Revision 1 is durable before a
  worker session exists.
- Reject invalid Bootstrap output without creating a partial team or session.
- Run several Coordinator handoffs without changing the working goal or revision.
- Reject a Coordinator response containing a working goal, team patch, session change, or final completion.
- Accept a Board edit while a worker runs. The active run stays unchanged and the new revision activates before
  the Coordinator routes it.
- Reject a stale Overseer proposal and never replace a pending Board revision automatically.
- Run a one-time Plan member once while repeating members continue across cycles.
- Remove the active member, quit during execution, recover, route under the active revision, and continue at the
  first eligible member.
- Report a completion candidate. A fresh Completion Review checks the user goal and either completes, continues,
  or pauses.
- Run Own-memory and Fresh-every-run members through interruption and restart without leaking or losing the active
  lineage.
- Form a compatible Shared group without selecting either prior history as its seed. Reject incompatible members.
- Change one Shared member's instructions and reset the full group unless the revision first moves it out.
- Reach periodic and early Strategic Review. Apply at most one revision and pause after the configured no-progress
  ceiling.
- Migrate an old activity from its old configuration and bounded overall state exactly once. Failure leaves the old
  paused state authoritative.
- Reproduce the UnityBridge four-member to two-member intervention without editing private files or losing its 515
  prior runs.

## Non-goals

Do not add a workflow graph, arbitrary conditions, nested loops, parallel execution, a prompt language, or
arbitrary agent code execution as part of this redesign.

Do not let the Coordinator make strategic changes or let the Overseer manage every handoff.

Do not mutate a provider turn already in flight. Editable while running means a revision can be saved immediately
with a clear activation boundary.

Do not merge, clone, or fork provider histories. Transcripts remain the durable evidence used to rebuild context
when a new lineage starts.

Do not present the cadence constants as permanent truths. They are safe initial limits to be revised from real
activity evidence.
