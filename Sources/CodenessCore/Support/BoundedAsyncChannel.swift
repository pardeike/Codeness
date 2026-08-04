import Foundation

enum BoundedChannelSendResult: Sendable, Equatable {
    case accepted
    case full
    case terminated
}

/// A single logical FIFO with bounded producer-side storage.
///
/// `send` suspends when the buffer is full instead of allowing an `AsyncStream`
/// continuation to accumulate an unbounded backlog. `stream()` uses the
/// demand-driven unfolding initializer, so it adds no second continuation
/// buffer between this channel and its consumer.
actor BoundedAsyncChannel<Element: Sendable> {
    private enum State {
        case open
        case finishing
        case cancelled
    }

    private struct PendingSend {
        let id: UUID
        let element: Element
        let retainedCost: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct PendingReceive {
        let id: UUID
        let continuation: CheckedContinuation<Element?, Never>
    }

    private struct BufferedElement {
        let element: Element
        let retainedCost: Int
    }

    private let capacity: Int
    private let maximumRetainedCost: Int
    private let retainedCost: @Sendable (Element) -> Int
    private var state = State.open
    private var buffer: [BufferedElement] = []
    private var bufferedRetainedCost = 0
    private var pendingSends: [PendingSend] = []
    private var pendingSendRetainedCost = 0
    private var pendingReceives: [PendingReceive] = []

    init(
        capacity: Int,
        maximumRetainedCost: Int? = nil,
        retainedCost: @escaping @Sendable (Element) -> Int = { _ in 1 }
    ) {
        precondition(capacity > 0, "A bounded channel needs positive capacity.")
        let resolvedMaximumRetainedCost = maximumRetainedCost ?? capacity
        precondition(
            resolvedMaximumRetainedCost > 0,
            "A bounded channel needs a positive retained-cost limit."
        )
        self.capacity = capacity
        self.maximumRetainedCost = resolvedMaximumRetainedCost
        self.retainedCost = retainedCost
        buffer.reserveCapacity(capacity)
    }

    /// Enqueues a value in FIFO order, suspending while the channel is full.
    /// Returns `false` if the caller is cancelled before admission or the
    /// channel is no longer accepting values.
    func send(_ element: Element) async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                enqueueSend(
                    PendingSend(
                        id: id,
                        element: element,
                        retainedCost: normalizedRetainedCost(of: element),
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelSend(id: id) }
        }
    }

    /// Attempts immediate FIFO admission without suspending for capacity.
    /// This is intended for producers that must fail a higher-level operation
    /// explicitly instead of allowing one abandoned consumer to stall an
    /// unrelated event pump.
    func trySend(_ element: Element) -> BoundedChannelSendResult {
        guard state == .open else { return .terminated }
        guard pendingSends.isEmpty else { return .full }
        let cost = normalizedRetainedCost(of: element)
        guard cost <= maximumRetainedCost else { return .full }

        if let receive = popNextReceive() {
            receive.continuation.resume(returning: element)
            return .accepted
        }
        guard canBufferOrdinaryElement(cost: cost) else { return .full }
        appendToBuffer(element, retainedCost: cost)
        return .accepted
    }

    /// Discards queued or suspended values matching a lifecycle predicate.
    /// Remaining values retain FIFO order. Removed suspended producers are
    /// resumed with `false`, then newly available capacity is offered to the
    /// oldest surviving producers.
    @discardableResult
    func discard(where shouldDiscard: @Sendable (Element) -> Bool) -> Int {
        var discardedCount = 0
        var retainedBuffer: [BufferedElement] = []
        retainedBuffer.reserveCapacity(buffer.count)
        for buffered in buffer {
            if shouldDiscard(buffered.element) {
                bufferedRetainedCost -= buffered.retainedCost
                discardedCount += 1
            } else {
                retainedBuffer.append(buffered)
            }
        }
        buffer = retainedBuffer

        var retainedSends: [PendingSend] = []
        retainedSends.reserveCapacity(pendingSends.count)
        for send in pendingSends {
            if shouldDiscard(send.element) {
                pendingSendRetainedCost -= send.retainedCost
                send.continuation.resume(returning: false)
                discardedCount += 1
            } else {
                retainedSends.append(send)
            }
        }
        pendingSends = retainedSends

        while !pendingSends.isEmpty,
              canBufferOrdinaryElement(cost: pendingSends[0].retainedCost) {
            admitNextSenderIfPossible()
        }
        finishReceiversIfDrained()
        return discardedCount
    }

    /// Rejects producers already suspended on capacity without discarding
    /// values that were admitted. Lifecycle pause mode uses this to convert an
    /// existing backpressure wait into an explicit generation-containment
    /// result before AppModel stops consuming the channel.
    func rejectPendingSends() {
        let sends = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        pendingSendRetainedCost = 0
        sends.forEach { $0.continuation.resume(returning: false) }
    }

    func testingBufferedCount() -> Int {
        buffer.count
    }

    /// Returns the next value, or `nil` once a finished channel has drained.
    func next() async -> Element? {
        guard !Task.isCancelled else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                enqueueReceive(PendingReceive(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelReceive(id: id) }
        }
    }

    /// Stops accepting new values and drains every value already admitted.
    func finish() {
        guard state == .open else { return }
        state = .finishing

        let sends = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        pendingSendRetainedCost = 0
        sends.forEach { $0.continuation.resume(returning: false) }
        finishReceiversIfDrained()
    }

    /// Atomically appends a final value and closes the producer side. The
    /// channel reserves one extra terminal slot for this operation, so teardown
    /// can never deadlock behind a full buffer and never has to discard an
    /// already-admitted value.
    @discardableResult
    func finish(with finalElement: Element) -> Bool {
        guard state == .open else { return false }
        let cost = normalizedRetainedCost(of: finalElement)
        guard cost <= maximumRetainedCost else { return false }
        state = .finishing

        let sends = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        pendingSendRetainedCost = 0
        sends.forEach { $0.continuation.resume(returning: false) }

        if buffer.isEmpty, let receive = popNextReceive() {
            receive.continuation.resume(returning: finalElement)
        } else {
            // One explicit terminal reserve above `capacity`; still bounded.
            appendToBuffer(finalElement, retainedCost: cost)
        }
        finishReceiversIfDrained()
        return true
    }

    /// Admits a generation-ending value without suspension, even when the
    /// ordinary buffer is full. Pending ordinary sends are rejected so an old
    /// generation cannot resume after its terminal. Two reserved slots (a
    /// diagnostic followed by an exit) keep
    /// teardown bounded while allowing process cleanup and restart to proceed
    /// independently of a temporarily stalled consumer.
    @discardableResult
    func sendForTeardown(_ finalElement: Element) -> Bool {
        guard state == .open else { return false }
        let cost = normalizedRetainedCost(of: finalElement)
        guard cost <= maximumRetainedCost else { return false }
        let sends = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        pendingSendRetainedCost = 0
        sends.forEach { $0.continuation.resume(returning: false) }

        if buffer.isEmpty, let receive = popNextReceive() {
            receive.continuation.resume(returning: finalElement)
            return true
        }
        guard buffer.count < capacity + 2 else { return false }
        appendToBuffer(finalElement, retainedCost: cost)
        return true
    }

    /// Ends the channel immediately. Intended for bounded teardown only.
    func cancel() {
        guard state != .cancelled else { return }
        state = .cancelled
        buffer.removeAll(keepingCapacity: false)
        bufferedRetainedCost = 0

        let sends = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        pendingSendRetainedCost = 0
        sends.forEach { $0.continuation.resume(returning: false) }

        let receives = pendingReceives
        pendingReceives.removeAll(keepingCapacity: false)
        receives.forEach { $0.continuation.resume(returning: nil) }
    }

    /// A demand-driven view with no additional `AsyncStream` continuation
    /// buffer. Multiple iterators share this channel, matching AsyncStream's
    /// single logical sequence semantics.
    nonisolated func stream(
        cancelChannelOnConsumerCancellation: Bool = false,
        onConsumerCancellation: (@Sendable () async -> Void)? = nil
    ) -> AsyncStream<Element> {
        AsyncStream(
            unfolding: { await self.next() },
            onCancel: {
                guard cancelChannelOnConsumerCancellation || onConsumerCancellation != nil else {
                    return
                }
                Task {
                    if cancelChannelOnConsumerCancellation {
                        await self.cancel()
                    }
                    await onConsumerCancellation?()
                }
            }
        )
    }

    private func enqueueSend(_ send: PendingSend) {
        if state != .open {
            send.continuation.resume(returning: false)
            return
        }

        guard send.retainedCost <= maximumRetainedCost else {
            send.continuation.resume(returning: false)
            return
        }

        if let receive = popNextReceive() {
            receive.continuation.resume(returning: send.element)
            send.continuation.resume(returning: true)
            return
        }

        if canBufferOrdinaryElement(cost: send.retainedCost) {
            appendToBuffer(
                send.element,
                retainedCost: send.retainedCost
            )
            send.continuation.resume(returning: true)
            return
        }

        // Suspended callers retain their elements too. Bound that side of the
        // channel as well; callers receive an explicit `false` admission result
        // and can fail closed instead of silently accumulating memory.
        guard pendingSends.count < capacity,
              pendingSendRetainedCost <= maximumRetainedCost - send.retainedCost else {
            send.continuation.resume(returning: false)
            return
        }
        pendingSends.append(send)
        pendingSendRetainedCost += send.retainedCost
    }

    private func enqueueReceive(_ receive: PendingReceive) {
        if state == .cancelled {
            receive.continuation.resume(returning: nil)
            return
        }

        if !buffer.isEmpty {
            let buffered = buffer.removeFirst()
            bufferedRetainedCost -= buffered.retainedCost
            admitNextSenderIfPossible()
            receive.continuation.resume(returning: buffered.element)
            finishReceiversIfDrained()
            return
        }

        if state == .finishing {
            receive.continuation.resume(returning: nil)
            return
        }

        pendingReceives.append(receive)
    }

    private func cancelSend(id: UUID) {
        guard let index = pendingSends.firstIndex(where: { $0.id == id }) else {
            return
        }
        let send = pendingSends.remove(at: index)
        pendingSendRetainedCost -= send.retainedCost
        send.continuation.resume(returning: false)
    }

    private func cancelReceive(id: UUID) {
        guard let index = pendingReceives.firstIndex(where: { $0.id == id }) else {
            return
        }
        let receive = pendingReceives.remove(at: index)
        receive.continuation.resume(returning: nil)
    }

    private func popNextReceive() -> PendingReceive? {
        guard !pendingReceives.isEmpty else { return nil }
        return pendingReceives.removeFirst()
    }

    private func admitNextSenderIfPossible() {
        guard state == .open else { return }
        guard !pendingSends.isEmpty else { return }
        guard canBufferOrdinaryElement(cost: pendingSends[0].retainedCost) else { return }
        let send = pendingSends.removeFirst()
        pendingSendRetainedCost -= send.retainedCost
        appendToBuffer(
            send.element,
            retainedCost: send.retainedCost
        )
        send.continuation.resume(returning: true)
    }

    private func finishReceiversIfDrained() {
        guard state == .finishing, buffer.isEmpty else { return }
        let receives = pendingReceives
        pendingReceives.removeAll(keepingCapacity: false)
        receives.forEach { $0.continuation.resume(returning: nil) }
    }

    private func normalizedRetainedCost(of element: Element) -> Int {
        max(1, retainedCost(element))
    }

    private func canBufferOrdinaryElement(cost: Int) -> Bool {
        guard cost <= maximumRetainedCost else { return false }
        return buffer.count < capacity
            && bufferedRetainedCost <= maximumRetainedCost - cost
    }

    private func appendToBuffer(
        _ element: Element,
        retainedCost: Int
    ) {
        buffer.append(BufferedElement(
            element: element,
            retainedCost: retainedCost
        ))
        bufferedRetainedCost += retainedCost
    }
}
