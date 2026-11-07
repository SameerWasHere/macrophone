import SwiftUI
import UIKit

// A subtree out of the accessibility tree (Nov 7 2026). `.accessibilityHidden(true)` hides what
// SwiftUI draws itself, but a UIKit-backed view inside it — a ScrollView, a Toggle's switch, a
// Menu's button, a UIViewRepresentable — is a UIView of its own in the hosting view, and
// VoiceOver and XCUITest still find it there: with a window in hand the Dock, Send after pasting
// and Cleanup under it were still in the tree, and the trackpad under the mic page. Two
// sentinels bracket the subtree's platform views in their common superview's order; what lies
// between them is taken out at the UIKit level too, and given back when the subtree returns.

extension View {
    /// Removes the subtree from the accessibility tree while `gone` — SwiftUI's nodes and the
    /// UIKit views inside it alike. For a subtree that is also off screen (faded out, under a
    /// window); it leaves the layout untouched and builds nothing anew.
    func accessibilityGone(_ gone: Bool) -> some View { modifier(AccessibilityGone(gone: gone)) }
}

private struct AccessibilityGone: ViewModifier {
    var gone: Bool
    @State private var pair = GonePair()

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(gone)
            .background(GoneSentinel(pair: pair, end: false, gone: gone))
            .overlay(GoneSentinel(pair: pair, end: true, gone: gone))
    }
}

/// The two sentinels' shared state: which views between them were taken out, and how they were.
@MainActor private final class GonePair {
    weak var start: UIView?
    weak var end: UIView?
    private var taken: [Taken] = []
    private var gone = false

    private struct Taken {
        weak var view: UIView?
        var elementsHidden: Bool
        var element: Bool
        var hidden: Bool
    }

    func apply(_ gone: Bool) {
        self.gone = gone
        guard gone else { giveBack(); return }
        guard let start, let end, let (parent, from, to) = Self.span(start, end) else { return }
        let subviews = parent.subviews
        guard let i = subviews.firstIndex(of: from), let j = subviews.firstIndex(of: to), i < j else { return }
        for v in subviews[(i + 1)..<j] where !taken.contains(where: { $0.view === v }) {
            taken.append(Taken(view: v, elementsHidden: v.accessibilityElementsHidden, element: v.isAccessibilityElement, hidden: v.isHidden))
            v.accessibilityElementsHidden = true
            v.isAccessibilityElement = false
            // The subtree is off screen already (faded, under a window): hidden at the UIKit
            // level too, which is the one flag every accessibility client honours — unless a
            // field in it holds the keyboard, which hiding would take away.
            if !v.holdsFirstResponder { v.isHidden = true }
        }
    }

    private func giveBack() {
        for t in taken {
            guard let v = t.view else { continue }
            v.accessibilityElementsHidden = t.elementsHidden
            v.isAccessibilityElement = t.element
            v.isHidden = t.hidden
        }
        taken = []
    }

    /// The sentinels' lowest common ancestor, and its two children that lead to each of them.
    private static func span(_ a: UIView, _ b: UIView) -> (UIView, UIView, UIView)? {
        var chainA: [UIView] = [], v: UIView? = a
        while let x = v { chainA.append(x); v = x.superview }
        var chainB: [UIView] = []
        v = b
        while let x = v { chainB.append(x); v = x.superview }
        var fromA = chainA[0], fromB = chainB[0], parent: UIView?
        var ia = chainA.count - 1, ib = chainB.count - 1
        while ia >= 0, ib >= 0, chainA[ia] === chainB[ib] {
            parent = chainA[ia]
            if ia > 0 { fromA = chainA[ia - 1] }
            if ib > 0 { fromB = chainB[ib - 1] }
            ia -= 1; ib -= 1
        }
        guard let parent, fromA !== fromB else { return nil }
        return (parent, fromA, fromB)
    }
}

/// A view of no size at one end of the subtree; it reports in once it's in a window and the
/// platform views around it are placed.
private struct GoneSentinel: UIViewRepresentable {
    let pair: GonePair
    var end: Bool
    var gone: Bool

    func makeUIView(context: Context) -> Sentinel {
        let v = Sentinel()
        v.onPlaced = { [pair] in pair.apply(gone) }
        if end { pair.end = v } else { pair.start = v }
        return v
    }

    func updateUIView(_ v: Sentinel, context: Context) {
        v.onPlaced = { [pair, gone] in pair.apply(gone) }
        // The platform views between the sentinels are placed after this pass.
        DispatchQueue.main.async { pair.apply(gone) }
    }

    final class Sentinel: UIView {
        var onPlaced: () -> Void = {}

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.onPlaced() }
        }
    }
}

private extension UIView {
    var holdsFirstResponder: Bool {
        if isFirstResponder { return true }
        return subviews.contains { $0.holdsFirstResponder }
    }
}
