import CoreGraphics
import Foundation

// The iPhone Duo (Oct 25 2026): a phone that folds like a book — a cover screen outside, a
// bigger screen inside. How it's held is a pose, and each pose has its own layout on the phone.
// The rules here are pure (the phone reads the hinge and the fold's region and hands them in;
// the tests hold them), so the Mac compiles them too and nothing in them touches UIKit.
//
//   closed      the cover screen: a regular iPhone, a little wider and shorter
//   open        the inner screen flat, upright or on its side
//   laptop      partly folded with the hinge across — the Mac above, the deck below
//   book        partly folded with the hinge up and down — the Mac on one page, the deck on the other

/// How the Duo is held.
public enum FoldPose: Equatable, Hashable, Sendable {
    case closed
    case open(landscape: Bool)
    case laptop
    case book

    /// The inner screen is up (every pose but closed).
    public var isInner: Bool { self != .closed }
    /// Partly folded: two halves with the fold between them.
    public var isFolded: Bool { self == .laptop || self == .book }

    /// The pose in a word, for the log and the debug hooks.
    public var name: String {
        switch self {
        case .closed: return "closed"
        case .open(let landscape): return landscape ? "landscape" : "portrait"
        case .laptop: return "laptop"
        case .book: return "book"
        }
    }

    /// For VoiceOver: what's where.
    public var spoken: String {
        switch self {
        case .closed: return "Cover screen"
        case .open(let landscape): return landscape ? "Open, on its side" : "Open"
        case .laptop: return "Laptop: your Mac above, the trackpad, keyboard and mic below"
        case .book: return "Book: your Mac on the left page, the trackpad, keyboard and mic on the right"
        }
    }
}

/// What the hinge says, as the phone reads it (SwiftUI's `DeviceHinge`; nil on a phone with no hinge).
public enum HingeStatus: Equatable, Sendable {
    case closed, partiallyOpen, fullyOpen
}

/// The fold's region in the scene — where the display bends, margins included — and whether
/// it's active (partly open) or only where it would be (flat or closed).
public struct FoldDivision: Equatable, Sendable {
    public var frame: CGRect
    public var isActive: Bool

    public init(frame: CGRect, isActive: Bool) {
        self.frame = frame
        self.isActive = isActive
    }

    /// The fold runs across (a horizontal band: the laptop) rather than up and down (the book).
    public var isAcross: Bool { frame.width >= frame.height }
}

/// Everything the pose is derived from.
public struct FoldReading: Equatable, Sendable {
    public var hinge: HingeStatus?
    /// Degrees: 0 closed, 180 flat.
    public var angle: Double
    /// The scene's size in points.
    public var size: CGSize
    public var division: FoldDivision?

    public init(hinge: HingeStatus?, angle: Double, size: CGSize, division: FoldDivision? = nil) {
        self.hinge = hinge
        self.angle = angle
        self.size = size
        self.division = division
    }

    public static let none = FoldReading(hinge: nil, angle: 180, size: .zero)
}

extension FoldPose {
    /// A screen at least this wide on its short side is the Duo's inner screen (669 × 951 points;
    /// the cover is 466 × 678; no regular iPhone is wider than 440).
    public static let innerShortSide: CGFloat = 600

    /// The pose from what the phone read. The hinge decides; the fold's region (or, without one,
    /// the scene's shape) says which way the halves lie; a scene as big as the inner screen with no
    /// hinge reading yet is still the inner screen, open.
    public static func derive(_ r: FoldReading) -> FoldPose {
        let landscape = r.size.width > r.size.height
        // An inner pose is laid out for the inner screen: a scene the cover's size (the hinge
        // partly open while the app is still on the cover, as the phone opens or closes) stays
        // the phone's layout. Nothing measured yet: the hinge's word stands.
        let onCover = r.size != .zero && min(r.size.width, r.size.height) < innerShortSide
        switch r.hinge {
        case .closed?:
            return .closed
        case .fullyOpen?:
            return onCover ? .closed : .open(landscape: landscape)
        case .partiallyOpen?:
            if onCover { return .closed }
            if let d = r.division { return d.isAcross ? .laptop : .book }
            return landscape ? .laptop : .book
        case nil:
            // No hinge (a regular iPhone, or nothing read yet): the size tells the screen.
            guard r.size != .zero, !onCover else { return .closed }
            return .open(landscape: landscape)
        }
    }

    /// How far the deck has risen as the hinge folds from flat toward the laptop or the book:
    /// 0 flat (nothing to show yet), 1 folded past about 120°. Drives the deck's arrival and the
    /// Mac's picture settling into its half, so the split follows the hinge rather than snapping.
    /// In fiftieths, so a hinge that trembles by a fraction of a degree moves nothing.
    public static func deckRise(angle: Double) -> Double {
        let t = (165 - angle) / 45
        return (min(1, max(0, t)) * 50).rounded() / 50
    }
}

/// The two halves of a folded screen: the Mac's and the deck's.
public struct FoldHalves: Equatable, Sendable {
    /// Above (the laptop) or leading (the book): the Mac.
    public var mac: CGRect
    /// Below or trailing: the deck.
    public var deck: CGRect

    public init(mac: CGRect, deck: CGRect) {
        self.mac = mac
        self.deck = deck
    }

    /// The room a fold takes when the phone has no region for it: a band in the middle.
    public static let defaultFold: CGFloat = 28

    /// Split the scene at the fold. The region's frame already carries its margins, so nothing is
    /// added; without one, a band in the middle stands for it.
    public static func split(_ size: CGSize, pose: FoldPose, division: FoldDivision?) -> FoldHalves? {
        guard pose.isFolded, size.width > 0, size.height > 0 else { return nil }
        if pose == .laptop {
            let band = division.map { $0.frame.standardized } ?? CGRect(x: 0, y: (size.height - defaultFold) / 2, width: size.width, height: defaultFold)
            let top = max(0, min(size.height, band.minY))
            let bottom = max(top, min(size.height, band.maxY))
            return FoldHalves(mac: CGRect(x: 0, y: 0, width: size.width, height: top),
                              deck: CGRect(x: 0, y: bottom, width: size.width, height: size.height - bottom))
        } else {
            let band = division.map { $0.frame.standardized } ?? CGRect(x: (size.width - defaultFold) / 2, y: 0, width: defaultFold, height: size.height)
            let leading = max(0, min(size.width, band.minX))
            let trailing = max(leading, min(size.width, band.maxX))
            return FoldHalves(mac: CGRect(x: 0, y: 0, width: leading, height: size.height),
                              deck: CGRect(x: trailing, y: 0, width: size.width - trailing, height: size.height))
        }
    }
}
