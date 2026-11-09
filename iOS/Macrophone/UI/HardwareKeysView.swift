import Combine
import MacrophoneKit
import SwiftUI
import UIKit

/// The responder a real keyboard types through (Nov 5 2026, `HardwareKeyboard.swift`): an empty
/// view behind everything that becomes first responder while a window is in hand, a keyboard is
/// connected and the keyboard page isn't up — and only while nothing else is typing (a search
/// field, Settings, the word being fixed) and no sheet is over the window. It is no key input, so
/// iOS never raises a keyboard for it (Nov 8 2026).
///
/// The view hears the watcher, the pages and the keyboard itself (Combine), not through
/// SwiftUI's update (Nov 7 2026): behind everything in `RootView`, its `updateUIView` — and a
/// wrapper view's body, tried too — ran only at launch, never again when a window opened or a
/// keyboard connected, so it never asked for the keyboard and a real keyboard typed nothing on
/// the Mac (`HardwareKeyboardUITests`, failing since round 1).
struct HardwareKeysCatcher: UIViewRepresentable {
    var watcher: Watcher

    func makeUIView(context: Context) -> HardwareKeysView {
        // A key input only for XCUITest (`MACROPHONE_UITEST_KEYS=1`, DEBUG): `typeText` wants one.
        // The app's own view is a plain responder — iOS raises no keyboard for it (below).
        #if DEBUG
        let v: HardwareKeysView = ProcessInfo.processInfo.environment["MACROPHONE_UITEST_KEYS"] == "1" ? HardwareKeysTypingView() : HardwareKeysView()
        #else
        let v = HardwareKeysView()
        #endif
        v.follow(watcher)
        return v
    }

    func updateUIView(_ v: HardwareKeysView, context: Context) {
        if v.watcher !== watcher { v.follow(watcher) }
    }
}

class HardwareKeysView: UIView {
    weak var input: MacInput?
    fileprivate weak var watcher: Watcher?
    private var follows: [AnyCancellable] = []

    /// Hears what decides `wanted`: a window in hand, the page that isn't the keyboard's, a
    /// keyboard connected. `objectWillChange` comes before the change, so it's read a turn later.
    fileprivate func follow(_ watcher: Watcher) {
        self.watcher = watcher
        input = watcher.input
        let changed = Publishers.Merge3(watcher.objectWillChange.map { _ in () },
                                        watcher.input.objectWillChange.map { _ in () },
                                        HardwareKeyboard.shared.objectWillChange.map { _ in () })
        follows = [changed.receive(on: DispatchQueue.main).sink { [weak self] in
            MainActor.assumeIsolated { self?.decide() }
        }]
        decide()
    }

    private func decide() {
        guard let watcher else { wanted = false; return }
        // Not across the swap into or out of full screen (Nov 8 2026): claiming the keyboard
        // while the layouts change under it brought the keyboard up over the screen on the Duo.
        if watcher.fullScreen != lastFullScreen {
            lastFullScreen = watcher.fullScreen
            swapUntil = Date().addingTimeInterval(1.0)
            wanted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in self?.decide() }
            return
        }
        if Date() < swapUntil { wanted = false; return }
        wanted = watcher.isShowing && watcher.input.page != .keyboard && HardwareKeyboard.shared.connected
    }
    private var lastFullScreen = false
    private var swapUntil = Date.distantPast

    /// Should hear the keyboard now (acted on the next turn, never inside a SwiftUI update).
    var wanted = false {
        didSet {
            guard wanted != oldValue else { return }
            DispatchQueue.main.async { [weak self] in self?.wanted == true ? self?.startLooking() : self?.stopLooking() }
        }
    }
    private var looking: Timer?
    /// Presses passed on (not sent to the Mac), so their ends go the same way.
    private var passed: Set<Int> = []
    private var resign: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        // Leaving the app (⌘H, ⌘Space, a call): nothing stays held on the Mac.
        resign = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.input?.hardwareReleaseAll() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        looking?.invalidate()
        if let resign { NotificationCenter.default.removeObserver(resign) }
    }

    override var canBecomeFirstResponder: Bool { true }

    // Tab never reaches a responder as a press here — iOS takes it first (keyboard navigation; and
    // ⌘Tab is its own app switcher), so Tab in every combination is asked for as a key command
    // with priority over the system's. Whatever still doesn't come (⌘Tab on the simulator), ⌥Tab
    // stands in for (`HardwareKeyRouter.switching`).
    private lazy var tabCommands: [UIKeyCommand] = {
        let combos: [UIKeyModifierFlags] = [[], .shift, .alternate, [.alternate, .shift], .control, [.control, .shift],
                                            .command, [.command, .shift]]
        return combos.map { mods in
            let c = UIKeyCommand(input: "\t", modifierFlags: mods, action: #selector(tabKey(_:)))
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }()
    override var keyCommands: [UIKeyCommand]? { tabCommands }
    @objc private func tabKey(_ c: UIKeyCommand) { input?.hardwareTab(c.modifierFlags.watchModifiers) }

    // A key input as far as iOS is concerned (it says the keyboard has a home — XCUITest won't
    // type without one), but every press is taken in `pressesBegan` before it can insert
    // anything, and no keys of iOS's own ever show: an empty input view, no shortcuts bar, no
    // predictions.
    @objc var hasText: Bool { false }
    @objc func insertText(_ text: String) { input?.hardwareInserted(text) }
    @objc func deleteBackward() { input?.hardwareInserted(nil) }
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    // Not a `UIKeyInput`, and no input view (Nov 8 2026, round 2): iOS raises a keyboard for a
    // key input, or for any first responder with an input view of its own, and every press
    // arrives in `pressesBegan` either way. As a key input with an empty input view this view
    // brought the keyboard up on the Duo as it took the keyboard a second into full screen and
    // the moment the mic mode came: zero-sized, the system keys (the simulator draws them though
    // GCKeyboard says a keyboard is attached); a point tall, the folded laptop still drew the
    // keyboard's window — its blurred backdrop — over the whole lower half (iOS docks it to the
    // half under the hinge whatever is in it), and so it did for a plain responder that still
    // vended the 1 pt view. The key-input conformance and the 1 pt input view live on
    // `HardwareKeysTypingView`, used only under XCUITest, whose `typeText` needs a key input.
    override var inputAccessoryView: UIView? { nil }

    // No edit actions of its own: ⌘C, ⌘V, ⌘Z are the Mac's, not a copy here.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(UIResponder.macrophoneFoundFirst) || action == #selector(tabKey(_:))
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        // Another field took the keyboard (or the window went): let go of ⌘ on the Mac.
        if r { input?.hardwareReleaseAll(); passed = [] }
        return r
    }

    // While wanted, a look every 0.4 s: claim the keyboard when nothing else types, give it back
    // when a sheet comes over the window. Cheap (one responder lookup).
    private func startLooking() {
        looking?.invalidate()
        claimIfFree()
        looking = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.claimIfFree() }
        }
    }

    private func stopLooking() {
        looking?.invalidate()
        looking = nil
        if isFirstResponder { _ = resignFirstResponder() }
    }

    private func claimIfFree() {
        guard wanted, let window, window.isKeyWindow else { return }
        let covered = window.rootViewController?.presentedViewController != nil
        if covered {
            if isFirstResponder { _ = resignFirstResponder() }
            return
        }
        guard !isFirstResponder else { return }
        // Someone typing (a text field, the keyboard page's own field): theirs.
        if let other = UIResponder.currentFirst, other is UIKeyInput, !(other is HardwareKeysView) { return }
        if becomeFirstResponder() { AppModel.shared.log.add("watching: a hardware keyboard types on the Mac (first responder)") }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses {
            guard let key = p.key, input?.hardwarePress(key) == true else { rest.insert(p); continue }
        }
        for p in rest { if let k = p.key { passed.insert(k.keyCode.rawValue) } }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        ended(presses, event: event, cancelled: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        ended(presses, event: event, cancelled: true)
    }

    private func ended(_ presses: Set<UIPress>, event: UIPressesEvent?, cancelled: Bool) {
        var rest = Set<UIPress>()
        for p in presses {
            guard let key = p.key else { rest.insert(p); continue }
            if passed.remove(key.keyCode.rawValue) != nil { rest.insert(p); continue }
            input?.hardwareRelease(key)
        }
        guard !rest.isEmpty else { return }
        if cancelled { super.pressesCancelled(rest, with: event) } else { super.pressesEnded(rest, with: event) }
    }
}

/// The test rig's key input (DEBUG, `MACROPHONE_UITEST_KEYS=1`): XCUITest's `typeText` reaches a
/// key input as inserted text and nothing else; the app never makes one of these itself.
final class HardwareKeysTypingView: HardwareKeysView, UIKeyInput {
    // A point tall, never zero: zero-sized, iOS 27 put the system keys up on the simulator.
    private let noKeys: UIView = {
        let v = UIInputView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), inputViewStyle: .keyboard)
        v.allowsSelfSizing = true
        v.backgroundColor = .clear
        return v
    }()
    override var inputView: UIView? { noKeys }
}

extension UIResponder {
    private static weak var found: UIResponder?

    /// The first responder now, if any (the action goes to it, else up from the key window).
    static var currentFirst: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.macrophoneFoundFirst), to: nil, from: nil, for: nil)
        return found
    }

    @objc fileprivate func macrophoneFoundFirst() { UIResponder.found = self }
}
