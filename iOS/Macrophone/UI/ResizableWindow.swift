import SwiftUI

// The window as a window (Nov 8 2026). Sameer: "remove the borders of a window … more that that
// window is just viewable on my iPhone and ready to interact with", then "the window can take up
// the max space possible and the user can resize the window as they want with the space
// available on their phone".
//
// The window opens taking all the room the window view has. A corner arc just outside its
// bottom-right corner — iPad's Stage Manager handle — resizes it: the width round the middle,
// the height from the top down. While the finger is on it the picture keeps its zoom and the
// window's edge moves over it; let go and the Mac's window takes that shape (it comes back with
// its words re-flowed for it) and the picture settles to fit. A double tap on the arc gives it
// all the room again. The principle (Sameer, the same day): "when an app is opened … resized on
// the Mac to be as big as possible on the current iPhone display. But the user should have the
// ability to resize the window as they want to" — so every window opens at all the room, and a
// size he gives it lasts while it's open, never into the next open. What's left round a smaller
// window is the Mac's wallpaper.

extension EnvironmentValues {
    /// A finger is on the window's resize corner: the viewer keeps its zoom.
    @Entry var watchResizing = false
}

struct ResizableWindow<Content: View>: View {
    @ObservedObject var watcher: Watcher
    /// Off where the window must fill its room (the keyboard up on the cover, a hidden panel).
    var enabled: Bool
    @ViewBuilder var content: Content

    /// The room the window may take.
    @State private var room: CGSize = .zero
    /// The window's size as fractions of the room (width, height): all of it at every open.
    @State private var share = CGSize(width: 1, height: 1)
    /// While dragging: the share the drag started from, and the share now.
    @State private var start: CGSize?
    @State private var live: CGSize?
    @State private var snapped = true
    /// A finger is on the arc. SwiftUI resets it when the drag ends *or is cancelled* (the system
    /// took the touch, the arc left mid-drag) — `onEnded` alone never hears a cancel, which left
    /// `live` set and the watcher believing a resize was still under way: nothing reshaped the
    /// window again until the next drag.
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var minWidth: CGFloat { 0.5 }
    static var minHeight: CGFloat { 0.35 }

    /// A new open, another window, full screen (in or out) or another pose (a fold, a turn): all
    /// the room again — a new space starts as big as it can be.
    private var opening: String { "\(watcher.isOpen)-\(watcher.windowSeq)-\(watcher.fullScreen)-\(watcher.input.pose.name)-\(watcher.target.map { "\($0)" } ?? "")" }
    private var shown: CGSize { enabled ? (live ?? share) : CGSize(width: 1, height: 1) }
    /// What of the picture shows inside the frame (the viewer says): the arc sits on its corner
    /// when the window sits smaller than its frame (one the Mac can't reshape to it).
    @State private var picture: CGRect = .zero
    /// The picture covered the frame as the drag began (he had zoomed in): the arc keeps to the
    /// frame's corner through the drag.
    @State private var zoomedAtStart = false
    /// The picture's own shape, for the fitted corner mid-drag.
    private var pictureAspect: CGSize? {
        let s = watcher.videoSize ?? watcher.image?.size ?? watcher.lastPicture?.size
        return s.map { $0.width > 0 && $0.height > 0 } == true ? s : nil
    }

    var body: some View {
        let f = shown
        let measured = room.width > 0 && room.height > 0
        let frame = CGSize(width: measured ? room.width * f.width : 0, height: measured ? room.height * f.height : 0)
        // Where the arc goes: the window's own bottom-right corner — the picture's, never the
        // frame's (Nov 9 2026: the outline hugs the picture shown). During the drag the picture
        // is fitted in the frame (`ViewerScrollView.fittedRect`, the viewer's own rule), so its
        // corner is known in this very pass — never a frame behind the finger; a window he had
        // zoomed in covers the frame, so the frame's corner then. At rest, the viewer reports it.
        let corner = arcCorner(frame: frame)
        Color.clear
            .onGeometryChange(for: CGSize.self) { $0.size } action: { room = $0 }
            .overlay(alignment: .top) {
                content
                    .frame(width: measured ? frame.width : nil, height: measured ? frame.height : nil)
                    .overlay(alignment: .topLeading) {
                        if handleShown, measured {
                            // (Its 34 pt touch square centred 3 pt in from the corner: 20 in, 14 out.)
                            handle
                                .position(x: corner.x - 3, y: corner.y - 3)
                                .transition(.opacity)
                        }
                    }
            }
            .onPreferenceChange(WindowPictureKey.self) { r in picture = r }
            .environment(\.watchResizing, live != nil)
            .onChange(of: opening) { _, _ in
                share = CGSize(width: 1, height: 1)
                watcher.shrunkHere = false
            }
            .onChange(of: live != nil) { _, on in watcher.resizingHere = on }
            .onChange(of: touching) { _, on in if !on { endDrag() } }
            .onChange(of: handleShown) { _, on in if !on { endDrag() } }
            .onDisappear { if live != nil { watcher.resizingHere = false } }
            .animation(.easeOut(duration: 0.2), value: watcher.phase == .live)
            .animation(live != nil || reduceMotion ? nil : .easeInOut(duration: 0.25), value: picture)
    }

    /// The arc shows on a live (or held) window where it may be resized.
    private var handleShown: Bool { enabled && (watcher.phase == .live || watcher.phase == .reconnecting) }

    /// The drag is over — let go, or cancelled: the size it reached is the window's.
    private func endDrag() {
        guard start != nil || live != nil else { return }
        let final = live ?? share
        start = nil
        live = nil
        commit(final, haptic: false)
    }

    // MARK: The corner

    /// The window's bottom-right corner inside a frame of this size (see `body`).
    private func arcCorner(frame: CGSize) -> CGPoint {
        if live != nil, let aspect = pictureAspect, !zoomedAtStart {
            let fitted = ViewerScrollView.fittedRect(aspect, in: CGRect(origin: .zero, size: frame))
            return fitted == .zero ? CGPoint(x: frame.width, y: frame.height) : CGPoint(x: fitted.maxX, y: fitted.maxY)
        }
        if live != nil || picture == .zero { return CGPoint(x: frame.width, y: frame.height) }
        return CGPoint(x: min(picture.maxX, frame.width), y: min(picture.maxY, frame.height))
    }

    /// The arc, its touch area centred on the window's corner: placed by its centre (`position`).
    private var handle: some View {
        CornerArc()
            .stroke(Ink.ink.opacity(live != nil ? 0.55 : 0.32), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            .frame(width: 22, height: 22)
            .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
            // The arc's bend sits 5 pt outside the corner (clear of the row 8 pt below); its
            // touch area reaches 20 pt in over the window's own resize corner and 14 pt out.
            .offset(x: -3, y: -3)
            .frame(width: 34, height: 34, alignment: .center)
            .contentShape(Rectangle())
            .gesture(resize)
            .simultaneousGesture(TapGesture(count: 2).onEnded { fillRoom() })
            .accessibilityElement()
            .accessibilityLabel("Resize window")
            .accessibilityValue("\(Int((share.width * share.height * 100).rounded())) percent of the space")
            .accessibilityHint("Drag to make the window smaller or larger. Double-tap to use all the space.")
            .accessibilityAdjustableAction { dir in
                let step: CGFloat = dir == .increment ? 0.1 : -0.1
                let next = clamp(CGSize(width: share.width + step, height: share.height + step))
                commit(next)
            }
            .accessibilityAction(named: "Use all the space") { fillRoom() }
            .accessibilityIdentifier("watch-resize")
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($touching) { _, on, _ in on = true }
            .onChanged { v in
                if start == nil {
                    start = share
                    snapped = share == CGSize(width: 1, height: 1)
                    // Zoomed in: the picture reaches the frame's edges (within a point or two).
                    let f = CGSize(width: room.width * share.width, height: room.height * share.height)
                    zoomedAtStart = picture != .zero && picture.width >= f.width - 2 && picture.height >= f.height - 2
                    Haptics.grab()
                }
                guard let s = start, room.width > 0, room.height > 0 else { return }
                // The width grows both ways round the middle; the height down from the top.
                var next = CGSize(width: s.width + 2 * v.translation.width / room.width,
                                  height: s.height + v.translation.height / room.height)
                next = clamp(next)
                // Within a few points of all the room: all of it, with a tick.
                let full = (1 - next.width) * room.width < 14 && (1 - next.height) * room.height < 14
                if full { next = CGSize(width: 1, height: 1) }
                if full != snapped { snapped = full; if full { Haptics.pick() } }
                live = next
                // The Mac's window follows the finger (Nov 9 2026): the frame's shape goes every
                // ~90 ms while it moves, applied at once there, so the app reflows under the finger.
                watcher.resizingShape(CGSize(width: room.width * next.width, height: room.height * next.height))
            }
            .onEnded { _ in endDrag() }
    }

    private func clamp(_ s: CGSize) -> CGSize {
        CGSize(width: min(1, max(Self.minWidth, s.width)), height: min(1, max(Self.minHeight, s.height)))
    }

    private func fillRoom() {
        guard share != CGSize(width: 1, height: 1) else { return }
        withAnimation(reduceMotion ? nil : Motion.settle) { commit(CGSize(width: 1, height: 1)) }
    }

    /// The new size, given to the Mac's window.
    private func commit(_ s: CGSize, haptic: Bool = true) {
        share = s
        watcher.shrunkHere = s != CGSize(width: 1, height: 1)
        if haptic { Haptics.pick() }
        guard room.width > 0, room.height > 0 else { return }
        watcher.resizedHere(CGSize(width: room.width * s.width, height: room.height * s.height))
    }
}

/// Stage Manager's handle: an L round the window's corner, its bend rounded.
private struct CornerArc: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let bend: CGFloat = 8
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - bend, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - bend), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
