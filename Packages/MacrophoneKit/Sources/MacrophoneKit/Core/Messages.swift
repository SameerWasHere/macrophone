import Foundation

// The wire, in two layers.
//
// 1. Handshake frames (plain JSON) — either a session handshake with a key both sides
//    already hold, or a pairing exchange that creates that key. Nothing secret is in them.
// 2. Session frames — every frame after the handshake is a `Message`, JSON-encoded and
//    sealed with ChaCha20-Poly1305 under a per-connection, per-direction key.
//
// Every frame on the socket is a 4-byte big-endian length followed by that many bytes.

public enum Handshake: Codable, Sendable {
    // MARK: Session (a paired phone reconnecting)
    case clientHello(phoneID: UUID, nonce: Data, version: Int)
    case serverHello(macID: UUID, nonce: Data, proof: Data)
    case clientFinish(proof: Data)

    // MARK: Pairing by QR code
    /// The phone proves it saw the QR: proof = HMAC(token, phonePub ‖ macPub).
    case pairQR(phoneID: UUID, phoneName: String, phonePub: Data, inviteID: UUID, proof: Data, version: Int)

    // MARK: Pairing by confirmation code (commit → key → reveal, so neither side can steer the code)
    case pairCodeCommit(phoneID: UUID, phoneName: String, commitment: Data, version: Int)
    case pairCodeMacKey(macID: UUID, macName: String, macPub: Data, nonce: Data)
    case pairCodeReveal(phonePub: Data, nonce: Data)
    /// Sent by the Mac while it waits for the person to compare codes.
    case pairCodeWaiting

    // MARK: Pairing outcome (both methods)
    /// confirm = HMAC(pairKey, "mac-confirm") so the phone knows the Mac derived the same key.
    case pairAccepted(macID: UUID, macName: String, confirm: Data)
    case pairRejected(reason: PairRejection)

    /// The handshake failed; the connection closes after this.
    case failure(reason: HandshakeFailure)
}

public enum PairRejection: String, Codable, Sendable, Error {
    case expired          // the QR or code timed out — make a new one
    case badProof         // the QR didn't match (scanned an old one?)
    case declined         // the person said the codes don't match
    case tooManyAttempts  // code pairing is rate limited
    case notPairing       // the Mac isn't showing a pairing screen
    case versionMismatch

    public var message: String {
        switch self {
        case .expired: return "That pairing code expired. Make a new one on your Mac."
        case .badProof: return "That QR code is out of date. Scan the one on your Mac now."
        case .declined: return "Pairing was declined on the Mac."
        case .tooManyAttempts: return "Too many tries. Wait a few minutes and try again."
        case .notPairing: return "Open Macrophone on your Mac and choose Pair iPhone."
        case .versionMismatch: return "Update Macrophone on both devices, then try again."
        }
    }
}

public enum HandshakeFailure: String, Codable, Sendable, Error {
    case unknownPeer      // this Mac doesn't know the phone (it was forgotten)
    case badProof
    case versionMismatch
    case protocolError
}

/// What finally happened on the Mac, after the countdown and the paste — sent back to the phone
/// that dictated it, so the phone can say "In Claude — sent" or exactly why it didn't land.
public enum LandingResult: String, Codable, Sendable {
    /// Pasted into the app and the send key pressed.
    case sent
    /// Pasted into the app (Send after pasting off — or sent but not confirmed: see `detail`).
    case pasted
    /// On the Mac's clipboard: what Clipboard asks for, or a fallback when pasting couldn't happen.
    case copied
    /// Someone pressed Cancel on the Mac during the countdown.
    case cancelled
    /// Didn't land anywhere.
    case failed
}

/// What the Mac did with a dictation.
public enum DeliveryOutcome: String, Codable, Sendable {
    case delivered
    /// Already had this id — a resend or retry. Not delivered twice.
    case duplicate
    case failed
}

public enum Message: Codable, Sendable {
    // Phone → Mac
    /// `features`: what this phone understands beyond the first version ("attention"); the Mac
    /// sends a newer message only to a phone that names it (an unknown message ends a session).
    case hello(phoneName: String, appVersion: String, os: String, features: [String]? = nil)
    case dictation(Dictation, delayed: Bool)
    // Mac → Phone
    /// `features`: what this Mac understands beyond the first version ("video", "fit"); the phone
    /// sends a newer message only to a Mac that names it (an older Mac leaves it out).
    case welcome(macName: String, appVersion: String, features: [String]? = nil)
    /// `detail` is a short human line, e.g. "Pasted into Claude" or "Copied to clipboard".
    case ack(id: UUID, outcome: DeliveryOutcome, detail: String?)
    /// Mac → phone, after delivery finishes: where it actually landed. `detail` is one plain line
    /// ("Sent to Claude", "The message box wasn't found — it's on your Mac's clipboard").
    case landed(id: UUID, result: LandingResult, detail: String)
    /// Mac → phone: the open apps/windows with somewhere to type, newest first. Sent after
    /// welcome and whenever the list changes.
    case targets([LiveTarget])
    /// Phone → Mac: rescan now (the picker just opened).
    case refreshTargets
    /// Either way: the shared Send-to choice changed. The phone sends its own right after
    /// welcome, so on reconnect the phone's choice wins.
    case selection(SendSelection)
    /// Phone → Mac: send the list of apps installed on the Mac.
    case listApps
    /// Mac → phone: the apps installed on the Mac, by name.
    case apps([MacApp])
    /// Phone → Mac: open this app and bring it forward.
    case openApp(bundleID: String)
    /// Mac → phone: whether it opened, in a plain line ("Claude is open", "Couldn't open Claude").
    case appOpened(bundleID: String, ok: Bool, detail: String)
    /// Phone → Mac: show this place's window (nil = stop watching).
    case watch(TargetRef?)
    /// Phone → Mac: a one-tap action on the watched window.
    case watchAction(WatchAction)
    /// Phone → Mac: click the watched window here (fractions of it, 0…1, top-left origin).
    case watchClick(x: Double, y: Double)
    /// Phone → Mac: scroll the watched window where the finger is (x, y) by (dx, dy) — all as
    /// fractions of the window; positive dy moves the content down, like a finger dragging it.
    case watchScroll(x: Double, y: Double, dx: Double, dy: Double)
    /// Phone → Mac: answer the prompt the window showed (`WatchPrompt.id`) with its answer at
    /// `index`. The Mac ignores it if the window has moved on to another question.
    case watchChoose(promptID: String, index: Int)
    /// Mac → phone: a window is asking a question (only to phones whose hello named "attention").
    case attention(Attention)
    /// Mac → phone: how watching is going.
    case watchState(WatchState)
    /// Mac → phone: the window, when it changed (a picture — to a phone that didn't name "video").
    case watchFrame(WatchFrame)
    /// Mac → phone (only to a phone whose hello named "remote"): the addresses this Mac can be
    /// reached at from away, with remote access on — sent after welcome and whenever they
    /// change; empty when remote access is off. The phone keeps them with the pairing.
    case remoteAddresses([RemoteAddress])
    /// Mac → phone: the window, when it changed, as video (only to a phone that named "video").
    case watchVideo(WatchVideoFrame)
    /// Phone → Mac: send a frame that stands on its own (the phone started, came back, or lost
    /// one). Only to a Mac that named "video".
    case watchKeyframe
    /// Phone → Mac: size the watched window for readable text (only to a Mac that named "fit").
    case watchFit(WatchFit)
    /// Phone → Mac: where a swipe on the watched window is — the finger landed or lifted, the
    /// coast after a flick began or ended — at (x, y), fractions of the window. The `watchScroll`
    /// deltas between two phases are one trackpad gesture on the Mac. Only to a Mac that named
    /// "scroll".
    case watchScrollPhase(WatchScrollPhase, x: Double, y: Double)
    // Either way
    case ping
    case pong
    /// The other side forgot this pairing. Delete the key and stop reconnecting.
    case unpair
}

enum WireCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
