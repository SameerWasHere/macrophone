import MacrophoneKit
import SwiftUI
import UIKit

// The iPhone Duo's pose (Oct 25 2026, Sameer: "a Duo version that supports every fold option of
// the device"). The phone reads the hinge (SwiftUI's `onHingeChange`, iOS 27.1) and the fold's
// region in the scene (`reservedRegions(kind: .division)`), hands them to the shared rule
// (`FoldPose.derive`, MacrophoneKit) and keeps the answer here for every screen. A regular
// iPhone never reads a hinge and stays `.closed` — its layout is untouched.
//
// DEBUG: `MACROPHONE_POSTURE=closed|portrait|landscape|laptop|book[@<angle>]` forces the pose
// (and a fold band in the middle of the scene), so every pose can be laid out and screenshotted
// on a simulator that can't be folded from a script.

@MainActor
final class Posture: ObservableObject {
    static let shared = Posture()

    @Published private(set) var pose: FoldPose = .closed
    @Published private(set) var reading: FoldReading = .none
    /// The two halves of a folded screen (the laptop, the book); nil otherwise.
    @Published private(set) var halves: FoldHalves?
    /// How far the deck has risen as the hinge folds: 0 flat, 1 folded (`FoldPose.deckRise`).
    @Published private(set) var rise: Double = 0
    /// Bumped when the pose changes: a soft tick, a VoiceOver announcement.
    @Published private(set) var settleSeq = 0
    /// The pose before this one (what to restore on the way back).
    private(set) var previous: FoldPose = .closed
    var log: DiagnosticLog?

    private var hinge: HingeStatus?
    private var angle: Double = 180
    private var size: CGSize = .zero
    private var division: FoldDivision?

    #if DEBUG
    /// `MACROPHONE_POSTURE`: the pose, and the angle it's held at.
    struct Forced {
        var pose: FoldPose
        var angle: Double

        init?(_ spec: String?) {
            guard let spec else { return nil }
            let parts = spec.split(separator: "@").map(String.init)
            switch parts.first {
            case "closed": pose = .closed
            case "portrait": pose = .open(landscape: false)
            case "landscape": pose = .open(landscape: true)
            case "laptop": pose = .laptop
            case "book": pose = .book
            default: return nil
            }
            angle = parts.dropFirst().first.flatMap(Double.init) ?? (pose.isFolded ? 112 : pose == .closed ? 0 : 180)
        }
    }
    static let forced = Forced(DebugHooks.env["MACROPHONE_POSTURE"])
    #endif

    /// The hinge, as SwiftUI reports it (nil: no hinge in this hierarchy).
    func hinge(_ status: HingeStatus?, angle: Double) {
        guard status != hinge || abs(angle - self.angle) > 0.5 else { return }
        hinge = status
        self.angle = angle
        recompute()
    }

    /// The scene's size and the fold's region in it (read with the inactive one included, so an
    /// open screen still knows where its fold lies).
    func scene(size: CGSize, division: FoldDivision?) {
        guard size != self.size || division != self.division else { return }
        self.size = size
        self.division = division
        recompute()
    }

    private func recompute() {
        var r = FoldReading(hinge: hinge, angle: angle, size: size, division: division)
        #if DEBUG
        if let f = Self.forced {
            r.hinge = f.pose == .closed ? .closed : f.pose.isFolded ? .partiallyOpen : .fullyOpen
            r.angle = f.angle
            // A band across the middle (the laptop) or down it (the book) stands for the fold.
            if f.pose.isFolded, size != .zero {
                let w = FoldHalves.defaultFold
                let frame = f.pose == .laptop ? CGRect(x: 0, y: (size.height - w) / 2, width: size.width, height: w)
                                              : CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
                r.division = FoldDivision(frame: frame, isActive: true)
            } else if size != .zero {
                r.division = nil
            }
        }
        #endif
        let p = FoldPose.derive(r)
        reading = r
        let rise = p.isFolded ? FoldPose.deckRise(angle: r.angle) : 0
        if rise != self.rise { self.rise = rise }
        let h = FoldHalves.split(r.size, pose: p, division: r.division)
        if h != halves { halves = h }
        guard p != pose else { return }
        previous = pose
        pose = p
        settleSeq &+= 1
        log?.add("pose: \(p.name) (\(Int(r.angle))°, \(Int(r.size.width))×\(Int(r.size.height)))")
    }

    /// The fold's line in the scene even when the screen is flat (the inactive region): what an
    /// open layout keeps its controls clear of. Nil on a phone with no fold.
    var foldLine: CGRect? {
        guard let d = reading.division, pose.isInner else { return nil }
        return d.frame
    }
}

/// Reads the hinge and the fold's region into `Posture` — iOS 27.1 only; older systems and
/// regular iPhones pass through untouched.
struct PostureReader: ViewModifier {
    @ObservedObject var posture: Posture

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .onChange(of: FoldSnapshot(geo), initial: true) { _, s in posture.scene(size: s.size, division: s.division) }
        }
        .ignoresSafeArea(.keyboard)
        .modifier(HingeReader(posture: posture))
    }
}

/// The scene's size and its fold, as one Equatable value (so a change in either re-reads once).
private struct FoldSnapshot: Equatable {
    var size: CGSize
    var division: FoldDivision?

    init(_ geo: GeometryProxy) {
        size = geo.size
        if #available(iOS 27.1, *) {
            // The one that splits the view, active or not; the first is the fold.
            if let r = geo.reservedRegions(kind: .division, options: [.includeInactive]).first {
                division = FoldDivision(frame: r.frame, isActive: r.isActive)
            } else {
                division = nil
            }
        } else {
            division = nil
        }
    }
}

private struct HingeReader: ViewModifier {
    @ObservedObject var posture: Posture

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                guard let h = new.hinge else { posture.hinge(nil, angle: 180); return }
                let status: HingeStatus = h.status == .closed ? .closed : h.status == .partiallyOpen ? .partiallyOpen : .fullyOpen
                posture.hinge(status, angle: h.angle.degrees)
            }
        } else {
            content
        }
    }
}
