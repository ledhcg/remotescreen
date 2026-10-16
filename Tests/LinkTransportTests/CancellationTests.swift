import Foundation
import Testing
@testable import LinkTransport

/// Every wait in the transport ends when its task is cancelled. Before, a cancelled `OneShot.wait` or `LinkInbox` read
/// waited for a value that might never come, so neither `.timeLimit`, `Task.cancel()` nor a session shutdown could stop
/// it (a test process was found still waiting after 16 hours).
@Suite(.timeLimit(.minutes(1))) struct CancellationTests {
    /// Runs `body` in a task, cancels it after a moment, and returns how long the task took to end.
    private func timeToEndAfterCancel(_ body: @escaping @Sendable () async -> Void) async -> Duration {
        let task = Task { await body() }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        await task.value
        return ContinuousClock.now - start
    }

    @Test func aCancelledOneShotWaiterStopsWaiting() async throws {
        let gate = OneShot<Int>()
        let outcome = OneShot<String>()
        let elapsed = await timeToEndAfterCancel {
            do { _ = try await gate.wait(); outcome.complete(.success("value")) }
            catch is CancellationError { outcome.complete(.success("cancelled")) }
            catch { outcome.complete(.success("other")) }
        }
        #expect(elapsed < .seconds(1))
        #expect(try await outcome.wait() == "cancelled")
        // The gate still works for others afterwards.
        gate.complete(.success(7))
        #expect(try await gate.wait() == 7)
    }

    @Test func aOneShotWaiterCancelledBeforeWaitingDoesNotSuspend() async {
        let gate = OneShot<Int>()
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await gate.wait(); return false } catch { return error is CancellationError }
        }
        #expect(await task.value)
    }

    @Test func aCancelledInboxReaderEndsItsLoop() async {
        let inbox = LinkInbox<Int>()
        let elapsed = await timeToEndAfterCancel {
            for await _ in inbox {}
        }
        #expect(elapsed < .seconds(1))
    }

    @Test func aCancelledProducerStopsWaitingForRoom() async {
        // `push` returns once its element fits and waits while the inbox is full after adding it: the second push waits.
        let inbox = LinkInbox<Int>(capacity: 2)
        await inbox.push(1, cost: 1)
        let elapsed = await timeToEndAfterCancel { await inbox.push(2, cost: 1) }
        #expect(elapsed < .seconds(1))
        // What was pushed before is still delivered, in order.
        var it = inbox.makeAsyncIterator()
        #expect(await it.next() == 1)
    }

    @Test func manyWaitersCancelledAtRandomNeverHang() async {
        let gate = OneShot<Int>()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let task = Task { _ = try? await gate.wait() }
                    if i.isMultiple(of: 2) { task.cancel() }
                    await task.value
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
            gate.complete(.success(1)) // ends the waiters that were not cancelled
        }
    }
}
