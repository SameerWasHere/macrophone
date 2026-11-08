import Foundation

// Keep Awake (Nov 7 2026): the Mac stays on — with the lid closed on a laptop — so it can be used
// from the iPhone. Moved from SameerOS's On The Go (~/claude-projects/OnTheGo/CLAUDE.md is the
// manual it grew from) and made for anyone's Mac: a laptop or a desktop, Intel or Apple silicon,
// one display, several or none.
//
// This file is the pure part: the wire (`KeepAwakeStatus` Mac → phone, `KeepAwakeRequest`
// phone → Mac, feature `keepAwake`), `pmset`'s text read and the changes to make, the machine's
// power as a snapshot, the warnings, and every sentence the Mac and the phone show. The state
// machine is KeepAwakeEngine.swift; the Mac app supplies the system calls.

public enum MachineKind: String, Codable, Sendable {
    /// Has a lid and a battery: "Lid can close".
    case laptop
    /// iMac, mini, Studio, Pro: no lid, no battery — "Stays awake and reachable".
    case desktop
}

public enum ThermalLevel: Int, Codable, Sendable, Comparable {
    case nominal = 0, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The machine's power, read in one go.
public struct PowerSnapshot: Equatable, Sendable {
    public var hasBattery: Bool
    public var battery: Int?
    public var charging: Bool
    /// On the power adapter (or a desktop).
    public var onPower: Bool
    /// The lid is closed (nil: no lid, or unknown).
    public var lidClosed: Bool?
    public var lowPowerMode: Bool
    public var thermal: ThermalLevel

    public init(hasBattery: Bool = false, battery: Int? = nil, charging: Bool = false, onPower: Bool = true,
                lidClosed: Bool? = nil, lowPowerMode: Bool = false, thermal: ThermalLevel = .nominal) {
        self.hasBattery = hasBattery
        self.battery = battery
        self.charging = charging
        self.onPower = onPower
        self.lidClosed = lidClosed
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }

    public var onBattery: Bool { hasBattery && !onPower }

    /// "84%" / "84% · charging" / nil on a desktop.
    public var batteryWords: String? {
        guard hasBattery, let battery else { return nil }
        if charging { return "\(battery)% · charging" }
        return "\(battery)%"
    }
}

// MARK: - pmset

/// What `pmset` says, per power source, for the keys Keep Awake changes.
public struct PowerProfile: Codable, Equatable, Sendable {
    /// "Battery Power" / "AC Power" / "UPS Power" → key → value.
    public var sources: [String: [String: Int]]
    public init(sources: [String: [String: Int]] = [:]) { self.sources = sources }
    public var isEmpty: Bool { sources.values.allSatisfy(\.isEmpty) }
}

public enum PMSet {
    /// The per-source keys Keep Awake changes and puts back.
    public static let tracked = ["sleep", "displaysleep", "hibernatemode"]

    static let sourceNames: [String: PowerChange.Source] = ["Battery Power": .battery, "AC Power": .charger, "UPS Power": .ups]

    /// `pmset -g custom` → each source's tracked values. A Mac that only lists "AC Power" (a
    /// desktop) gives one source; one that never prints hibernatemode just hasn't it.
    public static func parseCustom(_ text: String) -> PowerProfile {
        var out: [String: [String: Int]] = [:]
        var current: String?
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":"), !line.hasPrefix(" ") {
                let name = String(trimmed.dropLast())
                current = sourceNames[name] != nil ? name : nil
                if let current { out[current] = out[current] ?? [:] }
                continue
            }
            guard let current, let (k, v) = keyValue(trimmed), tracked.contains(k) else { continue }
            out[current]?[k] = v
        }
        return PowerProfile(sources: out)
    }

    /// One value out of `pmset -g` ("sleep 0 (sleep prevented by …)" → 0). Case-sensitive, so
    /// "Sleep On Power Button" is never "sleep".
    public static func value(_ key: String, in text: String) -> Int? {
        for raw in text.split(separator: "\n") {
            if let (k, v) = keyValue(raw.trimmingCharacters(in: .whitespaces)), k == key { return v }
        }
        return nil
    }

    /// `pmset -g`'s "SleepDisabled 1": the Mac won't sleep at all, lid or no lid.
    public static func sleepDisabled(_ summary: String) -> Bool? {
        value("SleepDisabled", in: summary).map { $0 == 1 }
    }

    private static func keyValue(_ s: String) -> (String, Int)? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, let v = Int(parts[1]) else { return nil }
        return (String(parts[0]), v)
    }

    /// Keep Awake's settings: no system sleep, no display sleep, no sleep at all (the lid), and
    /// on a laptop no hibernation image to write on the way down.
    public static func enableChanges(machine: MachineKind) -> [PowerChange] {
        var c = [PowerChange(.all, "sleep", 0), PowerChange(.all, "displaysleep", 0), PowerChange(.all, "disablesleep", 1)]
        if machine == .laptop { c.insert(PowerChange(.all, "hibernatemode", 0), at: 1) }
        return c
    }

    /// Back to what was there, source by source (a laptop's battery and charger settings
    /// differ — On The Go's single `-a` restore flattened them). With no backup, macOS's own
    /// defaults for this kind of Mac. `disablesleep 0` always, last.
    public static func restoreChanges(backup: PowerProfile?, machine: MachineKind) -> [PowerChange] {
        var out: [PowerChange] = []
        if let backup, !backup.isEmpty {
            for name in backup.sources.keys.sorted() {
                guard let source = sourceNames[name], let values = backup.sources[name] else { continue }
                for key in tracked { if let v = values[key] { out.append(PowerChange(source, key, v)) } }
            }
        } else if machine == .laptop {
            out = [PowerChange(.battery, "sleep", 1), PowerChange(.battery, "displaysleep", 2),
                   PowerChange(.charger, "sleep", 1), PowerChange(.charger, "displaysleep", 10),
                   PowerChange(.all, "hibernatemode", 3)]
        } else {
            out = [PowerChange(.all, "sleep", 1), PowerChange(.all, "displaysleep", 10)]
        }
        out = out.filter(\.isAllowed)
        out.append(PowerChange(.all, "disablesleep", 0))
        return out
    }

    /// While on, the settings that matter have drifted (a macOS update, a reboot, someone else).
    public static func drifted(_ summary: String) -> Bool {
        sleepDisabled(summary) != true || (value("displaysleep", in: summary).map { $0 != 0 } ?? false)
    }
}

// MARK: - Another app keeping the Mac awake

/// SameerOS's On The Go — the feature this replaces — changing the same settings. Keep Awake
/// never fights it: it says so and won't turn on until it's off.
public enum OtherKeeper {
    /// Words for the one line, or nil when nothing else is keeping the Mac awake.
    public static func words(onTheGoActive: Bool, sameerOSHelperLoaded: Bool) -> String? {
        if onTheGoActive { return "SameerOS's On The Go is on — turn it off there first." }
        if sameerOSHelperLoaded { return "SameerOS can still change sleep settings — remove its helper in SameerOS › Displays first." }
        return nil
    }
}

// MARK: - The wire

/// Mac → phone (only to a phone naming `feature`): Keep Awake as it is now — after the welcome
/// and on every change. Every field decodes with a default, so a newer Mac's extra fields never
/// break a phone and an older one's missing ones read as "not known".
public struct KeepAwakeStatus: Codable, Sendable, Equatable {
    public static let feature = "keepAwake"

    public var on: Bool
    /// Turning on or off right now.
    public var busy: Bool
    public var machine: MachineKind
    /// A laptop whose sleep settings are changed: the lid can close.
    public var lidCanClose: Bool
    public var since: Date?
    public var displaysOff: Bool
    public var displaysOffSince: Date?
    /// The Mac has a display to turn off (a headless mini has none).
    public var hasDisplays: Bool
    /// "Back at desk at…": Keep Awake turns itself off then.
    public var backAt: Date?
    public var battery: Int?
    public var charging: Bool
    public var onPower: Bool
    /// Why it can't turn on right now (another app keeps the Mac awake).
    public var blocked: String?
    /// Something isn't right, and what fixes it.
    public var problem: String?
    /// Worth knowing: the battery's low, the Mac is hot.
    public var warning: String?
    /// The Mac is set never to sleep and Keep Awake isn't on: one click restores.
    public var sleepStillOff: Bool

    public init(on: Bool = false, busy: Bool = false, machine: MachineKind = .laptop, lidCanClose: Bool = false,
                since: Date? = nil, displaysOff: Bool = false, displaysOffSince: Date? = nil, hasDisplays: Bool = true,
                backAt: Date? = nil, battery: Int? = nil, charging: Bool = false, onPower: Bool = true,
                blocked: String? = nil, problem: String? = nil, warning: String? = nil, sleepStillOff: Bool = false) {
        self.on = on; self.busy = busy; self.machine = machine; self.lidCanClose = lidCanClose
        self.since = since; self.displaysOff = displaysOff; self.displaysOffSince = displaysOffSince
        self.hasDisplays = hasDisplays; self.backAt = backAt; self.battery = battery; self.charging = charging
        self.onPower = onPower; self.blocked = blocked; self.problem = problem; self.warning = warning
        self.sleepStillOff = sleepStillOff
    }

    enum CodingKeys: String, CodingKey {
        case on, busy, machine, lidCanClose, since, displaysOff, displaysOffSince, hasDisplays, backAt
        case battery, charging, onPower, blocked, problem, warning, sleepStillOff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
        busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        machine = (try? c.decodeIfPresent(MachineKind.self, forKey: .machine)) ?? .laptop
        lidCanClose = try c.decodeIfPresent(Bool.self, forKey: .lidCanClose) ?? false
        since = try c.decodeIfPresent(Date.self, forKey: .since)
        displaysOff = try c.decodeIfPresent(Bool.self, forKey: .displaysOff) ?? false
        displaysOffSince = try c.decodeIfPresent(Date.self, forKey: .displaysOffSince)
        hasDisplays = try c.decodeIfPresent(Bool.self, forKey: .hasDisplays) ?? true
        backAt = try c.decodeIfPresent(Date.self, forKey: .backAt)
        battery = try c.decodeIfPresent(Int.self, forKey: .battery)
        charging = try c.decodeIfPresent(Bool.self, forKey: .charging) ?? false
        onPower = try c.decodeIfPresent(Bool.self, forKey: .onPower) ?? true
        blocked = try c.decodeIfPresent(String.self, forKey: .blocked)
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
        sleepStillOff = try c.decodeIfPresent(Bool.self, forKey: .sleepStillOff) ?? false
    }

    public var canTurnOn: Bool { blocked == nil && !busy }

    /// The tile's line on the phone: "Lid can close · 84%", "Stays awake", "Off · 84%".
    public var phoneLine: String {
        if let blocked, !on { return blocked }
        if sleepStillOff, !on { return "Your Mac is set never to sleep" }
        var parts: [String] = []
        if busy { parts.append(on ? "Turning off…" : "Turning on…") }
        else if on {
            switch machine {
            case .laptop: parts.append(lidCanClose ? "Lid can close" : "Keep the lid open")
            case .desktop: parts.append("Stays awake")
            }
        } else {
            parts.append("Off")
        }
        if let battery, machine == .laptop { parts.append(charging ? "\(battery)% · charging" : "\(battery)%") }
        return parts.joined(separator: " · ")
    }
}

/// Phone → Mac (only to a Mac naming `KeepAwakeStatus.feature`). The action is a string, so a
/// newer phone's action is ignored by an older Mac rather than ending the session.
public struct KeepAwakeRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        case on, off, displaysOn, displaysOff, timer, restoreSleep
    }
    public var action: String
    /// For `timer`: minutes from now; 0 cancels.
    public var minutes: Int?

    public init(_ action: Action, minutes: Int? = nil) {
        self.action = action.rawValue
        self.minutes = minutes
    }

    public var known: Action? { Action(rawValue: action) }
    /// A timer is between 1 minute and a day, or 0 to cancel.
    public var isValid: Bool {
        guard let known else { return false }
        if known == .timer { return minutes.map { (0...1440).contains($0) } ?? false }
        return true
    }
}

// MARK: - Warnings

public enum KeepAwakeWarning: Equatable, Sendable, Hashable {
    case lowBattery(Int)
    case longOnBattery(hours: Int)
    case hot
    case lowPowerMode

    public var text: String {
        switch self {
        case .lowBattery(let p): return "Battery \(p)% — plug in your Mac to keep it awake."
        case .longOnBattery(let h): return "On battery for \(h) hour\(h == 1 ? "" : "s") — plug in if you can."
        case .hot: return "Your Mac is hot. If it's in a bag, take it out or open the lid."
        case .lowPowerMode: return "Low Power Mode is on — your Mac stays awake but may be slower."
        }
    }

    /// For "tell once" bookkeeping.
    public var key: String {
        switch self {
        case .lowBattery: return "lowBattery"
        case .longOnBattery: return "longOnBattery"
        case .hot: return "hot"
        case .lowPowerMode: return "lowPowerMode"
        }
    }
}

public enum KeepAwakeRules {
    /// Below this, on battery, a warning.
    public static let lowBatteryWarning = 20
    /// On battery this long, a warning.
    public static let longOnBattery: TimeInterval = 2 * 3600
    /// The choices for turning itself off on a low battery (0 = never).
    public static let lowBatteryChoices = [5, 10, 20, 0]

    /// What to warn about now, most urgent first.
    public static func warnings(_ p: PowerSnapshot, onBatterySince: Date?, now: Date) -> [KeepAwakeWarning] {
        var out: [KeepAwakeWarning] = []
        if p.thermal >= .serious { out.append(.hot) }
        if p.onBattery, let b = p.battery, b < lowBatteryWarning { out.append(.lowBattery(b)) }
        if p.onBattery, let since = onBatterySince, now.timeIntervalSince(since) >= longOnBattery {
            out.append(.longOnBattery(hours: Int(now.timeIntervalSince(since) / 3600)))
        }
        if p.lowPowerMode { out.append(.lowPowerMode) }
        return out
    }

    /// Keep Awake turns itself off: the battery reached the chosen floor (on battery only).
    public static func batteryTooLow(_ p: PowerSnapshot, offAt: Int) -> Bool {
        guard offAt > 0, p.onBattery, let b = p.battery else { return false }
        return b <= offAt
    }

    /// Keep Awake turns itself off: macOS says the Mac is critically hot (it should be allowed
    /// to sleep and cool, wherever it is).
    public static func tooHot(_ p: PowerSnapshot) -> Bool { p.thermal == .critical }
}

// MARK: - Words

public enum KeepAwakeWords {
    public static let title = "Keep Awake"

    /// The one sentence under the switch.
    public static func explainer(_ machine: MachineKind) -> String {
        switch machine {
        case .laptop: return "Your Mac stays on with the lid closed, so you can use it from your iPhone."
        case .desktop: return "Your Mac stays awake and reachable, so you can use it from your iPhone."
        }
    }

    /// "On · lid can close · displays off since 3:12 · back at desk at 5:00".
    public static func macLine(_ s: KeepAwakeStatus, time: (Date) -> String) -> String {
        if s.busy { return s.on ? "Turning off…" : "Turning on…" }
        guard s.on else {
            if let b = s.blocked { return b }
            if s.sleepStillOff { return "Off · your Mac is still set never to sleep" }
            return "Off"
        }
        var parts = ["On"]
        switch s.machine {
        case .laptop: parts.append(s.lidCanClose ? "lid can close" : "keep the lid open")
        case .desktop: parts.append("stays awake")
        }
        if s.displaysOff {
            parts.append(s.displaysOffSince.map { "displays off since \(time($0))" } ?? "displays off")
        }
        if let at = s.backAt { parts.append("back at desk at \(time(at))") }
        return parts.joined(separator: " · ")
    }

    /// The menu bar's second row while on: "Displays off · idle 3m" / "Displays on · active".
    public static func displaysLine(off: Bool, idle: TimeInterval?, autoDimMinutes: Int) -> String {
        let state = off ? "Displays off" : "Displays on"
        guard let idle else { return state }
        if idle < 30 { return off ? state : "\(state) · active" }
        return "\(state) · idle \(duration(idle))"
    }

    /// "Back at desk in 1h 20m".
    public static func countdown(to deadline: Date, now: Date) -> String {
        "Back at desk in \(duration(max(60, deadline.timeIntervalSince(now))))"
    }

    /// "2h 14m", "3m", "45s".
    public static func duration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    /// "30 minutes", "1 hour", "4 hours".
    public static func choice(minutes m: Int) -> String {
        m < 60 ? "\(m) minutes" : "\(m / 60) hour\(m == 60 ? "" : "s")"
    }

    public static let timerChoices = [30, 60, 120, 240, 480]
    public static let autoDimChoices = [2, 5, 10, 15, 0]
}
