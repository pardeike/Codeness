import Foundation

public struct WorkflowHandoffContext: Sendable, Equatable {
    public let goal: String
    public let workflowName: String
    public let sourceStep: WorkflowStepSnapshot
    public let nextStepName: String?
    public let makesLoopDecision: Bool
    public let previousHandoff: WorkflowHandoff?
    public let source: String

    public init(
        goal: String,
        workflowName: String,
        sourceStep: WorkflowStepSnapshot,
        nextStepName: String?,
        makesLoopDecision: Bool,
        previousHandoff: WorkflowHandoff? = nil,
        source: String
    ) {
        self.goal = goal
        self.workflowName = workflowName
        self.sourceStep = sourceStep
        self.nextStepName = nextStepName
        self.makesLoopDecision = makesLoopDecision
        self.previousHandoff = previousHandoff
        self.source = source
    }
}

public protocol WorkflowHandoffRouting: Sendable {
    func route(
        _ context: WorkflowHandoffContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) async throws -> WorkflowHandoff

    func summarizeWork(
        _ context: WorkSummaryContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) async throws -> String
}

public extension WorkflowHandoffRouting {
    func summarizeWork(
        _ context: WorkSummaryContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) async throws -> String {
        _ = context
        _ = configuration
        _ = cwd
        throw HandoffRouterError.workSummaryUnsupported
    }
}

public actor AgentWorkflowHandoffRouter: WorkflowHandoffRouting {
    private let providers: AgentProviderRegistry

    public init(providers: AgentProviderRegistry) {
        self.providers = providers
    }

    public func route(
        _ context: WorkflowHandoffContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) async throws -> WorkflowHandoff {
        let request = AgentUtilityRequest(
            cwd: cwd,
            prompt: Self.prompt(context: context, instructions: configuration.instructions),
            target: configuration.target,
            developerInstructions: configuration.instructions,
            outputSchema: Self.outputSchema
        )
        let result = try await providers.runUtility(request)
        return try Self.decode(result.output, makesLoopDecision: context.makesLoopDecision)
    }

    public func summarizeWork(
        _ context: WorkSummaryContext,
        configuration: WorkflowCoordinatorConfiguration,
        cwd: String
    ) async throws -> String {
        let request = AgentUtilityRequest(
            cwd: cwd,
            prompt: WorkSummaryPrompt.utilityPrompt(
                context,
                coordinatorInstructions: configuration.instructions
            ),
            target: configuration.target,
            developerInstructions: configuration.instructions,
            outputSchema: WorkSummaryPrompt.outputSchema
        )
        let result = try await providers.runUtility(request)
        return try WorkSummaryPrompt.decodeUtilityOutput(result.output)
    }

    public static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "handoffText": .object([
                "type": .string("string"),
                "description": .string("Concise factual context needed by the next step.")
            ]),
            "outcome": .object([
                "type": .string("string"),
                "enum": .array(WorkflowOutcome.allCases.map { .string($0.rawValue) })
            ]),
            "runLabel": .object([
                "type": .string("string"),
                "description": .string("Short, specific label for the completed run.")
            ])
        ]),
        "required": .array([
            .string("handoffText"),
            .string("outcome"),
            .string("runLabel")
        ])
    ])

    private static func prompt(
        context: WorkflowHandoffContext,
        instructions: String
    ) -> String {
        let decisionRule = context.makesLoopDecision
            ? """
            This is the last step in the repeating loop. Set outcome to complete only if the \
            entire goal is satisfied; otherwise use continueWorkflow. Use blocked, failed, or \
            unclear only when that condition actually applies.
            """
            : """
            This is not the loop decision point. Use continueWorkflow unless the source is \
            blocked, failed, or too unclear to continue safely. A step-local completion claim \
            does not complete the workflow here.
            """
        var sections = [
            """
        \(instructions)

        Produce the structured Codeness handoff described by the output schema.

        WORKFLOW
        \(context.workflowName)

        FULL GOAL
        \(context.goal)

        SOURCE STEP
        \(context.sourceStep.name) · \(context.sourceStep.section.displayName) · loop \
        \(context.sourceStep.loopIteration)

        NEXT STEP
        \(context.nextStepName ?? "No configured step")

        DECISION RULE
        \(decisionRule)
        """
        ]
        if let previousHandoff = context.previousHandoff {
            sections.append(
                """
                PREVIOUS CUMULATIVE HANDOFF

                \(previousHandoff.text)
                """
            )
        }
        sections.append(
            """
            SOURCE RESULT

            \(context.source)
            """
        )
        sections.append(
            """
            HANDOFF CONSERVATION

            Merge the new source result with still-relevant facts from the previous cumulative \
            handoff. Do not drop unresolved requirements, plan decisions, findings, blockers, or \
            validation state merely because the latest source did not repeat them.
            """
        )
        return sections.joined(separator: "\n\n")
    }

    private static func decode(
        _ output: String,
        makesLoopDecision: Bool
    ) throws -> WorkflowHandoff {
        let clean = stripCodeFence(output)
        guard let data = clean.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let text = value["handoffText"]?.stringValue?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let rawOutcome = value["outcome"]?.stringValue,
              var outcome = WorkflowOutcome(rawValue: rawOutcome),
              let label = value["runLabel"]?.stringValue?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            throw AgentProviderError.invalidResponse(
                "the workflow coordinator did not return the required handoff JSON"
            )
        }
        if !makesLoopDecision, outcome == .complete {
            outcome = .continueWorkflow
        }
        return WorkflowHandoff(
            text: text,
            outcome: outcome,
            runLabel: String(label.prefix(100))
        )
    }

    private static func stripCodeFence(_ output: String) -> String {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("```"), clean.hasSuffix("```") else { return clean }
        var lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return clean }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }
}
