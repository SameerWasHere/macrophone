@testable import MacrophoneKit
import XCTest

/// A real keyboard on the iPhone (Nov 5 2026): HID usages to the Mac's names, and what a press
/// becomes on the wire.
final class HardwareKeysTests: XCTestCase {
    // HID usages (page 7), as `UIKey.keyCode` gives them.
    let a = 0x04, c = 0x06, w = 0x1A, z = 0x1D, one = 0x1E, zero = 0x27
    let ret = 0x28, esc = 0x29, backspace = 0x2A, tab = 0x2B, space = 0x2C
    let left = 0x50, up = 0x52, f1 = 0x3A, f12 = 0x45, f13 = 0x68
    let lctrl = 0xE0, lshift = 0xE1, lalt = 0xE2, lcmd = 0xE3, rcmd = 0xE7, caps = 0x39

    func testEveryUsageHasTheMacsName() {
        XCTAssertEqual(HardwareKeyNames.name(usage: a), "a")
        XCTAssertEqual(HardwareKeyNames.name(usage: z), "z")
        XCTAssertEqual(HardwareKeyNames.name(usage: one), "1")
        XCTAssertEqual(HardwareKeyNames.name(usage: 0x26), "9")
        XCTAssertEqual(HardwareKeyNames.name(usage: zero), "0")
        XCTAssertEqual(HardwareKeyNames.name(usage: ret), "return")
        XCTAssertEqual(HardwareKeyNames.name(usage: esc), "escape")
        XCTAssertEqual(HardwareKeyNames.name(usage: backspace), "delete")
        XCTAssertEqual(HardwareKeyNames.name(usage: 0x4C), "forwarddelete")
        XCTAssertEqual(HardwareKeyNames.name(usage: f1), "f1")
        XCTAssertEqual(HardwareKeyNames.name(usage: f12), "f12")
        XCTAssertEqual(HardwareKeyNames.name(usage: f13), "f13")
        XCTAssertEqual(HardwareKeyNames.name(usage: 0x6F), "f20")
        XCTAssertNil(HardwareKeyNames.name(usage: 0x70), "F21 has no Mac key")
        XCTAssertEqual(HardwareKeyNames.name(usage: 0x58), "enter")
        XCTAssertEqual(HardwareKeyNames.name(usage: 0x62), "0")
        XCTAssertEqual(HardwareKeyNames.name(usage: 0x35), "grave")
        XCTAssertNil(HardwareKeyNames.name(usage: 0x64), "the ISO § key has no name on the Mac's map")
        XCTAssertEqual(HardwareKeyNames.modifier(usage: lcmd), .command)
        XCTAssertEqual(HardwareKeyNames.modifier(usage: rcmd), .command, "either side holds the one ⌘ the Mac knows")
        XCTAssertEqual(HardwareKeyNames.modifier(usage: lalt), .option)
        XCTAssertNil(HardwareKeyNames.modifier(usage: a))
        XCTAssertEqual(HardwareKeyNames.usage(for: "tab"), tab)
        XCTAssertEqual(HardwareKeyNames.usage(for: "command"), lcmd)
        XCTAssertEqual(HardwareKeyNames.usage(for: "1"), one, "the main row's, not the keypad's")
        // Every name given is one the Mac maps (`MacKeys.allNames` is what a Mac naming keyHold knows).
        let known = Set(MacKeys.allNames)
        for u in 0...0xFF { if let n = HardwareKeyNames.name(usage: u) { XCTAssertTrue(known.contains(n), "\(n) (0x\(String(u, radix: 16)))") } }
    }

    func testCharactersAreTypedAsTheLayoutGivesThem() {
        var r = HardwareKeyRouter()
        XCTAssertEqual(r.press(usage: a, characters: "a", modifiers: []), [.type("a")])
        XCTAssertEqual(r.press(usage: a, characters: "A", modifiers: [.shift]), [.type("A")], "⇧ stays on the phone: the capital is typed")
        XCTAssertEqual(r.press(usage: space, characters: " ", modifiers: []), [.type(" ")])
        XCTAssertEqual(r.press(usage: 0x1F, characters: "@", modifiers: [.shift]), [.type("@")])
        XCTAssertEqual(r.press(usage: a, characters: "å", modifiers: [.option]), [.type("å")], "⌥ with a letter types what the Mac would")
        XCTAssertEqual(r.press(usage: 0x08, characters: "", modifiers: [.option]), [.key(WatchKey("e", option: true))],
                       "a dead key (⌥E) goes as the key, for the Mac to compose")
        XCTAssertEqual(r.press(usage: a, characters: "A", modifiers: []), [.type("A")], "Caps Lock's capitals come from iOS")
        XCTAssertEqual(r.press(usage: caps, characters: "", modifiers: []), [], "Caps Lock itself never reaches the Mac")
        XCTAssertEqual(r.press(usage: 0x64, characters: "§", modifiers: []), [.type("§")], "a key with no Mac name types its characters")
        XCTAssertTrue(r.heldOnMac.isEmpty)
    }

    func testKeysThatAreNotCharactersArePressedByName() {
        var r = HardwareKeyRouter()
        XCTAssertEqual(r.press(usage: esc, characters: "\u{1B}", modifiers: []), [.key(WatchKey("escape"))])
        XCTAssertEqual(r.press(usage: ret, characters: "\r", modifiers: []), [.key(WatchKey("return"))])
        XCTAssertEqual(r.press(usage: ret, characters: "\r", modifiers: [.shift]), [.key(WatchKey("return", shift: true))], "⇧↩, a new line")
        XCTAssertEqual(r.press(usage: tab, characters: "\t", modifiers: [.shift]), [.key(WatchKey("tab", shift: true))])
        XCTAssertEqual(r.press(usage: backspace, characters: "\u{8}", modifiers: [.option]), [.key(WatchKey("delete", option: true))], "⌥⌫")
        XCTAssertEqual(r.press(usage: left, characters: "\u{F702}", modifiers: [.option]), [.key(WatchKey("left", option: true))], "⌥←")
        XCTAssertEqual(r.press(usage: 0x4A, characters: "\u{F729}", modifiers: []), [.key(WatchKey("home"))])
        XCTAssertEqual(r.press(usage: f1 + 4, characters: "\u{F708}", modifiers: []), [.key(WatchKey("f5"))])
        XCTAssertTrue(r.heldOnMac.isEmpty, "⇧ and ⌥ are never held on the Mac")
    }

    func testCommandAndControlAreHeldOnTheMacAndMakeChords() {
        var r = HardwareKeyRouter()
        XCTAssertEqual(r.press(usage: lcmd, characters: "", modifiers: []), [.hold(.command, down: true)], "⌘ down, before its flag shows")
        XCTAssertEqual(r.press(usage: lcmd, characters: "", modifiers: [.command]), [], "never held twice")
        XCTAssertEqual(r.press(usage: c, characters: "c", modifiers: [.command]), [.key(WatchKey("c", command: true))], "⌘C")
        XCTAssertEqual(r.press(usage: z, characters: "z", modifiers: [.command, .shift]), [.key(WatchKey("z", command: true, shift: true))], "⇧⌘Z")
        XCTAssertEqual(r.press(usage: w, characters: "w", modifiers: [.command]), [.key(WatchKey("w", command: true))])
        XCTAssertEqual(r.press(usage: left, characters: "", modifiers: [.command]), [.key(WatchKey("left", command: true))], "⌘←")
        XCTAssertEqual(r.release(usage: lcmd, modifiers: [.command]), [.hold(.command, down: false)], "let go, whatever the flag still says")
        XCTAssertTrue(r.heldOnMac.isEmpty)

        XCTAssertEqual(r.press(usage: lctrl, characters: "", modifiers: [.control]), [.hold(.control, down: true)])
        XCTAssertEqual(r.press(usage: c, characters: "\u{3}", modifiers: [.control]), [.key(WatchKey("c", control: true))], "⌃C, not a control character")
        XCTAssertEqual(r.release(usage: lctrl, modifiers: []), [.hold(.control, down: false)])
    }

    func testCommandTabStepsTheSwitcherAndCommitsOnRelease() {
        var r = HardwareKeyRouter()
        var wire: [HardwareKeyRouter.Out] = []
        wire += r.press(usage: lcmd, characters: "", modifiers: [.command])
        wire += r.press(usage: tab, characters: "\t", modifiers: [.command])
        wire += r.release(usage: tab, modifiers: [.command])
        wire += r.press(usage: tab, characters: "\t", modifiers: [.command])
        wire += r.release(usage: tab, modifiers: [.command])
        wire += r.release(usage: lcmd, modifiers: [])
        XCTAssertEqual(wire, [.hold(.command, down: true), .key(WatchKey("tab", command: true)), .key(WatchKey("tab", command: true)),
                              .hold(.command, down: false)])
    }

    func testOptionTabIsTheMacsSwitcherWhileOptionIsHeld() {
        var r = HardwareKeyRouter()
        var wire: [HardwareKeyRouter.Out] = []
        wire += r.press(usage: lalt, characters: "", modifiers: [.option])
        wire += r.press(usage: tab, characters: "\t", modifiers: [.option])
        wire += r.press(usage: tab, characters: "\t", modifiers: [.option])
        wire += r.press(usage: tab, characters: "\t", modifiers: [.option, .shift])
        XCTAssertTrue(r.switching)
        wire += r.release(usage: lalt, modifiers: [])
        XCTAssertEqual(wire, [.hold(.command, down: true), .key(WatchKey("tab", command: true)), .key(WatchKey("tab", command: true)),
                              .key(WatchKey("tab", command: true, shift: true)), .hold(.command, down: false)])
        XCTAssertFalse(r.switching)
        // Done mid-switch lets ⌘ go too.
        _ = r.press(usage: tab, characters: "\t", modifiers: [.option])
        XCTAssertEqual(r.releaseAll(), [.hold(.command, down: false)])
        // A real ⌘ held through it isn't let go by the switcher's end.
        _ = r.press(usage: lcmd, characters: "", modifiers: [.command])
        _ = r.press(usage: tab, characters: "\t", modifiers: [.command, .option])
        XCTAssertFalse(r.switching, "⌘⌥Tab is a chord of its own")
    }

    func testAMissedReleaseOrPressIsPutRightOnTheNextKey() {
        var r = HardwareKeyRouter()
        _ = r.press(usage: lcmd, characters: "", modifiers: [.command])
        // iOS kept ⌘'s release (⌘H, ⌘Space): the next key, with no ⌘, lets the Mac's go first.
        XCTAssertEqual(r.press(usage: a, characters: "a", modifiers: []), [.hold(.command, down: false), .type("a")])
        // ⌘ went down before the keyboard reached the app: held on the Mac before the chord.
        XCTAssertEqual(r.press(usage: c, characters: "c", modifiers: [.command]), [.hold(.command, down: true), .key(WatchKey("c", command: true))])
    }

    func testReleaseAllLetsGoLastHeldFirstAndForgetSendsNothing() {
        var r = HardwareKeyRouter()
        _ = r.press(usage: lcmd, characters: "", modifiers: [.command])
        _ = r.press(usage: lctrl, characters: "", modifiers: [.command, .control])
        XCTAssertEqual(r.heldOnMac, [.command, .control])
        XCTAssertEqual(r.physical, [.command, .control])
        XCTAssertEqual(r.releaseAll(), [.hold(.control, down: false), .hold(.command, down: false)])
        XCTAssertEqual(r.releaseAll(), [])
        XCTAssertTrue(r.physical.isEmpty)
        _ = r.press(usage: lcmd, characters: "", modifiers: [.command])
        r.forget()
        XCTAssertEqual(r.releaseAll(), [], "the link went: the Mac let go itself")
    }

    func testShiftAndOptionAreKeptForClicks() {
        var r = HardwareKeyRouter()
        XCTAssertEqual(r.press(usage: lshift, characters: "", modifiers: []), [])
        XCTAssertEqual(r.physical, [.shift])
        _ = r.release(usage: lshift, modifiers: [])
        XCTAssertTrue(r.physical.isEmpty)
    }

    func testWhatRepeatsAndWhatAFieldTypesItself() {
        XCTAssertTrue(HardwareKeyRouter.repeats(.type("a")))
        XCTAssertTrue(HardwareKeyRouter.repeats(.key(WatchKey("delete"))))
        XCTAssertTrue(HardwareKeyRouter.repeats(.key(WatchKey("delete", option: true))), "⌥⌫ runs on, word by word")
        XCTAssertTrue(HardwareKeyRouter.repeats(.key(WatchKey("down", shift: true))))
        XCTAssertFalse(HardwareKeyRouter.repeats(.key(WatchKey("w", command: true))), "never a ⌘ chord")
        XCTAssertFalse(HardwareKeyRouter.repeats(.key(WatchKey("left", control: true))))
        XCTAssertFalse(HardwareKeyRouter.repeats(.key(WatchKey("escape"))))
        XCTAssertFalse(HardwareKeyRouter.repeats(.key(WatchKey("return"))))
        XCTAssertFalse(HardwareKeyRouter.repeats(.hold(.command, down: true)))

        XCTAssertTrue(HardwareKeyRouter.textFieldTakes(.type("a")))
        XCTAssertTrue(HardwareKeyRouter.textFieldTakes(.key(WatchKey("delete"))))
        XCTAssertTrue(HardwareKeyRouter.textFieldTakes(.key(WatchKey("return", shift: true))))
        XCTAssertFalse(HardwareKeyRouter.textFieldTakes(.key(WatchKey("left"))), "the arrows go to the Mac, not the hidden caret")
        XCTAssertFalse(HardwareKeyRouter.textFieldTakes(.key(WatchKey("c", command: true))))
        XCTAssertFalse(HardwareKeyRouter.textFieldTakes(.key(WatchKey("escape"))))
        XCTAssertFalse(HardwareKeyRouter.textFieldTakes(.hold(.command, down: true)))
    }

    func testPrintable() {
        XCTAssertTrue(HardwareKeyNames.isPrintable("é"))
        XCTAssertTrue(HardwareKeyNames.isPrintable("👍"))
        XCTAssertFalse(HardwareKeyNames.isPrintable(""))
        XCTAssertFalse(HardwareKeyNames.isPrintable("\r"))
        XCTAssertFalse(HardwareKeyNames.isPrintable("\u{7F}"))
        XCTAssertFalse(HardwareKeyNames.isPrintable("\u{F700}"))
    }
}
