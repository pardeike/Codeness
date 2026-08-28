# Product-company orchestration

Status: implemented in Codeness

Decision date: 2026-08-28

## Purpose

Codeness is a universal company simulator for producing a real result from one user goal. It is not a process designer, a document generator, or a perpetual management meeting.

The operating model is designed around two pressures that both force delivery:

- top-down return on investment: the CEO allocates tokens only to work that advances the fixed user goal;
- personal product investment: every hired person has opinions, ambition, a stake in the result, and a desire to show working product value.

Creative energy is welcome, but ideas earn continued investment by becoming a coherent product people can see, use, test, or make a concrete decision from. This prevents both known local minima: bureaucratic caution with no product, and an endless contest of exciting prototypes with no integrated delivery.

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

Assignments must produce or exercise the real product. Plans, documentation, status prose, evidence collection, meetings, and reviews are support work and do not count as product value unless the user goal makes them the deliverable or they directly unlock the integrated demonstration.

## Lightweight orchestration motor

Normal successful turns do not call a model coordinator. A deterministic product motor:

1. saves the completed worker result;
2. marks completed one-time assignments;
3. calculates the next eligible saved assignment;
4. measures tokens and turns under the current bet;
5. carries the factual result forward as the next handoff; and
6. either starts the next person or opens an investment boundary.

This removes the previous per-turn management call and its tendency to reinterpret every result as a reason for more ceremony.

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

Reports cover involvement, progress, evidence, one concern or none, and the single next product move the person would fight for. They are advice, not votes. Missing or invalid reports remain visible as unavailable and never block the CEO from deciding.

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
- the best idea must become an integrated product;
- repeated support work or disconnected prototypes are investment failures;
- product value and learning per effective token cost drive the next bet;
- unavailable external evidence is recorded once while autonomous product work continues;
- ordinary position IDs are mandatory; and
- only the CEO can declare the goal complete.

Employee prompts establish build-first behavior:

- act from the persisted personality and convictions;
- challenge timid or mediocre work;
- improve the repository's actual product;
- exercise or demonstrate the result;
- avoid documentation unless it is the product or durable operating information;
- do not launch sub-agents because Codeness owns orchestration; and
- report concrete changes, exercised evidence, blockers, and the highest-value next move in at most 180 plainspoken words.

CEO decisions use short fields rather than essays: reason and evidence are at most two sentences each, working goals are at most three sentences, and assignments are at most 60 words. Company check-ins are capped at 80 words. Formal, academic, consultant, and committee language is explicitly rejected because volume can make weak progress look substantial.

The current repository and Codeness handoffs are the only project-specific history. Prompts forbid recovering old project decisions or implementations from personal or global agent memory, previous Codeness runs, archives, Trash, sibling workspaces, and other checkouts unless the current goal or repository explicitly names that source. This keeps a reset repository genuinely clean while still allowing general engineering and creative knowledge.

The prompts are deliberately product-generic. Software and coding remain common positions and activities, but there is no game-specific language in the operating system.

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
