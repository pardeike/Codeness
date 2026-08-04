import Foundation
import Testing
@testable import CodenessCore

@Suite(.serialized)
struct BoundedAsyncChannelTests {
    @Test
    func weightedAdmissionBoundsLargeElementsBeforeCountCapacity() async {
        let channel = BoundedAsyncChannel<Int>(
            capacity: 8,
            maximumRetainedCost: 10,
            retainedCost: { $0 }
        )

        #expect(await channel.trySend(6) == .accepted)
        #expect(await channel.trySend(5) == .full)
        #expect(await channel.next() == 6)
        #expect(await channel.trySend(5) == .accepted)
        #expect(await channel.next() == 5)
    }

    @Test
    func nonblockingAdmissionPreservesPendingSenderFIFO() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 1)
        #expect(await channel.trySend(1) == .accepted)

        let pending = Task { await channel.send(2) }
        await Task.yield()
        #expect(await channel.trySend(3) == .full)
        #expect(await channel.next() == 1)
        #expect(await pending.value)
        #expect(await channel.next() == 2)
    }

    @Test
    func cancellationBeforeAdmissionDoesNotLeaveAQueuedElement() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 1)
        #expect(await channel.trySend(1) == .accepted)

        let cancelled = Task { await channel.send(2) }
        cancelled.cancel()
        #expect(!(await cancelled.value))
        #expect(await channel.next() == 1)
        #expect(await channel.trySend(3) == .accepted)
        #expect(await channel.next() == 3)
    }

    @Test
    func terminalReserveDoesNotDiscardAnAcceptedElement() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 1)
        #expect(await channel.trySend(1) == .accepted)
        #expect(await channel.finish(with: 2))

        #expect(await channel.next() == 1)
        #expect(await channel.next() == 2)
        #expect(await channel.next() == nil)
        #expect(await channel.trySend(3) == .terminated)
    }

    @Test
    func discardRemovesMatchingBufferedAndPendingValuesWithoutReorderingSurvivors() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 2)
        #expect(await channel.trySend(1) == .accepted)
        #expect(await channel.trySend(2) == .accepted)
        let pendingOld = Task { await channel.send(3) }
        let pendingCurrent = Task { await channel.send(4) }
        await Task.yield()

        #expect(await channel.discard(where: { $0 < 4 }) == 3)
        #expect(!(await pendingOld.value))
        #expect(await pendingCurrent.value)
        #expect(await channel.next() == 4)
    }
}
