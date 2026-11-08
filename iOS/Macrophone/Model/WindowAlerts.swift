import MacrophoneKit
import SwiftUI
import UserNotifications

/// Windows on watch (Nov 6 2026, Sameer: "have the app watch any window and alert me with a
/// notification and an image of the window for any significant state change"). The Mac does the
/// watching (Mac/App/Watch/WindowAlerts.swift); the phone puts a window on watch or off — from the
/// Window menu, a Dock icon's long press, a place's long press, Settings — shows a bell on what's
/// on watch, and posts the alert while the app is open (the notification extension does it while
/// it's closed). Every alert looks the same (`AlertNotification`), an agent's question included.
extension AppModel: LinkClientAlertsDelegate {
    func linkClient(_ client: LinkClient, alertWatches list: [AlertWatch]) {
        guard client === self.client else { return }
        if alertWatches != list { alertWatches = list }
        // Something on watch: make sure iCloud will bring its alerts while the app is closed (at
        // launch the list wasn't here yet, so the launch's check passed this by; a try that
        // failed before is tried again).
        if !list.isEmpty { Task { await AgentAlerts.shared.retryIfNeeded() } }
    }

    func linkClient(_ client: LinkClient, macAlert a: MacAlert) {
        guard client === self.client else { return }
        // A chat he wrote to goes by "When a chat answers you" (Nov 8 2026); a question by the
        // agent-alerts switch; a window he put on watch, always.
        if a.chat == true {
            guard settings.chatAnswers else { return }
        } else if a.knownKind == .asking, !settings.agentAlerts, alertWatch(for: a.ref) == nil {
            return
        }
        // Already looking at that window: he sees it.
        if sceneActive, watcher.isShowing, let t = watcher.target, t.bundleID == a.ref.bundleID,
           t.windowKey == nil || t.windowKey == a.ref.windowKey { return }
        AgentAlerts.shared.post(a)
        log.add("alert: \(a.kind)\(a.chat == true ? " (a chat)" : "") in \(a.appName)\(a.jpeg == nil ? "" : " with a picture")")
    }

    /// The Mac can watch windows for changes right now.
    var canAlert: Bool { isConnected && client.macCanAlert }

    /// The watch on this place: its window, or (an app) any of its windows.
    func alertWatch(for ref: TargetRef) -> AlertWatch? {
        guard case let .app(bid, key, _) = ref else { return nil }
        return alertWatches.first { $0.bundleID == bid && (key == nil || $0.windowKey == nil || $0.windowKey == key) }
    }

    func alertWatch(for place: PlaceOption) -> AlertWatch? {
        alertWatches.first { w in place.target.bundleID == w.bundleID }
    }

    /// Puts it on watch (an app: its front window on the Mac), or takes it off.
    func setAlertWatch(_ ref: TargetRef, on: Bool) {
        guard canAlert, case let .app(bid, key, name) = ref else { return }
        if on {
            guard alertWatch(for: ref) == nil else { return }
            // Shown at once; the Mac's list replaces it a moment later.
            alertWatches.insert(AlertWatch(ref: ref, bundleID: bid, windowKey: key, appName: name, title: name, since: Date()), at: 0)
            client.alertWatch(ref, on: true)
            Haptics.pick()
            Task { await AgentAlerts.shared.askIfNeeded(force: true) }
        } else {
            let existing = alertWatch(for: ref)
            alertWatches.removeAll { $0 == existing }
            client.alertWatch(existing?.ref ?? ref, on: false)
            Haptics.pick()
        }
    }

    func toggleAlertWatch(_ ref: TargetRef) { setAlertWatch(ref, on: alertWatch(for: ref) == nil) }
}

/// "Alert Me When It Changes" / "Stop Alerts" for a place, as a menu row (the Window menu, a
/// place's long press).
struct AlertWatchButton: View {
    @EnvironmentObject var model: AppModel
    var ref: TargetRef

    var body: some View {
        if model.canAlert, case .app = ref, !DesktopWatch.isDesktop(ref) {
            if let w = model.alertWatch(for: ref) {
                Button { model.setAlertWatch(w.ref, on: false) } label: {
                    Label("Stop Alerts", systemImage: "bell.slash")
                    Text(w.calm ? "Only when it stops changing" : "You'll hear when it changes")
                }
                .accessibilityIdentifier("alert-watch-off")
            } else {
                Button { model.setAlertWatch(ref, on: true) } label: {
                    Label("Alert Me When It Changes", systemImage: "bell.badge")
                    Text("A notification with a picture when it finishes or needs you")
                }
                .accessibilityIdentifier("alert-watch-on")
            }
        }
    }
}

/// The bell on a place that's on watch (a Dock icon, a tile).
struct AlertWatchBadge: View {
    var calm = false

    var body: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(calm ? Color(uiColor: .systemGray) : Light.gold))
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}
