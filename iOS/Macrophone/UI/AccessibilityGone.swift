import SwiftUI

// A subtree out of the accessibility tree (Nov 7 2026): the one modifier for a layer nobody can
// see — the desktop under a window in hand, a carousel page that isn't up, a Duo layout kept
// built but hidden (`KeptHidden`). What it does today is `.accessibilityHidden`, which is what
// VoiceOver honours. What it is for: the XCUITest snapshot and `performAccessibilityAudit` on
// iOS 27 list SwiftUI's nodes whatever that flag says — a Button under a window, a blank
// placeholder text and a decorative check all marked hidden were in every tree and audited —
// and a UIKit-backed view inside the subtree (a ScrollView, a Toggle's switch, a Menu's button,
// a representable) is a UIView of its own. Two sentinel platform views bracketing the subtree
// and hiding the UIViews between them in their common superview changed nothing in that tree
// (the sentinels showed as empty nodes; the hosts weren't siblings of the content's views), so
// that attempt isn't kept. What does take a node out of that tree is not building it, or
// `.hidden()` — neither conditional without changing the view's identity, which `KeptHidden`
// exists to avoid. Every caller goes through here, so the better answer lands in one place.

extension View {
    /// Removes the subtree from the accessibility tree while `gone` — a subtree that is also
    /// off screen (faded out, under a window). Leaves the layout untouched, builds nothing anew.
    func accessibilityGone(_ gone: Bool) -> some View { accessibilityHidden(gone) }
}
