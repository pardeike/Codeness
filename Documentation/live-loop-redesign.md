# Live loop editing redesign

Status: design proposal, not implemented

Origin: UnityBridge workflow intervention, 2026-08-27

## Decision

Codeness should stop treating a workflow template as a frozen runtime program. A new activity starts with a fixed
user goal and no steps. Its overseer creates a working goal and the first live, ordered loop from the user goal,
repository, and available agents.

The user and overseer can then add, remove, move, or edit steps while the activity is paused or running. A running
turn keeps the exact step snapshot it started with. The latest valid loop revision takes effect when that provider
turn ends, before Codeness routes its handoff.

The overseer also replaces the separately configured coordinator. It creates the initial loop, routes each
completed step, decides completion, and reviews the loop on a bounded cadence. Routing and structural review are
different invocation modes so an agent that runs after every step cannot rewrite the loop after every step.

New activities do not use workflow templates or presets. The legacy decoder and template UI remain temporarily so
existing activities can recover and perform the one-time migration described below.

This change should reuse the current agent providers, run records, handoff router, persistence, interruption, and
recovery code. It does not call for a general workflow graph, branching language, or another orchestration layer.

## Why change it

The current template system is good at starting a workflow and bad at evolving one.

A generic activity stores a complete `WorkflowTemplate`. Its cursor uses a section and array index. The app permits
instruction and target changes only while paused, and `RepositoryCoordinator.updateWorkflowPreferences` rejects
changes to workflow identity, step names, sections, order, or membership through `sameFrozenWorkflowTopology`.
The restrictions make sense for an index-based scheduler, but they force a long-running activity to preserve an
early guess about how work should be organized.

The UnityBridge activity showed the cost. It reached 515 runs with persistent Prepare, Plan, Code, and Review
sessions. Product work was progressing, but the workflow began spending repeated cycles on its own audit verifier.
Recovering useful progress required an external intervention:

1. Pause at a durable checkpoint and quit Codeness.
2. Edit `workspace.json` directly.
3. Replace four steps with Deliver and Review.
4. Assign new step IDs and clear the old session map.
5. Compact the goal and repository handoff state.
6. Reopen while paused, verify recovery, and resume.

The new Deliver session initially repeated the stale pre-intervention handoff. After reading the repository, it
recognized the newer workflow decision and corrected itself. The restart was safe, but the repair depended on
knowledge of Codeness's private persistence format. Codeness should make the same operation ordinary, visible, and
recoverable.

The implementation has useful pieces already:

- `WorkflowStep` has a stable ID, instructions, and agent target.
- `WorkflowSessionState` already makes provider lineage explicit, although the redesign must stop assuming that one
  step ID always owns one lineage.
- `RunRecord.workflowStep` preserves the step identity and loop iteration seen by a run.
- `RepositoryCoordinator` already persists `.recoverRun`, `.routeCompletedRun`, and `.perform` checkpoints before
  crossing provider and routing boundaries.
- `WorkflowEditorSheet` already supports adding, removing, moving, and editing steps before an activity starts.
- `RepositorySettingsSheet` and `updateWorkflowPreferences` already update instructions and targets while paused.

The redesign changes topology ownership and transition identity. It should extend these paths rather than replace
them.

## Product model

An activity owns these concepts:

- a user goal that agents cannot edit;
- a working goal maintained by the overseer;
- one ordered list of loop steps;
- an explicit session policy for each step;
- one overseer configuration and general policy;
- a current loop revision;
- a scheduler checkpoint;
- provider session slots owned by a step or shared group, plus run-owned sessions for fresh execution; and
- run history containing the exact step, session policy, and loop revision used for each run.

There are no runtime Before Loop, Repeating Loop, or After Completion sections in the new model. Planning,
implementation, review, cleanup, and final reporting are all ordinary steps. A user who wants a planning pass can
start with a Plan step and remove it later. A final report can be requested as a normal step before completing the
activity. The scheduler only needs to repeat an ordered list and honor an overseer completion result at a safe
boundary.

A draft activity may contain no working goal and zero steps while it waits for initial loop creation. The work
scheduler requires a nonempty working goal and at least one step before launching a worker. If overseer creation
fails or returns an invalid revision, Codeness pauses the empty activity and offers Retry Overseer and Edit User
Goal. Step IDs are generated by Codeness and never edited in the UI.

One possible persisted shape is:

```swift
struct LiveLoopDefinition: Codable, Equatable {
    var revision: Int
    var workingGoal: String
    var steps: [LiveLoopStep]
}

struct LiveLoopStep: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var instructions: String
    var target: AgentTarget
    var sessionPolicy: SessionPolicy
}

enum SessionPolicy: Codable, Equatable {
    case persistentStep
    case persistentShared(groupID: String)
    case freshRun
}

struct LiveLoopCheckpoint: Codable, Equatable {
    var stepID: String
    var loopIteration: Int
    var loopRevision: Int
}

struct OverseerDecision: Codable, Equatable {
    var handoff: String
    var outcome: WorkflowOutcome
    var runLabel: String
    var workingGoal: String?
    var loopPatch: LiveLoopPatch?
}
```

The names are illustrative. The important changes are an identity-based checkpoint and an activity-owned loop
revision. `WorkflowStep`, `WorkflowSessionState`, `WorkflowStepSnapshot`, `WorkflowOutcome`, and most of the
existing target model can remain, but persisted session state becomes slot-based instead of step-keyed. The current
handoff response grows one optional, structured loop patch.

## Two goals

The user goal and working goal have different authority.

The user goal states what success means and what the activity is allowed to do. Agents cannot edit it. If the user
changes it explicitly, Codeness records a human amendment and treats the revised text as a new user-goal version.
An overseer cannot create that amendment.

The working goal is a compact, current operating brief. The overseer can narrow the active slice, change priority,
record a required detour and return condition, retire resolved history, or rewrite an overloaded handoff into a
cleaner statement. It cannot remove a user requirement, claim completion on weaker terms, add external authority,
or turn an optional discovery into mandatory scope without tying that decision to the user goal.

Every worker prompt contains only the current operational scope:

```text
WORKING GOAL
The overseer's current scope and priorities.

YOUR STEP
The instructions and stopping condition for this step.
```

Among agents, only the overseer receives the user goal. It must carry every requirement and task-specific authority
boundary that matters to the current work into the working goal. Workers never reinterpret the full user goal and
cannot claim overall completion. Their job is to finish the working goal through their configured step.

The overseer judges completion only against the user goal. A working-goal update and loop patch form one atomic
loop revision. This prevents Codeness from applying new steps with stale scope or new scope with an old step
structure. A decision may update only the working goal, only the steps, both, or neither. Codeness's own provider,
filesystem, interaction, and process safety rules still apply independently of either goal.

## Edit semantics

The editor is available at all times. Saving an edit validates and persists a complete new loop revision in one
transaction. It never rewrites the active run.

| Edit | Running turn | Next scheduling boundary | Provider session |
| --- | --- | --- | --- |
| Rename a step | Keeps launch snapshot | Uses new name | Preserved |
| Change effort or speed | Keeps launch target | Uses new target | Preserved when the provider supports it |
| Change instructions | Keeps launch instructions | Uses new instructions | Starts a fresh lineage |
| Change provider, model, or mode | Keeps launch target | Uses new target | Starts a fresh lineage |
| Change session policy | Keeps launch session | Uses the new binding | Follows the transition rules below |
| Move a step | Continues normally | Uses new order | Preserved |
| Add a step | Not visible to active turn | Eligible at next boundary | Created on first run |
| Remove another step | No effect on active turn | Step is absent | Released after the revision is durable |
| Remove the active step | Active turn is allowed to finish | Scheduling restarts at the first step | Released after the turn and handoff finish |
| Request fresh context | No effect on active turn | Next execution starts a new lineage | Previous session is released after persistence |

Starting from the first step after removal of the active step is intentionally simple. The UI must say
this before applying that edit. It avoids carrying old array positions, tombstones, or a graph migration plan.

The provider turn is the mutation boundary. When it finishes, Codeness activates the newest pending revision before
handoff routing. The overseer receives the completed run's immutable step snapshot together with the new loop and
the successor selected from it. This prevents a valid edit from being followed by a stale handoff. Edits saved
after routing starts wait for routing to finish and apply at the next provider-turn boundary.

Only one pending revision is needed. Further edits replace it before activation. Codeness does not need a queue of
partially applied workflow mutations.

## Scheduler changes

`WorkflowCursor` currently stores `section`, `stepIndex`, and `loopIteration`. Array indexes make live structure
changes ambiguous. Replace generic runtime scheduling with a stable step ID and revision.

At run launch:

1. Read the current durable loop revision.
2. Resolve the checkpoint's step ID.
3. Store the full `WorkflowStepSnapshot`, target, session lineage, and loop revision in the run.
4. Persist `.recoverRun(runID)` before starting the provider, as Codeness does now.

When the provider turn finishes:

1. Finish and persist the run against its launch revision.
2. Activate and persist the newest valid loop revision if one is pending.
3. If the completed step still exists, choose the next step after it.
4. If the completed step was removed, choose the first step.
5. Increment the loop iteration only when scheduling wraps to the first step.
6. Route the completed output using the new loop revision and selected successor as context.
7. Persist the next identity-based checkpoint before launching it.

Completion keeps the current conservative rule. Honor `complete` only after a step and its overseer handoff
finish. The overseer is a temporary control session, not a visible or persistent loop step. This reuses the proven
handoff and completion path while giving one agent responsibility for loop creation and repair.

## Session rules

Session persistence is a loop decision, not an accidental consequence of step identity. Each step selects one of
three policies:

| Policy | Meaning | Best fit |
| --- | --- | --- |
| Own memory | The step reuses one private persistent session across cycles | A stable specialist that accumulates local context |
| Shared memory | Every step with the same explicit group ID reuses one persistent session | Closely coupled stages that benefit from one continuous conversation |
| Fresh every run | Every execution starts without provider conversation history | Independent review, audits, or work vulnerable to stale assumptions |

Sharing every step is one shared group. Fully independent persistent specialists use Own memory. Today's behavior
maps to Own memory for every step. Completely stateless executions use Fresh every run. The UI should use those
product names; the persisted enum names above are only illustrative.

Persistent provider state is stored in session slots. An Own-memory slot is derived from the stable step ID. A
Shared-memory slot uses a stable Codeness-generated group ID referenced by every member. A Fresh run owns a
temporary session record only long enough to support interruption and crash recovery; Codeness releases it after
the run and its handoff are durably complete.

Loaded-session admission counts distinct established persistent slots plus any active Fresh-run slot, not loop
steps. A shared group therefore consumes one persistent slot, regardless of how many steps reference it.

The transition rules are deliberately strict:

- Name, position, effort, and speed changes preserve the current slot.
- Instruction, provider, model, and mode changes start a fresh lineage at the next execution.
- Members of one shared group must use a compatible provider, model, and mode. Effort and speed may vary when the
  provider already supports changing them within one lineage.
- Forming a new shared group starts a new lineage. Codeness never merges two existing provider histories.
- Joining an existing shared group adopts that group's current lineage at the next execution and releases the old
  slot only after it is no longer referenced.
- Leaving a shared group for Own memory starts a fresh private lineage. Codeness does not pretend to fork a
  provider conversation.
- Changing the instructions or execution identity of one shared member resets the entire shared lineage unless the
  same revision first moves that step to a different policy. The editor previews every affected step.
- Removing one member does not release a shared slot while another member or recoverable run still references it.
- Undoing a removal restores the step definition and binding, not a provider conversation that was already safely
  released.

The user can request a fresh lineage without changing the policy. The overseer can also set a policy or reset a
slot in Bootstrap, Migrate, or Review mode. Both operations count as structural changes for cadence and undo.

The default is Own memory. The overseer should choose Shared memory only when steps have compatible roles and
repeated handoff evidence shows that reconstructing the same context is wasteful. It should choose Fresh every run
for independent verification or when old conclusions bias later work. It receives per-slot age, usage, member
steps, and recent reset reasons so it can retire overloaded context strategically. The overseer itself remains a
temporary, nonpersistent control invocation with a bounded state snapshot.

## Persistence and recovery

Live editing must preserve the guarantees Codeness already has:

- The active run is immutable after launch.
- Codeness acknowledges an edit only after the pending definition is durable.
- The pending definition becomes routing authority only after its activation revision and recovery checkpoint are
  durable.
- A crash before revision persistence leaves the old revision authoritative.
- A crash after revision persistence but before the next launch resumes from the new identity-based checkpoint.
- A crash during a run recovers the run using its stored step snapshot and launch revision. Its pending edit remains
  pending until the provider turn reaches a terminal state.
- A removed active step can still complete recovery because the run owns its snapshot.
- A routing retry uses the loop revision activated at that provider-turn boundary, so it cannot regenerate an old
  next-step handoff after a structural edit.
- Provider sessions are released only after the durable state no longer references them.
- Import clears machine-local provider session IDs but preserves step IDs, shared group IDs, policies, and loop
  revisions.

Keep a small append-only edit record with revision number, time, actor, operation summary, and optional rationale.
Do not store a full workflow copy for every edit. Retain the previous definition until the next step starts so one
"Undo loop edit" action is crash-safe. Run history already records which definition each agent actually saw.

The edit actor is `user`, `overseer`, or `migration`. This is enough to explain changes without creating a general
event-sourcing system.

## User interface

The activity window should show the live loop near the current run controls. It should not send users to app-wide
template settings for ordinary changes.

The editor needs:

- the ordered step list with add, remove, drag, and duplicate actions;
- step instructions and agent target;
- an Own memory, Shared memory, or Fresh every run control, including shared-group membership;
- a "Start fresh next time" action with lineage impact shown before saving;
- the active step and the revision used by its running turn;
- a pending-change indicator when a running turn still owns an older snapshot;
- one-step undo for the latest applied loop edit; and
- a compact edit history showing who changed what and why.

Saving during a run should use direct language: "Deliver keeps running with revision 12. Revision 13 starts when
this turn ends and will shape its handoff." Removing the active step should say that the current turn will finish
and scheduling will restart at the first step.

Session controls must show consequences before saving. Joining a shared group says which steps and existing
lineage the step will join. Creating a group says that its members start fresh. Resetting a shared group names every
step that will lose provider context. Fresh every run still promises crash recovery for the active run; it does not
promise a resumable lineage after that run has completed.

Creating an activity asks for the goal, then starts the overseer with an empty loop. The user does not choose a
template. Before starting, an advanced disclosure can show the overseer target and its general rules. Once the
overseer saves revision 1, the ordinary loop editor appears and the first worker step starts.

## Overseer

The overseer is Codeness's control agent. It is not a loop step and does not own a persistent worker session. The
current coordinator execution path is its natural starting point.

The overseer runs in these situations:

- when a new activity has a user goal but no working goal or steps;
- after every completed worker turn to create the next handoff and judge completion;
- after interruption, recovery, or a user-goal amendment;
- when the user selects Review Loop Now; and
- when recent evidence suggests that the current organization is wasting work.

It receives the fixed user goal, current working goal and loop revision, the completed worker result when one
exists, bounded recent handoffs and outcomes, per-step runtime and token totals, session policy and slot age,
shared-group membership, recent steering, and the edit record since its previous structural change. Workers
receive none of the user goal or this supervisory history.

At bootstrap, the overseer must return a nonempty working goal and at least one valid step. Codeness applies that
result as revision 1 and launches its first worker. If validation or persistence fails, the activity remains paused
with zero steps. No partial worker session is created.

After a worker turn, the overseer returns the existing handoff fields and may update the working goal. It can return
a loop patch only when Codeness invokes it in Bootstrap or Review mode. The patch uses a small operation set:

```text
addStep
removeStep
moveStep
updateInstructions
updateTarget
setSessionPolicy
resetSession
noChange
```

Each structural change includes a short diagnosis, the evidence that triggered it, and the expected improvement.
Codeness validates it through the same transaction used for human edits.

The product should ship one general overseer policy, not a catalog of workflow prompts. Its rules are:

- create the smallest loop that can make useful progress on the user goal;
- give each worker a bounded responsibility and a clear stopping condition;
- choose the least shared session policy that preserves useful context;
- keep the working goal compact, current, and sufficient for workers who cannot see the user goal;
- conserve every relevant user requirement and authority boundary;
- judge overall completion only against the user goal;
- inspect whether each step changes a decision or produces useful work;
- combine, remove, rewrite, or reset steps when repeated cycles show that they do not;
- add a specialist only for a concrete missing responsibility;
- preserve unrelated work and Codeness's safety rules; and
- return no patch when the current loop is working.

The overseer can apply a validated revision automatically. This is its purpose, including at bootstrap. The user
can switch an activity to Review Changes First, apply a proposal manually, edit it, or reject it. Automatic changes
remain bounded:

- never alter the active run snapshot;
- apply at most one revision per overseer decision;
- keep at least one worker step and keep distinct persistent slots within the loaded-session budget;
- never edit the user goal, credentials, repository, permissions, or external authority;
- never add an unavailable provider or unsupported target;
- require a fresh lineage when instructions or execution identity change;
- never merge or fork provider histories, and never share an incompatible execution identity;
- do not make another structural change until at least one worker has run under the previous revision;
- expose every applied revision with one-step undo; and
- pause when the proposal cannot pass ordinary validation.

The overseer may update the working goal after every worker because scope naturally advances. Structural changes
follow the cadence below. Step membership, order, instructions, target, session policy, and session reset all count
as structural changes. The distinction prevents the edit history from filling with no-op step or context churn.

The UnityBridge intervention is the acceptance case. The overseer should have recognized repeated procedure-only
Review failures, replaced Prepare, Plan, Code, and Review with Deliver and Review, started both lineages fresh,
rewritten the working goal around useful product progress, and named a small reusable audit runner as the next
slice. It should be able to perform that repair while the activity is open, with the same persistence guarantees as
a human edit.

## Intervention cadence

Codeness, not the overseer prompt, controls when structural edits are legal. Every overseer request has one mode:

| Mode | When it runs | Allowed changes |
| --- | --- | --- |
| `bootstrap` | Once for an activity with no working goal or steps | Create working goal and revision 1 |
| `migrate` | Once at a durable boundary for an older template activity | Replace old runtime configuration with working goal and revision 1 |
| `route` | After every worker turn | Handoff, label, outcome, and working-goal update only |
| `review` | At a scheduled, triggered, or manual review point | Working-goal update and at most one loop revision |

The operating principle is "if it is hard, do it more often": let the overseer observe every handoff so it becomes
good at organizing work, but let Codeness admit structural changes only after enough evidence. Frequent judgment
and bounded mutation are separate controls.

The default automatic policy is:

- Run a scheduled Review after three complete cycles or 12 worker turns under the same loop revision, whichever
  comes first.
- Trigger Review early after the same step reports failed, blocked, or incomplete twice without intervening
  progress, or when its provider target becomes unavailable.
- After applying a structural revision, require two complete cycles under it before another automatic structural
  edit. A provider failure that makes the loop unrunnable may bypass the cooldown.
- Let the user select Review Loop Now at any time. A human edit or manual review is not blocked by the automatic
  cooldown, but the UI shows how much evidence the current revision has accumulated.
- Count automatic structural revisions since the last recorded progress result. After three without progress,
  pause and ask the user instead of applying a fourth.
- Detect direct oscillation. Re-adding a recently removed step, restoring the prior order, or alternating the same
  instructions within six cycles pauses automatic review unless new evidence explains the reversal.

A working-goal update does not reset the structural cadence. It creates a new revision only when its normalized
text changes. Route mode must keep it unchanged when the completed turn adds no decision-changing evidence.

Session-policy changes and resets use the same cooldown, no-progress limit, and oscillation detector as step
topology. Moving repeatedly between Shared memory and Fresh every run is an oscillation even when the step list is
unchanged.

The cycle interval can become an activity setting with `1`, `3`, `5`, and `Manual` choices. Three is the default
because it gives every small loop multiple observations. The 12-turn ceiling prevents a large loop from consuming
dozens of runs before review. The cooldown, no-progress limit, and oscillation detector remain enforced for every
automatic interval.

## Migration

Migration is a one-time overseer intervention, not a fixed mapping from old sections to new steps.

For an old generic activity, Codeness first reaches a durable paused boundary. It then invokes the overseer in
Migrate mode with:

- the fixed user goal;
- the old `WorkflowTemplate`, cursor, and recovery checkpoint;
- step IDs, targets, provider lineages, and whether each session is established;
- a bounded summary of recent runs, handoffs, failures, steering, and token/runtime totals;
- the current repository and activity status; and
- any pending human goal amendment.

The overseer returns a nonempty working goal and complete live loop revision, including every step's session
policy. It may preserve an old step ID and its Own-memory lineage only when the step keeps the same responsibility
and compatible execution identity. Combining, splitting, rewriting, or placing existing steps into a new shared
group creates fresh lineages; migration never merges old sessions. Removed sessions are released only after
migration is durable.

Codeness validates the result, maps the next identity-based checkpoint, writes one migration record, and swaps the
runtime state in one transaction. Existing runs and transcripts remain unchanged. If overseer execution,
validation, or persistence fails, the old activity stays paused with its old checkpoint and sessions.

A running old activity can offer Convert After Current. A paused activity can offer Convert Now. Start Over creates
a new empty live activity and lets Bootstrap mode design it without treating the old template as authority.

This is the same shape as the UnityBridge intervention: inspect the goal, old organization, accumulated evidence,
and current work; decide what still helps; then replace the live organization at a safe boundary. Codeness performs
the persistence surgery instead of requiring a person to edit JSON.

Workflow catalogs and their settings UI are not part of the new activity path. They can remain temporarily for old
activities and be deleted when the migration path and retained legacy recovery fixtures no longer need them.

## Implementation sequence

Keep the first implementation narrow.

1. Add the fixed user goal, overseer-owned working goal, live loop revision, and structured overseer modes to the
   persisted activity model. Let Bootstrap mode create revision 1 for a goal-only activity.
2. Expand the current coordinator path into the overseer. Prove that only the overseer receives the user goal and
   that worker prompts contain only the working goal and their step.
3. Replace the section-and-index cursor with an identity-based checkpoint and cover the transition rules with pure
   tests.
4. Let paused and running activities use one validated loop-revision transaction. Activate pending revisions at
   the provider-turn boundary before handoff routing.
5. Replace step-keyed provider state with Own, Shared, and Fresh session slots. Apply the explicit reset, no-merge,
   compatibility, and delayed-release rules through recovery and routing retries.
6. Move the loop editor into the activity window and expose active revision, pending revision, edit history,
   one-step undo, Review Loop Now, and Review Changes First.
7. Enforce Review cadence, cooldown, no-progress, and oscillation rules in application code around the overseer.
8. Add Migrate mode as a one-time conversion of legacy activities, then remove the template catalog after retained
   recovery fixtures no longer require it.

Steps 1 through 5 prove the hard authority, persistence, and scheduling contract. The UI can remain plain until
those rules survive bootstrap failure, interruption, routing failure, app restart, and workspace export/import
tests.

## Acceptance scenarios

The design is ready only when focused tests prove these cases:

- Start a new activity with only a user goal. Bootstrap produces a working goal and revision 1, then the first
  worker prompt contains neither the user goal nor supervisory history.
- Fail or reject Bootstrap output. The goal-only activity remains durably paused with no partial loop, checkpoint,
  or worker session.
- Apply a working-goal change and loop patch. Both become one durable revision; neither can appear without the
  other after a crash.
- Invoke the overseer in Route mode. A topology patch in its response is rejected even if the patch would
  otherwise validate.
- Add and reorder steps while another step is running. The active prompt and run snapshot do not change, and the
  next run uses the new order.
- Edit the active step's instructions. Its current lineage finishes; its next execution starts fresh with the new
  instructions.
- Put two compatible steps in a new Shared-memory group. The group starts one fresh lineage, then both steps resume
  it; no previous step history is silently selected as the seed.
- Join a third step to an existing shared group, remove another member, and restart Codeness between those actions.
  The joining step adopts the durable group lineage and removing one member does not release it prematurely.
- Try to share steps with incompatible provider, model, or mode identities. Validation rejects the revision without
  changing either existing session.
- Run a Fresh-every-run step, quit during execution, and recover it. The active run resumes safely, but its next
  ordinary execution starts a new session after the recovered run and handoff finish.
- Change one shared member's instructions. Codeness either resets the whole group with an explicit impact preview
  or accepts an atomic revision that first moves the edited step out; it never leaves a mixed old lineage.
- Remove the active step, quit during provider execution, reopen paused, resume recovery, route against the new
  loop revision, and continue at the first step without resurrecting the removed session.
- Remove the checkpointed next step before resume. Codeness chooses a documented surviving step and persists that
  decision before launch.
- Save an empty loop after Bootstrap. Validation rejects it without changing the durable revision; zero steps are
  valid only for a goal-only activity waiting for Bootstrap.
- Fail persistence while applying an edit. The previous loop, cursor, and sessions remain authoritative.
- Fail routing after an edit. Retry keeps the completed run's launch snapshot but routes with the already activated
  new loop revision and selected successor.
- Export and import an edited activity. Step IDs, shared group IDs, policies, and revisions survive; local provider
  session IDs do not.
- Apply, reject, and undo an overseer patch through the same code path as a human edit.
- Reach a scheduled Review, an early failure trigger, and the structural cooldown. The overseer may observe every
  handoff but cannot evade the application's topology gates.
- Alternate between two structural revisions. The oscillation detector pauses automatic editing before the loop
  can sustain a feedback cycle.
- Migrate an old activity by giving the overseer its old configuration and bounded overall state exactly once. A
  valid result atomically becomes live revision 1; failure leaves the old paused activity unchanged and
  authoritative.
- Reproduce the UnityBridge four-step to two-step intervention while paused and while Deliver is running, without
  editing private files or losing the 515 prior runs.

## Non-goals

Do not add branches, conditions, dependencies, nested loops, parallel steps, a visual node graph, a prompt language,
or arbitrary overseer code execution as part of this redesign. Those features would recreate the template system
with more state.

Do not let edits mutate a provider turn already in flight. "Editable while running" means the user can save the
new loop immediately and trust when it will activate. It does not mean rewriting a conversation mid-turn.

Do not turn the mandatory overseer into a persistent worker step or let it monopolize a provider context. It is a
temporary control invocation. A person can still edit a two-step loop directly, request an immediate review, undo
an automatic change, or require approval for structural proposals.

Do not add provider-history merge, clone, or fork machinery. Session strategy selects future ownership of context;
run transcripts remain the durable evidence when a new lineage needs to reconstruct something important.

None of these decisions requires a workflow graph or a new provider protocol. The core change is smaller: replace
frozen array topology with a fixed user goal, an overseer-owned working goal, and a durable identity-based loop
that can accept revisions at safe boundaries. Instruction changes reset lineage, automatic Review defaults to
three complete cycles with a 12-turn ceiling, and structural or session-policy changes remain automatic but
visible, bounded, and reversible.
