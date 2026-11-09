import Foundation

// Answering a window's question from a notification, on the wire (Core/AlertAnswer.swift). Its
// own delegate protocol, like Undo's.

/// The Mac app's side: answer the window, and say how it went.
@MainActor
public protocol LinkServerAlertAnswerDelegate: AnyObject {
    func linkServer(_ server: LinkServer, answer: AlertAnswer, from peerID: UUID) async -> AlertAnswerResult
}

extension LinkServer {
    func handleAlertAnswer(_ answer: AlertAnswer, from peerID: UUID, on session: SecureSession) {
        Task { [weak self] in
            guard let self, let result = await self.answerOnMain(answer, from: peerID) else { return }
            try? await session.send(.alertAnswerDone(result))
        }
    }

    @MainActor private func answerOnMain(_ answer: AlertAnswer, from peerID: UUID) async -> AlertAnswerResult? {
        guard let d = delegate as? LinkServerAlertAnswerDelegate else { return nil }
        return await d.linkServer(self, answer: answer, from: peerID)
    }
}

extension LinkClient {
    /// The connected Mac answers a question for a phone that isn't watching the window.
    public var macCanAnswerAlerts: Bool { macFeatures.contains(AlertAnswers.feature) }

    /// Asks the Mac to answer, and waits for its word (nil: not connected, a Mac from before, or
    /// no answer in `timeout`).
    public func answerAlert(_ answer: AlertAnswer, timeout: TimeInterval = 10) async -> AlertAnswerResult? {
        guard macCanAnswerAlerts, let s = currentSession else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<AlertAnswerResult?, Never>) in
            let waiter = AnswerWaiter(c)
            answerWaiters.sync { $0.append(waiter) }
            s.post(.alertAnswer(answer))
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                waiter.resume(nil)
            }
        }
    }

    func deliverAlertAnswer(_ r: AlertAnswerResult) {
        let waiter: AnswerWaiter? = answerWaiters.sync { $0.isEmpty ? nil : $0.removeFirst() }
        waiter?.resume(r)
    }
}

/// One answer being waited for; resumed once.
final class AnswerWaiter: @unchecked Sendable {
    private var continuation: CheckedContinuation<AlertAnswerResult?, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<AlertAnswerResult?, Never>) { continuation = c }
    func resume(_ r: AlertAnswerResult?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: r)
    }
}

/// The waiters, behind a lock.
final class AnswerWaiters: @unchecked Sendable {
    private var list: [AnswerWaiter] = []
    private let lock = NSLock()
    func sync<T>(_ body: (inout [AnswerWaiter]) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&list) }
}
