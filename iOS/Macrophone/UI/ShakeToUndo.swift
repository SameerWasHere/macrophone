import SwiftUI
import UIKit

/// Shake to Undo (Nov 7 2026, round 2: "Undo kept longer … by shaking"). While the landed pill or
/// the Undo chip is up, a shake asks "Undo Paste into ‹App›?" with Undo / Cancel — iOS's own
/// convention, honoured only while the system's Shake to Undo setting is on
/// (`UIAccessibility.isShakeToUndoEnabled`). The motion event is heard at the end of the responder
/// chain (`AppDelegate`, a `UIResponder`), so nothing takes first responder from the keyboard's
/// field or `HardwareKeysView`; a text field that holds the keyboard keeps its own shake. The
/// alert is UIKit's, presented over whatever is up — a sheet included.
@MainActor
enum ShakeToUndo {
    private static weak var alert: UIAlertController?

    /// The phone was shaken (or the DEBUG hook `shake` stood in for it).
    static func shaken() {
        guard UIAccessibility.isShakeToUndoEnabled, alert == nil else { return }
        let model = AppModel.shared
        guard let u = model.undoable, model.canUndo(u.id), model.landedChip?.id == u.id,
              model.landedChip?.undoing != true, let top = topController() else { return }
        let a = UIAlertController(title: "Undo Paste into \(u.appName)?", message: nil, preferredStyle: .alert)
        let undo = UIAlertAction(title: "Undo", style: .default) { _ in model.undo(id: u.id) }
        a.addAction(undo)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.preferredAction = undo
        a.view.accessibilityIdentifier = "shake-undo"
        alert = a
        top.present(a, animated: true)
        model.log.add("shake: asked to undo")
    }

    /// Whatever is in front: the main screen, or the sheet over it.
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.keyWindow
        var vc = window?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
}

extension AppDelegate {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { ShakeToUndo.shaken() } else { super.motionEnded(motion, with: event) }
    }
}
