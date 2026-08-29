# Codeness Company Harness V2

## Summary

Codeness currently models many professions in its company catalog, but the orchestration harness does not honor those distinctions. `LiveTeamPromptBuilder`, `CompanyProductMotor`, and `AgentLiveTeamRouter` give nearly every worker the same build-first assignment shape, pass the previous worker’s mostly raw final output to the next worker, and explicitly bias the CEO toward hiring a Developer. The resulting specialization is largely cosmetic: an Art Director, Sound Designer, Researcher, Product Manager, and Developer receive different titles but substantially the same definition of useful work.

Refactor the live loop into a profession-led company harness:

```text
CEO company design
      │
      ├── assignment + required contribution + acceptance evidence
      ▼
Position practice contract ──► enforceable target/tool policy
      │                                │
      │                                └── denied/missing capability
      ▼                                          │
Specialist worker                                 ▼
      │                                 CompanyCapabilityBlock
      ▼                                          │
Structured contribution                          ▼
      │                                 immediate CEO review
      ▼                                          │
Recipient-aware handoff ◄──────────── hire or assign the right profession
```

The deterministic product motor remains lightweight. It will coordinate typed contributions and capability blocks, not reinterpret the company through another unconstrained language-model layer.

Research supports this direction:

- [MetaGPT](https://arxiv.org/html/2308.00352v6) gives roles distinct goals, constraints, actions, tools, and subscribed message types; workers receive only relevant upstream messages rather than the complete conversation.
- MetaGPT’s concrete [Product Manager](https://github.com/FoundationAgents/MetaGPT/blob/main/metagpt/roles/product_manager.py), [Architect](https://github.com/FoundationAgents/MetaGPT/blob/main/metagpt/roles/architect.py), and [Engineer](https://github.com/FoundationAgents/MetaGPT/blob/main/metagpt/roles/engineer.py) implementations demonstrate that specialization must affect permitted actions and expected artifacts, not merely the persona text.
- [ChatDev](https://arxiv.org/html/2307.07924) defines each subtask through its objective, specialized roles, available tools, communication protocol, termination condition, and constraints; its long-term memory passes extracted solutions instead of replaying entire dialogues.
- [CrewAI](https://github.com/crewAIInc/crewAI/blob/main/README.md) separates an agent’s persistent role, goal, backstory, and tools from each task’s description, expected output, assignee, and prerequisite context.
- MetaGPT and ChatDev are software-company systems, so Codeness should adopt their specialization and communication mechanisms without copying their software-development pipelines. CrewAI provides the more domain-general task/agent separation.

## Implementation Plan

### 1. Preserve this plan as the immutable implementation baseline

- Create a dedicated implementation branch from the current clean `main`.
- Store this complete approved plan, unmodified and in full, at the repository root as `PLAN_V2.md`.
- Commit only `PLAN_V2.md` in the first commit. Confirm the staged diff contains no other path before committing.
- Do not amend, shorten, regenerate, or update `PLAN_V2.md` during implementation. If implementation evidence requires a deviation, record the reason in the relevant later commit and update the canonical product-company documentation separately; the baseline remains unchanged.
- Do not push, open a pull request, release, or publish anything unless separately authorized.

### 2. Introduce exact profession-practice contracts

Add one canonical `CompanyPositionPracticeCatalog`, indexed by every existing `CompanyPositionID`. Keep universal instructions limited to shared concerns such as workspace authority, safety, honesty, memory use, escalation, and natural coworker communication. Remove universal product-building language from that layer.

Each exact position practice must define:

- the profession’s purpose and decisions it owns;
- contribution kinds it may be assigned;
- accepted deliverables and evidence;
- relevant upstream contribution kinds;
- allowed capability classes;
- capabilities it must never silently assume;
- completion and escalation conditions;
- its role-specific work-report contract.

Use reusable capability and contribution enums, but give every position an explicit catalog entry rather than deriving behavior solely from a broad role family.

| Position | Primary contribution and evidence | Strict capability boundary |
|---|---|---|
| CEO | Company thesis, investment decision, staffing design, acceptance conditions | Read company evidence and provider capabilities; no implementation work |
| Product Manager | User problem, priority, requirements, acceptance decision | Workspace inspection, customer/research evidence, authored product artifacts; no source implementation |
| Producer | Work sequencing, dependencies, delivery readiness | Workspace and company-state inspection, authored coordination artifacts; no craft substitution |
| Developer | Working source change with focused build/test evidence | Source editing, shell execution, builds, tests, technical inspection |
| Designer | Product interaction or system design with inspectable design artifact | Design/document tools, product inspection, prototype or design-asset writes; no source implementation unless separately hired as Developer |
| Researcher | Sourced findings tied to a decision | Read-only workspace inspection, web/search tools, research artifacts; no product implementation |
| QA Tester | Reproduction, observed behavior, acceptance result | Build/test execution and product interaction; read-only product/source access |
| Operations Manager | Operating procedure, reliability observation, process control | Operational inspection and approved operational tools; no source or creative production |
| Technical Lead | Technical direction, integration boundary, code-review decision | Source inspection, builds/tests, technical design artifacts; implementation only when also assigned a Developer contribution |
| UX Designer | Flow, interaction, accessibility, and usability artifact | Product/UI inspection, design/prototyping tools, user evidence; no source implementation |
| Release Engineer | Reproducible package/release verification | Build, packaging, signing, artifact inspection; public publishing remains separately authorized |
| Art Director | Visual direction and visual asset acceptance | Image/design tools, asset inspection and asset-file creation; no programming or audio production |
| Writer | Canonical prose appropriate to audience and purpose | Source/reference reading and document/content editing; no code, visual, or audio production |
| Editor | Edited copy with rationale and consistency evidence | Corpus inspection and text editing; no unrelated content invention or implementation |
| Sound Designer | Audio/music direction, produced audio asset, or integration specification | Audio creation/editing/playback and asset writes; no programming or visual production |
| Research Lead | Research question, method, evidence synthesis, confidence judgment | Read-only inspection, web/search, research artifacts; no implementation |
| Data Analyst | Reproducible analysis, dataset/result, and interpretation | Data reading, analysis execution, charts/tables, analysis artifacts; no product source changes |
| Fact Checker | Claim ledger with source-supported verdicts | Read-only corpus and web/search access; no rewriting except a requested correction artifact |
| Industrial Designer | Physical form, ergonomics, materials, manufacturability artifact | CAD/design/visualization tools and design files; no software or fabrication substitution |
| Mechanical Engineer | Mechanical specification, calculation, model, and validation evidence | Engineering analysis/CAD tools and engineering artifacts; no software feature implementation |
| Fabricator | Physical-production instructions, fabrication artifact, or verified build record | Fabrication-specific tools and files; no engineering redesign without escalation |
| QA Technician | Measured physical or technical conformance report | Inspection, measurement, test execution; no repair or redesign unless reassigned |
| Marketing Manager | Positioning, campaign asset, channel plan, and audience evidence | Research, content, and marketing-asset tools; no product implementation or external publication without authorization |
| Sales Manager | Sales hypothesis, qualification evidence, offer, and objection record | Customer and commercial artifacts; no product implementation or unsolicited external contact |
| Customer Researcher | Interview/research protocol, observations, and synthesized needs | Research and approved customer-evidence tools; no product changes or unapproved contact |
| Finance Manager | Cost model, budget judgment, runway or investment analysis | Financial/data analysis and finance artifacts; no spending or account mutation |
| Customer Support Lead | Support diagnosis, response, escalation, and recurring-problem evidence | Product/knowledge inspection and support artifacts; no source fix or external reply without authorization |

Treat the existing `Sound Designer` position as the company’s audio and music profession; do not add a parallel “Music Designer” identifier in this refactor.

Define capability classes at the effect level rather than around provider-specific tool names, including at minimum:

- workspace read;
- external/web research;
- authored text/data artifact write;
- source-code modification;
- command/build/test execution;
- product/UI operation;
- visual asset production;
- audio asset production;
- engineering/CAD production;
- external communication;
- publishing/release mutation;
- financial or other irreversible external mutation.

External communication, publishing, spending, deletion, and other irreversible operations remain authorization-gated even when relevant to a profession.

### 3. Separate company staffing, assignments, and profession prompts

Refactor the CEO/overseer contract so each worker definition contains:

- exact `positionID` and target;
- profession-appropriate assignment;
- required contribution kind;
- required capabilities;
- concrete acceptance evidence;
- relevant predecessor contributions or dependencies;
- a stopping/block condition.

Remove the Developer-default instruction. The CEO must choose the smallest cross-functional team whose professions cover the funded bet. It may hire a Developer when source implementation is actually required, but it may not tell an Art Director, Sound Designer, Researcher, or other specialist to become the missing programmer.

Before accepting a proposed company:

1. Resolve every worker through `CompanyPositionPracticeCatalog`.
2. Verify that the requested contribution is owned by that position.
3. Verify that required capabilities are allowed for the position.
4. Verify that the selected provider/target can enforce and supply those capabilities.
5. Return precise structured validation feedback for one existing correction retry.
6. If the corrected company is still invalid, stop with a visible company-design failure instead of weakening the boundary.

Recompose worker prompts from four deliberately separate layers:

1. Minimal common company rules.
2. The worker’s immutable profession-practice contract.
3. The current assignment and acceptance evidence.
4. Recipient-filtered predecessor context.

Remove universal instructions such as “improve the repository’s actual product,” “prefer an integrated result over plans or documents,” and “prove the best one through the repository.” Equivalent language may appear only in positions whose professional output truly requires it.

Make recurring staff reports profession-specific. A Sound Designer reports on audio direction/assets/integration or a missing capability; an Art Director reports on visual coherence/assets; a Researcher reports evidence and uncertainty; a Developer reports implemented behavior and verification. The generic “next tangible product move” staff prompt must disappear.

Keep provider-session developer instructions role-neutral and short because they can persist across turns. They may state that the current turn’s profession contract is authoritative, but they must not contain a hidden build-first default.

### 4. Replace raw handovers with structured, recipient-aware contributions

Introduce a typed `CompanyWorkReport` for every completed worker run. Use the existing `AgentRunRequest.outputSchema` path so providers are asked for structured output while preserving normal tool/transcript events.

The stable report envelope must contain:

- worker and position identity;
- contribution kind;
- concise human summary;
- created or changed artifact references;
- evidence and verification status;
- decisions and constraints established;
- unresolved risks or uncertainty;
- capability or dependency blocks;
- recommended recipient positions;
- raw-output provenance.

The role practice narrows allowed contribution kinds and defines profession-specific required report content. Examples include visual principles and asset references for Art Direction, audio files/timing/mood/integration constraints for Sound Design, source citations and confidence for Research, and changed behavior plus tests for Development.

Persist the full raw final output with the run for auditability, but stop using its last 6,000 characters as the next worker’s primary brief. `CompanyProductMotor` must instead build a bounded `CompanyHandoffPacket` by intersecting:

```text
previous structured report
∩ next position’s subscribed contribution kinds
∩ current assignment dependencies
```

The handoff packet includes only relevant artifacts, decisions, evidence, constraints, and blocks, while retaining source/run provenance. This prevents irrelevant programming detail from dominating creative, commercial, research, or operational work.

If a provider returns malformed structured output:

- preserve its raw output;
- create a deterministic `unstructured` report carrying only a bounded summary and provenance;
- mark required evidence as missing;
- route that deficiency to the next coordinator decision;
- never silently reinterpret the entire response as a valid cross-profession handoff.

Retain the established overall prompt-size limits. The new packet representation must be bounded before provider execution and must not regress the existing protection against oversized persisted histories.

### 5. Enforce tool boundaries and make capability blocks visible to the CEO

Extend provider session/run contracts with a `CompanyToolPolicy` and expose each registered provider/target’s enforceable capability profile to the CEO router.

Provider adapters must enforce the policy rather than relying solely on prompt compliance:

- Claude: construct an explicit `--tools` allowlist for the position and omit disallowed tools.
- OpenAI-compatible providers: register only the locally implemented tools allowed by the policy; split the current all-or-read-only tool selection into capability-based filtering.
- Codex App Server: configure web, apps/plugins, MCP servers, environments, sandbox policy, and available permission profile according to the position policy. Validate behavior against the locally generated protocol schema. Where Codex cannot suppress a built-in tool narrowly enough, use an effect-level sandbox/permission profile; do not claim a boundary that the runtime cannot enforce.
- Any provider/target unable to enforce or supply the assignment’s required capability must fail closed before the worker starts.

Introduce a persisted `CompanyCapabilityBlock` containing:

- blocked worker and position;
- assignment and requested contribution;
- required capability;
- whether it is profession-forbidden, target-unavailable, provider-unenforceable, or discovered during work;
- relevant artifacts/evidence already produced;
- suggested professions whose practice permits the capability.

A capability block is a strategic event, not an ordinary retry. It must immediately cross the existing exceptional-review boundary and be included verbatim in the CEO’s evidence. The CEO must then hire or assign a suitable profession/target, narrow the assignment, or explicitly stop the investment. It must not respond by instructing the blocked worker to cross the boundary.

Provider/tool absence for visual, audio, CAD, customer, finance, or publishing work must therefore become visible company information. The harness must not disguise it as a generic worker failure or fall back to programming.

Make persistent sessions policy-safe:

- Include the resolved tool-policy identifier in session identity.
- Permit memory sharing only between members whose resolved policies are identical.
- For previously persisted mixed-role shared groups, deterministically split future provider slots by policy while retaining old run/session provenance for inspection and cleanup.
- Never widen an existing session’s tools merely because a later worker with a different profession reuses the nominal shared group.
- Starting a new session after a policy change is expected behavior, not a recovery failure.

### 6. Update the canonical design and compatibility behavior

Revise `Documentation/live-loop-redesign.md` so “product-company orchestration” means profession-led contribution, not universal repository building. Document:

- the separation between profession, assignment, tools, and contribution;
- recipient-aware communication;
- capability-block escalation;
- the removal of Developer as the default hire;
- safe shared-session behavior;
- the fact that a valid company may create research, creative, operational, commercial, physical-design, or support outputs without source changes.

Update the README’s virtual-company description to match the new observable behavior.

Use additive optional fields and explicit decode defaults for persisted reports, handoff packets, blocks, and policy identifiers. Existing workspaces and historical runs must remain readable. Historical raw handovers remain audit records; they do not need to be rewritten into synthetic V2 reports. On resume, V2 routing begins at the next worker boundary.

Do not add migration machinery beyond what real persisted state requires. In-memory derivation and optional Codable defaults are preferred over rewriting users’ workspace files.

## Public and Internal Interface Changes

Add or extend these central contracts:

- `CompanyPositionPractice`
- `CompanyPositionPracticeCatalog`
- `CompanyCapability`
- `CompanyToolPolicy`
- `AgentProviderCapabilityProfile`
- `CompanyContributionKind`
- `CompanyWorkReport`
- `CompanyHandoffPacket`
- `CompanyCapabilityBlock`
- CEO worker-definition schema fields for contribution, capabilities, evidence, dependencies, and block conditions
- `AgentSessionRequest` and, where needed, `AgentRunRequest` with the resolved tool policy
- session-slot identity with a policy discriminator
- optional persisted report, handoff-packet, and capability-block fields on the existing run/coordinator records

Do not expose provider-specific tool names in company prompts or persisted company definitions. Position practices and CEO decisions use stable effect-level capabilities; provider adapters own the mapping to Claude, Codex, or OpenAI-compatible mechanics.

## Test and Acceptance Plan

### Catalog and prompt tests

- Assert that every existing position, including CEO, has exactly one complete practice entry.
- Assert that no worker position silently falls back to a generic Developer/build contract.
- Snapshot representative complete prompts for Developer, Art Director, Sound Designer, Researcher, Product Manager, QA Tester, Industrial Designer, Marketing Manager, and Finance Manager.
- Verify that the Art Director and Sound Designer prompts contain their own deliverables, evidence, and escalation rules and contain no universal programming instruction.
- Verify that common session instructions remain safe and role-neutral.

### Staffing and tool-policy tests

- Reject an Art Director assignment requiring source modification.
- Reject a Developer assignment requiring audio production when no audio-capable role/target is supplied.
- Accept cross-functional companies where separate specialists own code, visuals, audio, research, and acceptance.
- Verify the CEO receives registered target capability profiles and no longer defaults to Developer.
- Verify exact Claude tool allowlists, OpenAI-compatible tool registration, and Codex sandbox/configuration for representative read-only, source-editing, visual, audio, and external-research policies.
- Verify unsupported enforcement fails before execution and produces a structured capability block.

### Handover tests

- Developer → Art Director: pass the running product, relevant UI constraints, and artifact locations, but not a command to continue programming.
- Art Director → Sound Designer: pass visual mood, timing, interaction, and asset constraints relevant to sound.
- Researcher → Product Manager: pass sources, findings, confidence, and decision implications.
- QA Tester → Developer: pass reproduction steps, expected/observed behavior, and evidence.
- Marketing Manager → Sales Manager: pass positioning, audience, claims, and objections without repository-building directives.
- Keep irrelevant raw prose in the source run transcript but exclude it from the recipient packet.
- Preserve provenance and prompt bounds across hundreds of historical contributions.
- Handle malformed structured output deterministically without treating it as a valid typed contribution.

### Capability-block and recovery tests

- Simulate a Sound Designer discovering that no audio-production tool is available.
- Verify the run produces a `CompanyCapabilityBlock`, crosses the exceptional review boundary immediately, and reaches the CEO unchanged.
- Verify the motor does not retry the Sound Designer with programming instructions.
- Verify the CEO can revise the company with an appropriate target or specialist and that routing resumes from preserved evidence.
- Verify a provider with no enforceable policy fails closed rather than running with full tools.
- Verify same-policy shared sessions reuse memory, different-policy members get distinct slots, and legacy mixed groups split safely on their next run.
- Verify old persisted workspaces decode with no reports, packets, blocks, or policy identifiers and resume without rewriting historical records.

### Completion verification

Run focused suites first for the position catalog, prompts, routing, providers, persistence, and coordinator integration. Then run the repository test suite with `./scripts/test-quiet.sh`, investigating any broad-suite failures against focused reproductions rather than masking them.

Before declaring implementation complete:

- confirm `PLAN_V2.md` is byte-for-byte unchanged from the baseline commit;
- inspect the final diff for accidental universal build-first wording and unrelated changes;
- run `./scripts/build-quiet.sh`;
- verify that it installs the signed Release build at `/Applications/Codeness.app`;
- verify the installed bundle’s signature and version;
- report source/test/build/install evidence separately from any unperformed live company simulation.

## Assumptions and Fixed Decisions

- Strict tool boundaries are required. A prompt-only profession boundary is insufficient.
- When the correct profession lacks a required tool, the system exposes the block to the CEO so the company can hire or assign the right resource; it does not broaden the worker’s permissions automatically.
- All existing positions receive exact catalog entries in this refactor. New positions, a custom-role editor, and user-authored profession catalogs are outside this version.
- `Sound Designer` covers music as well as sound design for now.
- The deterministic product motor remains. This is a refactor of its inputs, outputs, and escalation semantics, not a replacement with a free-running coordinator agent.
- Structured reports supplement rather than erase raw transcripts.
- Historical workspace data remains readable, but old handovers are not retroactively rewritten.
- External communication, publishing, releases, spending, and irreversible mutations continue to require explicit authority even when the relevant profession normally performs them.
- The baseline plan commit and subsequent implementation commits remain local unless the user separately authorizes pushing or opening a pull request.
