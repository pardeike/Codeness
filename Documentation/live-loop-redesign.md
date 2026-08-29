# Product-company orchestration

Status: implemented in Codeness

Decision date: 2026-08-28

## Purpose

Codeness is a universal company simulator for producing a real result from one user goal. It is not a process designer, a document generator, or a perpetual management meeting.

The operating model is designed around two pressures that both force delivery:

- top-down return on investment: the CEO allocates tokens only to work that advances the fixed user goal;
- personal craft investment: every hired person has opinions, ambition, a stake in the result, and a desire to produce accepted evidence in their profession.

Creative energy is welcome, but ideas earn continued investment through coherent, inspectable contributions: software, research, visual or audio work, writing, physical design, analysis, commercial evidence, operations, support, or quality findings. This prevents both known local minima: bureaucratic caution with no result, and a software-only loop that erases the company professions needed to produce one.

## User contract

The user has only these operating interactions:

1. Create a new named folder or open an existing folder or repository, then define the fixed user goal. Codeness initializes Git when needed.
2. Pause, quit, reopen, and resume at durable boundaries.
3. Steer a running person or edit the fixed user goal.
4. After completion, amend the goal and start over while retaining the repository contents.

The user does not approve internal stages, hires, investment decisions, reviews, or reversible implementation choices. The user goal is preserved verbatim. Working goals, bets, assignments, people, and decisions are repository-adjacent Codeness state, not additions to the user goal.

## Company model

Every new activity begins with a generated persistent CEO. The CEO is the only model invocation that sees the complete user goal and the only authority that can complete the activity.

The CEO funds one product bet and hires the smallest team needed to pursue it. Every employee is a persistent named person. A person contains:

- full name and predefined position;
- background, formative success, and formative scar;
- concrete convictions and personal stake;
- working and conflict styles;
- a useful blind spot;
- evidence that can change their mind;
- randomized character ingredients used to create them;
- actual generation-token cost and a virtual hiring opportunity charge;
- an append-only company track record; and
- the current project-specific assignment.

The immutable profile keeps a person recognizable across strategy changes. Their assignment and track record evolve with the work.

### Profession, assignment, tools, and contribution

These are separate contracts:

- the fixed position practice defines what the profession owns, accepts, subscribes to, and must escalate;
- the current assignment names one allowed contribution, required capabilities, acceptance evidence, predecessor dependencies, and a stopping or block condition;
- the selected target advertises the effect-level capabilities it can enforce and supply;
- the provider adapter maps the intersection to its concrete tools and sandbox; and
- the worker returns a typed contribution rather than generic completion prose.

Every predefined position has an explicit practice. No position inherits a generic Developer contract. `Sound Designer` owns audio and music work. Developer is hired only when source implementation is an actual dependency.

The CEO sees target capability profiles before staffing. A proposed assignment is rejected when its contribution does not belong to the position, when its capabilities cross that profession's boundary, or when the target cannot supply them. The existing one-retry correction path applies; a second invalid company stops visibly rather than receiving broader tools.

### Non-indifference requirement

Personas must be ambitious, emotionally invested, strongly opinionated, willing to disagree, and impatient to show a real product. Persona prompts and structural validation reject neutral facilitators, indifferent colleagues, generic assistants, consensus-first managers, and characters invested in mediocrity.

Strong personality is not permission to ignore evidence, safety, authorization, or the user goal. Every person has explicit evidence that can change their mind. Productive disagreement is valuable; consequence-free hype is not.

### Fixed positions

The model may choose only predefined ordinary company positions. It never invents a goal-specific title. The assignment carries the specific work.

Universal positions include CEO, Product Manager, Producer, Developer, Designer, Researcher, QA Tester, and Operations Manager. Fixed sector catalogs add familiar software, creative and media, research and data, physical-product, and business and market positions such as Technical Lead, Art Director, Data Analyst, Mechanical Engineer, and Marketing Manager.

The CEO position is appointed separately and cannot be returned as an employee position. The user may replace the CEO from the Company list. Replacement generates and persists a new person and affects future investment decisions without interrupting current product work.

## Funded product bets

One product bet contains:

- an outcome-led headline;
- the user or product value promised;
- the integrated demonstration to show;
- the repository surface into which it must integrate;
- a condition that should end or redirect the bet;
- a token budget in 250,000-token funding units; and
- a maximum-turn safety boundary.

The CEO normally allocates three to eight funding units and six to twenty turns. Funding uses fresh input plus output at full cost and cached input at one tenth cost; raw provider usage remains available separately. Six turns is a hard minimum before an ordinary token or readiness review, so a review cannot recur after only one or two assignments. A genuinely unrunnable team still receives immediate executive repair. The turn boundary is a fallback when a provider cannot report complete token usage; effective funding tokens remain the primary cost signal.

Assignments must produce the accepted contribution of the hired profession. Status prose and meetings are not substitutes, but a research synthesis, visual direction, score specification, operating procedure, cost model, or quality verdict is real company value when its practice owns that artifact. Source changes are neither required nor privileged outside Development.

## Lightweight orchestration motor

Normal successful turns do not call a model coordinator. A deterministic company motor:

1. saves the completed worker result;
2. decodes its typed work report while preserving the full raw transcript;
3. marks completed one-time assignments;
4. calculates the next eligible saved assignment;
5. intersects the source contribution with the recipient practice and assignment dependencies;
6. builds a bounded handoff from relevant artifacts, decisions, evidence, constraints, and blocks;
7. measures tokens and turns under the current bet; and
8. either starts the next person or opens an investment boundary.

This removes the previous per-turn management call and its tendency to reinterpret every result as a reason for more ceremony.

Malformed output becomes a bounded `unstructured` report with missing-evidence risk. It never gains the authority of a typed contribution. Raw output remains attached to the source run for inspection but is no longer replayed as the next worker's primary brief.

### Capability blocks

Tool boundaries are enforced by provider mechanics: Claude receives an explicit tool allowlist, OpenAI-compatible sessions advertise only permitted local tools, and Codex applies a profession configuration plus a read-only sandbox when source mutation is not allowed. Session identity includes the resolved policy, so shared-memory names cannot widen an existing conversation; different policies get different provider slots.

If a required effect is forbidden to the profession, unavailable on the target, unenforceable by the provider, or discovered missing during work, the result is a structured `CompanyCapabilityBlock`. The motor immediately sends it to investment review. The CEO must select an equipped profession and target, narrow the assignment, or stop the bet. Retrying the same specialist as a programmer is invalid.

After the six-turn runway, the motor opens an ordinary investment boundary when:

- the funded token budget is consumed;
- the maximum-turn boundary is reached;
- a person explicitly reports that an integrated demonstration is ready;

The motor opens an exceptional investment boundary immediately when:

- no person remains eligible;
- a material blocker or repeated failure requires executive action;
- the user changed the goal; or
- completion must be judged.

Resume is not a review trigger. Pause saves the exact next action, and Resume continues it. There is no periodic round, turn, or elapsed-time review schedule.

Older saved agent loops retain their exact recovery point. They convert once at the next completed round or another natural executive boundary. Opening or resuming alone does not create the conversion review.

## Investment review

At an investment boundary, every currently hired employee gives one short report in parallel. No model call selects or invents meeting participants. No fresh generic manager personas are created. Each report uses the employee's persisted story, convictions, assignment, and company track record.

Reports cover involvement, the profession-specific contribution, evidence, one concern or none, and the single next move inside that profession. They are advice, not votes. Missing or invalid reports remain visible as unavailable and never block the CEO from deciding.

The CEO sees the fixed user goal, current product bet and company, durable run evidence and handoffs, token costs, prior company changes, and every available company report.

The CEO then renews the current bet, funds a replacement bet and company, or completes the goal. Renewing a bet creates a new persisted funding revision so its token and turn budget starts cleanly. Only the CEO can stop the autonomous loop as complete.

## Token return

Codeness records two cost classes:

- product work: every employee run;
- company control: initial setup, persona generation, legacy coordinator calls, correction retries that report usage, company check-ins, and CEO decisions.

The overview shows both classes, raw total tokens, effective funded-token progress, completed investment decisions, and tokens per decision. Effective funding cost counts fresh input and output in full and cached input at one tenth; this keeps raw accounting honest without treating cheap replay as equivalent to new work. Historical company definitions are retained so setup and former-person costs do not disappear when the company changes. Virtual hiring opportunity charges are displayed separately from actual provider token usage.

This is cost accounting, not a fabricated value score. Product value remains evidence-backed: an integrated result, exercised behavior, user or teammate use, an accepted demonstration, or concrete learning that changes the investment decision.

Provider usage can still be incomplete when a provider fails before returning usage. Codeness never invents missing token counts.

## Prompt culture

The CEO prompt establishes a forceful founder mindset:

- the fixed user goal is the sole authority source;
- subordinate concerns are hypotheses, not vetoes;
- the company should be bold, energetic, playful, and eager to show work;
- the best idea must become accepted evidence through the professions that own it;
- repeated status work or disconnected contributions are investment failures;
- useful goal progress and learning per effective token cost drive the next bet;
- unavailable external evidence is recorded once while autonomous product work continues;
- ordinary position IDs are mandatory; and
- only the CEO can declare the goal complete.

Employee prompts establish profession-first behavior:

- act from the persisted personality and convictions;
- challenge timid or mediocre work;
- produce exactly the assigned profession contribution;
- satisfy its stated acceptance evidence;
- stop and report a capability block rather than imitate another profession;
- use only the position and target's intersected capabilities;
- do not launch sub-agents because Codeness owns orchestration; and
- return a compact structured report containing artifacts, evidence, decisions, constraints, risks, blocks, and recommended recipients.

CEO decisions use short fields rather than essays: reason and evidence are at most two sentences each, working goals are at most three sentences, and assignments are at most 60 words. Company check-ins are capped at 80 words. Formal, academic, consultant, and committee language is explicitly rejected because volume can make weak progress look substantial.

The current repository and Codeness handoffs are the only project-specific history. Prompts forbid recovering old project decisions or implementations from personal or global agent memory, previous Codeness runs, archives, Trash, sibling workspaces, and other checkouts unless the current goal or repository explicitly names that source. This keeps a reset repository genuinely clean while still allowing general engineering and creative knowledge.

The prompts are deliberately company-generic. Software and coding remain one family of contributions, but the operating system gives research, creative, operational, commercial, physical-design, and support work equal standing under their own evidence rules.

## Interface

The sidebar begins with a compact Company section. It lists the CEO and current employees by name and familiar position. Selecting a person opens a vertically scrolling detail view with their assignment, story, convictions, stake, work personality, track record, and hiring cost. Long text wraps. Detail groups are collapsed by default.

Run rows retain short outcome-led headlines. Their metadata shows person name and position. Investment reviews remain visually distinct chapter rows and are selectable like turns. Their detail view contains collapsed sections for the trigger, company check-in, CEO decision, and resulting funded company.

The work overview shows the current bet, current company, product and control tokens, investment-decision count, and tokens per decision.

## Persistence and recovery

- The fixed user goal is never rewritten by generated product detail.
- A worker turn owns an immutable launch snapshot, including person, position, assignment, working goal, product bet, target, and memory binding.
- Product results and deterministic routing decisions are saved before the next turn starts.
- A company change applies only at a saved safe boundary.
- Persona profiles, randomized ingredients, generation costs, track records, product bets, company-definition history, reports, and CEO decisions are Codable activity state.
- A removed worker may finish the turn launched from the old snapshot.
- Reopening active work pauses it until the user resumes.
- Completed historical activities remain readable without forced migration.

## Deliberate limits

- Persona quality and CEO judgment still depend on model behavior; the prompts and evidence structure constrain but cannot guarantee taste.
- Token usage is exact only to the degree the provider returns usage.
- Codeness does not create a synthetic value-point score. A later version may add accepted-demonstration annotations when there is a reliable acceptance event.
- Employee execution remains ordered. Company reports run in parallel because they are short, independent, and read-only.
- Legacy source names such as `LiveTeam`, `member`, `cycle`, and `revision` remain for persisted compatibility. They are not the intended product language.

## Non-goals

This design does not add a visual workflow graph, arbitrary user-authored roles, nested orchestration, periodic management meetings, a bureaucracy settings panel, or unmanaged sub-agent trees. The product surface stays centered on the user goal, company, funded bet, product turns, investment decisions, and durable result.
