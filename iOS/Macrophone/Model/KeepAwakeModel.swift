import Foundation
import MacrophoneKit
import SwiftUI

/// Keep Awake on the phone (Nov 7 2026): what the Mac says (feature `keepAwake` — after the
/// welcome and on every change), kept per Mac so Control Center opens on the last state before the
/// Mac answers, and the requests (on, off, the displays). A tap shows its result at once and
/// settles to the Mac's answer; with no answer in 6 s it goes back and says so.
@MainActor
final class KeepAwakeModel: ObservableObject {
    static let shared = KeepAwakeModel()

    /// Each Mac's Keep Awake as it last said.
    @Published private(set) var statuses: [UUID: KeepAwakeStatus] = [:]
    /// A tap waiting for the Mac: what it asked for.
    @Published private(set) var pending: KeepAwakeRequest.Action?
    private var pendingTask: Task<Void, Never>?

    func status(of macID: UUID?) -> KeepAwakeStatus? {
        guard let macID else { return nil }
        if let s = statuses[macID] { return s }
        guard let data = UserDefaults.standard.data(forKey: Self.key(macID)) else { return nil }
        return try? JSONDecoder().decode(KeepAwakeStatus.self, from: data)
    }

    func note(_ s: KeepAwakeStatus, macID: UUID) {
        statuses[macID] = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key(macID)) }
        // The answer came: the tap is settled (a refused one shows why in the line).
        if let p = pending {
            let settled: Bool
            switch p {
            case .on, .timer: settled = s.on || s.blocked != nil || !s.busy
            case .off: settled = !s.on || !s.busy
            case .displaysOn: settled = !s.displaysOff
            case .displaysOff: settled = s.displaysOff
            case .restoreSleep: settled = true
            }
            if settled && !s.busy { pending = nil; pendingTask?.cancel() }
        }
    }

    func forget(except macIDs: [UUID]) {
        let keep = Set(macIDs)
        for id in statuses.keys where !keep.contains(id) { statuses[id] = nil }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            if let id = UUID(uuidString: String(key.dropFirst(Self.prefix.count))), !keep.contains(id) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func asked(_ action: KeepAwakeRequest.Action, model: AppModel) {
        pending = action
        pendingTask?.cancel()
        pendingTask = Task { [weak self, weak model] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.pending != nil else { return }
            self.pending = nil
            model?.explain("Your Mac didn't answer — check it's still connected.", for: 4)
        }
    }

    private static let prefix = "mac.keepAwake."
    private static func key(_ id: UUID) -> String { prefix + id.uuidString }
}

extension AppModel {
    var keepAwake: KeepAwakeModel { KeepAwakeModel.shared }

    /// The connected Mac has Keep Awake (its welcome names it).
    var canKeepAwake: Bool { isConnected && client.macCanKeepAwake }

    /// What Control Center shows: this run's answer, else what this Mac said last time (only for a
    /// Mac that has Keep Awake — an older one shows no tile).
    var keepAwakeShown: KeepAwakeStatus? {
        guard let id = pairedMac?.id else { return nil }
        if let s = keepAwake.statuses[id] { return s }
        guard !isConnected || client.macCanKeepAwake else { return nil }
        return keepAwake.status(of: id)
    }

    func askKeepAwake(_ action: KeepAwakeRequest.Action, minutes: Int? = nil) {
        guard canKeepAwake else { explain("Connect to your Mac first"); return }
        Haptics.pick()
        if client.keepAwake(KeepAwakeRequest(action, minutes: minutes)) {
            keepAwake.asked(action, model: self)
        } else {
            explain("Connect to your Mac first")
        }
    }
}

extension AppModel: LinkClientKeepAwakeDelegate {
    func linkClient(_ client: LinkClient, keepAwake status: KeepAwakeStatus, macID: UUID) {
        guard client === self.client else { return }
        let before = keepAwake.statuses[macID]
        keepAwake.note(status, macID: macID)
        if let before, before.on != status.on || before.displaysOff != status.displaysOff {
            log.add("keep awake: \(status.on ? "on" : "off")\(status.displaysOff ? ", displays off" : "")")
        }
    }
}
