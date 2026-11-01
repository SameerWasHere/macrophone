import MacrophoneKit
import SwiftUI
import UIKit

// The iPhone Duo's pose (Oct 25 2026, Sameer: "a Duo version that supports every fold option of
// the device"). The phone reads the hinge (SwiftUI's `onHingeChange`, iOS 27.1) and the fold's
// region in the scene (`reservedRegions(kind: .division)`), hands them to the shared rule
// (`FoldPose.derive`, MacrophoneKit) and keeps the answer here for every screen. A regular
// iPhone never reads a hinge and stays `.closed` — its layout is untouched.
//
// What's published is only what a layout draws from: the pose, the halves, the rise (in steps —
// `FoldPose.deckRise`). The raw reading isn't: a hinge trembling by half a degree would otherwise
// re-lay the whole main view each time (the third pass).
//
// DEBUG: `MACROPHONE_POSTURE=closed|portrait|landscape|laptop|book[@<angle>]` forces the pose
// (and a fold band in the middle of the scene), so every pose can be laid out and screenshotted
// on a simulator that can't be folded from a script.

@MainActor
final class Posture: ObservableObject {
    static let shared = Posture()

    @Published private(set) var pose: FoldPose = .closed
    /// The two halves of a folded screen (the laptop, the book); nil otherwise.
    @Published private(set) var halves: FoldHalves?
    /// How far the deck has risen as the hinge folds: 0 flat, 1 folded (`FoldPose.deckRise`).
    @Published private(set) var rise: Double = 0
    /// Bumped when the pose changes after the first one is known: a soft tick, a VoiceOver
    /// announcement (the pose the app opens in is no change he made).
    @Published private(set) var settleSeq = 0
    /// What the pose was derived from, for the log and the tests (not published: see above).
    private(set) var reading: FoldReading = .none
    /// The pose before this one (what to restore on the way back).
    private(set) var previous: FoldPose = .closed
    var log: DiagnosticLog?

    private var hinge: HingeStatus?
    private var angle: Double = 180
    private var size: CGSize = .zero
    private var screen: CGSize = .zero
    private var division: FoldDivision?
    private var derivedOnce = false

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

    /// The hinge, as SwiftUI reports it (nil: no hinge in this hierarchy). The angle only matters
    /// in the rise's steps, so a reading that changes neither the status nor the step is dropped
    /// here, before anything is published.
    func hinge(_ status: HingeStatus?, angle: Double) {
        let stepped = FoldPose.deckRise(angle: angle) != FoldPose.deckRise(angle: self.angle)
        guard status != hinge || stepped else { self.angle = angle; return }
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

    /// The whole screen the scene is on (the system's bars included): which screen it is.
    func screen(size: CGSize) {
        guard size != screen else { return }
        screen = size
        recompute()
    }

    private func recompute() {
        var r = FoldReading(hinge: hinge, angle: angle, size: size, division: division, screen: screen)
        #if DEBUG
        if let f = Self.forced {
            r.hinge = f.pose == .closed ? .closed : f.pose.isFolded ? .partiallyOpen : .fullyOpen
            r.angle = f.angle
            // The inner screen is drawn to scale on the cover: the scene's size is the one to go by.
            r.screen = .zero
            // A band stands for the fold, at the *screen's* middle (the frame's bars are stood
            // in for, so the scene starts under them): across it when the frame is upright
            // (the laptop, flat portrait), down it on its side (the book, flat landscape) —
            // active while folded, there but inactive when flat, as the real region is.
            if size != .zero, f.pose.isInner {
                let w = FoldHalves.defaultFold
                let insets = DebugHooks.frameInsets ?? EdgeInsets()
                let screen = DebugHooks.frame ?? size
                // The bar above the scene is whatever the frame leaves now (the laptop in hand
                // gives the status bar's room back): read off the scene's own height, so the
                // fold stays at the screen's middle either way.
                let top = max(0, screen.height - size.height - insets.bottom)
                let frame = f.pose.foldAcross ? CGRect(x: 0, y: screen.height / 2 - top - w / 2, width: size.width, height: w)
                                              : CGRect(x: screen.width / 2 - insets.leading - w / 2, y: 0, width: w, height: size.height)
                r.division = FoldDivision(frame: frame, isActive: f.pose.isFolded)
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
        if derivedOnce { settleSeq &+= 1 }
        log?.add("pose: \(p.name) (\(Int(r.angle))°, \(Int(r.size.width))×\(Int(r.size.height)) on \(Int(r.screen.width))×\(Int(r.screen.height)))")
        // The first pose derived after the first measure is the one the app opened in.
        if size != .zero { derivedOnce = true }
    }

    /// The fold's line in the scene even when the screen is flat (the inactive region): what an
    /// open layout keeps its controls clear of. Nil on a phone with no fold.
    var foldLine: CGRect? {
        guard let d = reading.division, pose.isInner else { return nil }
        return d.frame
    }

    /// The two halves either side of the fold for a layout laid out as the laptop or the book,
    /// folded or flat (Nov 1 2026: the open screen upright is the laptop laid flat): the
    /// layout's own size split at the fold's region (active or not), else at its middle. The
    /// layout's size, not the scene's: on the phone they are one and the same, but in the
    /// simulator's frame a NavigationStack draws its own vertical bar inside the scene, and a
    /// page measured from the scene ran under it.
    func halves(for pose: FoldPose, in size: CGSize) -> FoldHalves {
        FoldHalves.split(size, pose: pose, division: reading.division)
            ?? FoldHalves(mac: CGRect(origin: .zero, size: size), deck: .zero)
    }
}

/// Reads the hinge and the fold's region into `Posture` — iOS 27.1 only; older systems and
/// regular iPhones pass through untouched. The scene is measured with the keyboard ignored (a
/// folded layout never shrinks for it) in a layer of its own, so the content keeps the keyboard
/// avoidance it always had on the phone: the window view moves up over the keyboard page there.
struct PostureReader: ViewModifier {
    @ObservedObject var posture: Posture

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: FoldSnapshot(geo), initial: true) { _, s in posture.scene(size: s.size, division: s.division) }
                }
                .ignoresSafeArea(.keyboard)
            }
            // The whole screen, bars and all: which screen the scene is on.
            .background {
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size, initial: true) { _, s in posture.screen(size: s) }
                }
                .ignoresSafeArea()
            }
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
            // The one that splits the view, active or not; the first is the fold. Its frame is
            // in this proxy's own coordinate space, margins included (UIKit's words for the
            // same region).
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
                // No hinge: the view left a hierarchy that has one (or never had one).
                guard let h = new.hinge else { posture.hinge(nil, angle: 180); return }
                let status: HingeStatus = h.status == .closed ? .closed : h.status == .partiallyOpen ? .partiallyOpen : .fullyOpen
                // `DeviceHinge.angle` is an `Angle` (UIKit's `UIHinge.angle` is the same in radians).
                posture.hinge(status, angle: h.angle.degrees)
            }
        } else {
            content
        }
    }
}
