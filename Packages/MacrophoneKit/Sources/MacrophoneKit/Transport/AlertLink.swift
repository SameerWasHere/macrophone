import Foundation

// Alerts from the Mac on the wire (Core/MacAlerts.swift has the rules). Their own delegate
// protocols, like the undo's (UndoLink.swift).

/// The Mac app's side: the windows on watch, and a phone putting one on or off.
@MainActor
public protocol LinkServerAlertsDelegate: AnyObject {
    func alertWatches(_ server: LinkServer) -> [AlertWatch]
    func linkServer(_ server: LinkServer, alertWatch request: AlertWatchRequest, from peerID: UUID)
    /// The phone's "When a chat answers you" switch changed (ChatAnswers).
    func linkServer(_ server: LinkServer, chatAnswers on: Bool, from peerID: UUID)
}

/// The phone's side: the list of windows on watch, and an alert while the app is open.
@MainActor
public protocol LinkClientAlertsDelegate: AnyObject {
    func linkClient(_ client: LinkClient, alertWatches: [AlertWatch])
    func linkClient(_ client: LinkClient, macAlert: MacAlert)
}

extension LinkServer {
    func handleAlertWatch(_ request: AlertWatchRequest, from peerID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkServerAlertsDelegate else { return }
            d.linkServer(self, alertWatch: request, from: peerID)
        }
    }

    func handleChatAnswers(_ on: Bool, from peerID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkServerAlertsDelegate else { return }
            d.linkServer(self, chatAnswers: on, from: peerID)
        }
    }

    @MainActor func alertWatchesOnMain() -> [AlertWatch] {
        (delegate as? LinkServerAlertsDelegate)?.alertWatches(self) ?? []
    }

    /// The windows on watch changed: every phone that understands alerts hears the list.
    public func broadcastAlertWatches(_ list: [AlertWatch]) {
        for id in phones(with: MacAlerts.feature) { Task { await self.send(.alertWatches(list), to: id) } }
    }
}

extension LinkClient {
    /// The connected Mac watches windows for changes (its welcome names it).
    public var macCanAlert: Bool { macFeatures.contains(MacAlerts.feature) }

    /// Puts a window on watch, or takes it off. False when the Mac can't be asked.
    @discardableResult
    public func alertWatch(_ ref: TargetRef, on: Bool) -> Bool {
        guard macCanAlert, let s = currentSession else { return false }
        s.post(.alertWatch(AlertWatchRequest(ref: ref, on: on)))
        return true
    }

    /// The connected Mac follows chats for their answers (its welcome names it).
    public var macFollowsChats: Bool { macFeatures.contains(ChatAnswers.feature) }

    /// "When a chat answers you" changed: the next hello says so, and a Mac connected now hears
    /// it at once. False when the Mac can't be told now.
    @discardableResult
    public func setChatAnswers(_ on: Bool) -> Bool {
        features.removeAll { $0 == ChatAnswers.onWord || $0 == ChatAnswers.offWord }
        features.append(on ? ChatAnswers.onWord : ChatAnswers.offWord)
        guard macFollowsChats, let s = currentSession else { return false }
        s.post(.chatAnswers(on: on))
        return true
    }

    func deliverAlertWatches(_ list: [AlertWatch]) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientAlertsDelegate else { return }
            d.linkClient(self, alertWatches: list)
        }
    }

    func deliverMacAlert(_ a: MacAlert) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientAlertsDelegate else { return }
            d.linkClient(self, macAlert: a)
        }
    }
}
