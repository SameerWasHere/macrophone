import AppKit
import Combine
import Foundation
import MacrophoneKit
import Network
import ServiceManagement

/// A phone asking to pair by code, waiting for the person's answer.
struct CodeRequest: Identifiable, Equatable {
    let id = UUID()
    let code: String
    let phoneName: String
    static func == (a: CodeRequest, b: CodeRequest) -> Bool { a.id == b.id }
}

/// The app's hub: the link to the phones, history, Send to (the live targets and the shared
/// choice), settings, the pull API.
@MainActor
final class AppModel: ObservableObject, LinkServerDelegate {
    let settings = Settings()
    /// The apps and windows open on this Mac that have somewhere to type.
    let scanner = TargetScanner()
    let log: DiagnosticLog
    let server: LinkServer
    let historyStore: HistoryStore<HistoryItem>
    let popup = PopupController()
    let api: LocalAPIServer
    private(set) var delivery: DeliveryEngine!
    /// A phone watching the window it sends to (WatchService).
    private(set) var watch: WatchService!
    private(set) var attention: AttentionWatcher!
    /// Phone → the app it's watching, for the menu.
    @Published private(set) var watching: [UUID: String] = [:]

    @Published private(set) var history: [HistoryItem] = []
    /// What Send to can pick from right now (newest first).
    @Published private(set) var targets: [LiveTarget] = []
    /// A scan has finished since launch (until then, "not open" can't be said of anything).
    private(set) var targetsKnown = false
    /// A Macrophone window or the menu is open (the target list is being looked at).
    private var windowOpen = false
    private var menuOpen = false
    @Published private(set) var peers: [PairedPeer] = []
    @Published private(set) var connected: Set<UUID> = [] { didSet { if connected != oldValue { updateScanning() } } }
    /// Phones connected from beyond this network (remote access): the status line says so, and
    /// watching sends them smaller pictures.
    @Published private(set) var remotePeers: Set<UUID> = []
    /// Where this Mac can be reached from away right now (remote access on): its Tailscale
    /// address and name when Tailscale is running, then its local addresses — all with the port.
    @Published private(set) var remoteAddresses: [RemoteAddress] = []
    private var pathMonitor: NWPathMonitor?
    private var addressRefresh: Task<Void, Never>?
    @Published private(set) var phoneVersions: [UUID: String] = [:]
    @Published private(set) var listenerState: LinkServer.ListenerState = .starting
    @Published private(set) var apiState: LocalAPIServer.State = .off
    @Published private(set) var apiToken: String
    @Published private(set) var lastReceived: Date?
    @Published private(set) var accessibilityGranted = Paster.isTrusted
    @Published var launchAtLogin: Bool = false
    /// The menu bar has hidden Macrophone's icon (a crowded bar, the notch, or it was turned off).
    @Published private(set) var menuBarIconHidden = false
    /// Called once when the icon is found hidden (the app opens its window to say so).
    var onMenuBarIconHidden: () -> Void = {}

    // Pairing
    @Published private(set) var invite: PairingInvite?
    @Published private(set) var inviteExpires: Date?
    @Published var codeRequest: CodeRequest?
    /// Set when a phone just paired (the setup screen moves on).
    @Published private(set) var justPaired: PairedPeer?
    private var codeContinuation: CheckedContinuation<Bool, Never>?
    private var inviteTimer: Timer?

    /// Ticks the status item for a silent copy.
    var flashStatusItem: () -> Void = {}

    private var bag: Set<AnyCancellable> = []

    init() {
        log = DiagnosticLog(url: AppPaths.diagnostics)
        let s = settings
        historyStore = HistoryStore<HistoryItem>(url: AppPaths.history, capacity: 50, enabled: s.historyEnabled)
        let identity = DeviceIdentity.load(defaults: AppPaths.defaults, name: AppPaths.computerName)
        server = LinkServer(identity: identity,
                            store: KeychainPairingStore(service: AppPaths.keychainService, directory: AppPaths.supportDirectory),
                            appVersion: AppPaths.appVersion, seenIDsURL: AppPaths.seenIDs)

        // The API token lives in api.json (0600), which the CLI and MCP server read.
        let token = APIConfig.load()?.token ?? APIConfig.newToken()
        apiToken = token
        api = LocalAPIServer(token: token, status: .init(app_version: AppPaths.appVersion, history_enabled: s.historyEnabled, phones: []))

        delivery = DeliveryEngine(app: self)
        watch = WatchService(app: self)
        attention = AttentionWatcher(app: self)
        watch.onChange = { [weak self] in
            guard let self, self.watching != self.watch.watching else { return }
            self.watching = self.watch.watching
        }
        server.log = log
        server.delegate = self
        // What this Mac can do beyond the first version, for phones that can too.
        server.macFeatures = [WatchVideo.feature, WatchVideo.fitFeature, WatchScroll.feature]
        // Swipes skip the main actor: the receive loop hands each step to the watch's poster.
        let watchService = watch!
        server.watchInput = { peer, input in watchService.scrollInput(peer, input) }
        history = historyStore.all
        peers = server.store.peers()
        lastReceived = historyStore.latest?.receivedAt

        let store = historyStore
        api.latest = { store.latest?.pulled }
        // With history off, the API still answers with the one item held in memory.
        api.history = { n in
            store.isEnabled ? Array(store.all.prefix(n)).map(\.pulled) : (store.latest.map { [$0.pulled] } ?? [])
        }
        api.log = log
        api.onStateChange = { [weak self] state in
            guard let self else { return }
            self.apiState = state
            if case .listening(let port) = state { self.writeAPIConfig(port: port) }
        }

        scanner.onChange = { [weak self] list in self?.targetsChanged(list) }

        settings.$historyEnabled.dropFirst().sink { [weak self] on in
            guard let self else { return }
            self.historyStore.isEnabled = on
            self.history = self.historyStore.all
            self.log.add("history \(on ? "on" : "off")")
            self.pushStatus()
        }.store(in: &bag)
        settings.$apiEnabled.dropFirst().sink { [weak self] on in
            guard let self else { return }
            if on { self.api.start() } else { self.api.stop() }
            self.log.add("API \(on ? "on" : "off")")
        }.store(in: &bag)
        Publishers.Merge(settings.$remoteAccess.dropFirst().map { _ in () }, settings.$remotePort.dropFirst().map { _ in () })
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.applyRemoteAccess() }
            .store(in: &bag)

        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // The trust flag flips a moment after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refreshAccessibility() }
            }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshAccessibility(); Notifier.shared.refresh() }
            .store(in: &bag)

        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func start() {
        log.add("app started \(AppPaths.appVersion) (\(AppPaths.buildNumber)) · Accessibility \(accessibilityGranted ? "on" : "off") · Screen Recording \(CGPreflightScreenCaptureAccess() ? "on" : "off")")
        server.setRemote(remoteConfig)
        server.start()
        // The addresses follow the network: Tailscale starting or stopping, a new Wi-Fi.
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.refreshRemoteAddresses() } }
        m.start(queue: DispatchQueue(label: "macrophone.path", qos: .utility))
        pathMonitor = m
        if settings.apiEnabled { api.start() } else { apiState = .off }
        attention.update()
        pushStatus()
        // Nothing lands without Accessibility: ask at launch, which also puts Macrophone in the list.
        if !accessibilityGranted { _ = Paster.requestTrust() }
    }

    func refreshAccessibility() {
        let t = Paster.isTrusted
        if t != accessibilityGranted { accessibilityGranted = t; log.add("accessibility \(t ? "granted" : "not granted")") }
    }

    // MARK: Away from home (remote access)

    private var remoteConfig: RemoteConfig? {
        settings.remoteAccess ? RemoteConfig(port: UInt16(clamping: settings.remotePort)) : nil
    }

    /// The setting or the port changed: the listener moves (phones stay connected), and every
    /// phone that keeps addresses hears the new list (empty when off).
    private func applyRemoteAccess() {
        server.setRemote(remoteConfig)
        log.add(settings.remoteAccess ? "remote access on (port \(settings.remotePort))" : "remote access off")
        refreshRemoteAddresses()
    }

    /// Re-reads this Mac's addresses (a reverse lookup for the Tailscale name, off the main
    /// thread), publishes them and tells the connected phones when they changed.
    func refreshRemoteAddresses() {
        addressRefresh?.cancel()
        guard let config = remoteConfig else {
            if !remoteAddresses.isEmpty { remoteAddresses = []; server.broadcastRemoteAddresses([]) }
            return
        }
        addressRefresh = Task { [weak self] in
            let own = NetworkAddresses.current()
            var name: String?
            if let ts = own.first(where: \.isTailscale) { name = await NetworkAddresses.tailscaleName(for: ts.host) }
            guard !Task.isCancelled, let self else { return }
            let list = NetworkAddresses.remoteAddresses(port: config.port, tailscaleName: name)
            guard list != self.remoteAddresses else { return }
            self.remoteAddresses = list
            self.log.add("remote addresses: \(list.count) (Tailscale \(list.contains { $0.isTailscale } ? "yes" : "no"))")
            self.server.broadcastRemoteAddresses(list)
        }
    }

    /// The Tailscale address among them, if Tailscale is running here.
    var tailscaleAddress: RemoteAddress? { remoteAddresses.first { RemoteAddressRule.isTailscale($0.host) } }
    var tailscaleName: RemoteAddress? { remoteAddresses.first { RemoteAddressRule.isTailscaleName($0.host) } }
    var localAddresses: [RemoteAddress] { remoteAddresses.filter { !$0.isTailscale } }

    // MARK: History

    func record(_ item: HistoryItem) {
        historyStore.add(item)
        history = historyStore.all
        lastReceived = item.receivedAt
        api.publish(item.pulled)
    }

    func update(_ item: HistoryItem) {
        historyStore.update(item)
        history = historyStore.all
    }

    /// Which phone sent each recent dictation, so its final outcome can be reported back.
    private var senders: [(id: UUID, peer: UUID)] = []

    func noteSender(_ id: UUID, peer: UUID) {
        senders.append((id, peer))
        if senders.count > 100 { senders.removeFirst(senders.count - 100) }
    }

    func updateOutcome(_ id: UUID, _ outcome: HistoryItem.Outcome, _ detail: String) {
        reportLanding(id, outcome, detail)
        guard var item = historyStore.all.first(where: { $0.id == id }) ?? (historyStore.latest?.id == id ? historyStore.latest : nil) else { return }
        item.outcome = outcome
        item.detail = detail
        update(item)
    }

    /// Tells the phone where its dictation finally landed (a retry after a failure reports again).
    private func reportLanding(_ id: UUID, _ outcome: HistoryItem.Outcome, _ detail: String) {
        guard let peer = senders.last(where: { $0.id == id })?.peer else { return }
        let result: LandingResult
        switch outcome {
        case .pasted: result = detail.hasPrefix("Sent to") ? .sent : .pasted
        case .copied: result = .copied
        case .cancelled: result = .cancelled
        case .failed: result = .failed
        case .pending: return
        }
        server.reportLanding(id, result: result, detail: detail, to: peer)
        log.add("told the phone: \(result.rawValue)")
    }

    func deleteHistoryItem(_ id: UUID) {
        historyStore.remove(id)
        history = historyStore.all
    }

    func clearHistory() {
        historyStore.clear()
        history = []
        log.add("history cleared")
    }

    // MARK: API

    private func writeAPIConfig(port: UInt16) {
        // A debug test instance never touches the CLI's config (the real app owns it).
        if AppPaths.instance != nil { return }
        let cfg = APIConfig(port: port, token: apiToken)
        do {
            try cfg.save()
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: APIConfig.fileURL.path)
        } catch {
            log.add("couldn't write api.json")
        }
    }

    func regenerateToken() {
        apiToken = APIConfig.newToken()
        api.setToken(apiToken)
        if case .listening(let port) = apiState { writeAPIConfig(port: port) } else {
            let port = APIConfig.load()?.port ?? Product.apiPort
            writeAPIConfig(port: port)
        }
        log.add("API token regenerated")
    }

    func pushStatus() {
        let connectedIDs = connected
        let phones = peers.map {
            LocalAPIServer.PhoneStatus(name: displayName($0), connected: connectedIDs.contains($0.id), last_seen: connectedIDs.contains($0.id) ? Date() : $0.lastSeen)
        }
        api.setStatus(.init(app_version: AppPaths.appVersion, history_enabled: settings.historyEnabled, phones: phones))
    }

    // MARK: Send to

    var selection: SendSelection { settings.selection }

    /// The person changed Send to on this Mac: keep it and tell every phone.
    func choose(_ sel: SendSelection) {
        let sel = SendSelection(target: sel.target, send: sel.send)
        guard sel != settings.selection else { return }
        settings.selection = sel
        server.broadcastSelection(sel)
        log.add("send to changed on the Mac (\(Self.kind(sel)))")
    }

    func setSend(_ on: Bool) { choose(SendSelection(target: settings.selection.target, send: on)) }

    /// "an app, send" — for the log (never names an app or window).
    static func kind(_ sel: SendSelection) -> String {
        let k: String
        switch sel.target {
        case .clipboard: k = "clipboard"
        case .frontApp: k = "where typing"
        case .app: k = "an app"
        }
        return sel.send ? k + ", send" : k
    }

    /// An app picked without a proper name (a bare bundle id) gets the name Finder shows.
    static func named(_ ref: TargetRef) -> TargetRef {
        guard case let .app(bid, key, name) = ref, name.isEmpty || name == bid else { return ref }
        let n = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.localizedName ?? Paster.installedName(bid) ?? name
        return .app(bundleID: bid, windowKey: key, name: n)
    }

    /// The live target a selection points at, if it's open.
    func liveTarget(for ref: TargetRef) -> LiveTarget? { targets.first { ref.matches($0) } }

    func setWindowOpen(_ open: Bool) { windowOpen = open; updateScanning() }
    func setMenuOpen(_ open: Bool) { menuOpen = open; updateScanning() }

    private func updateScanning() {
        scanner.setActive(!connected.isEmpty || windowOpen || menuOpen)
    }

    private func targetsChanged(_ list: [LiveTarget]) {
        targetsKnown = true
        targets = list
        if !connected.isEmpty { server.broadcastTargets(list) }
        normalizeSelection(list)
    }

    /// Keeps the shared choice pointing at something in the list: an app that went from one
    /// window to several is picked by its most recent window, a window whose app now has only it
    /// becomes the app, and a renamed window keeps its new name.
    private func normalizeSelection(_ list: [LiveTarget]) {
        guard case let .app(bid, key, name) = settings.selection.target else { return }
        let mine = list.filter { $0.bundleID == bid }
        guard !mine.isEmpty else { return } // not open right now: keep it
        var ref: TargetRef?
        if let key {
            if let t = mine.first(where: { $0.windowKey == key }) {
                if t.title != name { ref = t.ref }
            } else if mine.count == 1, mine[0].windowKey == nil, let id = CGWindowID(key), WindowServer.exists(id) {
                ref = mine[0].ref
            }
        } else if let t = mine.first(where: { $0.windowKey == nil }) {
            if t.title != name { ref = t.ref }
        } else {
            ref = mine[0].ref
        }
        guard let ref else { return }
        let sel = SendSelection(target: ref, send: settings.selection.send)
        settings.selection = sel
        server.broadcastSelection(sel)
    }

    // MARK: Pairing

    func beginPairing() {
        let inv = server.makeInvite()
        invite = inv
        inviteExpires = Date().addingTimeInterval(PairingInvite.lifetime)
        justPaired = nil
        writeDebugInvite(inv)
        inviteTimer?.invalidate()
        // A fresh code a little before the old one expires; only while the screen is open.
        let t = Timer(timeInterval: PairingInvite.lifetime - 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginPairing() }
        }
        RunLoop.main.add(t, forMode: .common)
        inviteTimer = t
    }

    func endPairing() {
        inviteTimer?.invalidate()
        inviteTimer = nil
        server.closePairing()
        invite = nil
        inviteExpires = nil
        answerCode(false)
    }

    func answerCode(_ match: Bool) {
        codeRequest = nil
        let c = codeContinuation
        codeContinuation = nil
        c?.resume(returning: match)
        if c != nil { log.add("code pairing \(match ? "approved" : "declined") on the Mac") }
    }

    func forget(_ peer: PairedPeer) {
        settings.deviceNames[peer.id.uuidString] = nil
        Task {
            await server.forget(peer.id)
            peers = server.store.peers()
            connected.remove(peer.id)
            pushStatus()
        }
    }

    private func writeDebugInvite(_ inv: PairingInvite) {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MACROPHONE_PAIR_URL_FILE"] {
            try? inv.url.absoluteString.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        #if DEBUG
        // A debug build doesn't add itself to Login Items unless asked.
        if ProcessInfo.processInfo.environment["MACROPHONE_REAL_LOGIN_ITEM"] != "1" {
            launchAtLogin = on
            log.add("launch at login \(on ? "on" : "off") (debug: not registered)")
            return
        }
        #endif
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.add("launch at login change failed")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setMenuBarIconHidden(_ hidden: Bool) {
        guard hidden != menuBarIconHidden else { return }
        menuBarIconHidden = hidden
        log.add("menu bar icon \(hidden ? "hidden" : "visible")")
        if hidden { onMenuBarIconHidden() }
    }

    // MARK: Phone names

    /// The name to show for a phone: the one given on this Mac, else the one it sent.
    func displayName(_ peer: PairedPeer) -> String {
        if let n = settings.deviceNames[peer.id.uuidString], !n.isEmpty { return n }
        return peer.name.isEmpty ? "iPhone" : peer.name
    }

    /// The name given on this Mac, if any.
    func customName(_ peer: PairedPeer) -> String? { settings.deviceNames[peer.id.uuidString] }

    /// Empty (or the phone's own name) goes back to the name the phone sends.
    func rename(_ peer: PairedPeer, to name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        settings.deviceNames[peer.id.uuidString] = (n.isEmpty || n == peer.name) ? nil : n
        log.add("phone renamed on this Mac")
        objectWillChange.send()
        pushStatus()
    }

    /// iOS hides device names from apps, so many phones say only "iPhone".
    static func isGenericName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return n.isEmpty || n == "iphone" || n == "ipad" || n == "ipod touch"
    }

    /// "Sameer's iPhone", from the Mac account's first name — a suggestion for a generic phone.
    static var suggestedPhoneName: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "My iPhone" : "\(first)'s iPhone"
    }

    #if DEBUG
    /// Screenshots: stand-in phones (nothing is paired or written to the keychain).
    func debugJustPaired(_ p: PairedPeer) { justPaired = p }

    func debugListenerFailed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.listenerState = .failed("Local Network is off") }
    }

    func debugStage(peers: [PairedPeer], connected: Set<UUID>) {
        self.peers = peers
        self.connected = connected
        pushStatus()
    }
    #endif

    // MARK: Status words

    var connectedPeer: PairedPeer? { peers.first { connected.contains($0.id) } }

    /// "Connected to Sameer's iPhone" / "Waiting for your iPhone" / "Pair your iPhone to start".
    var statusLine: String {
        let on = peers.filter { connected.contains($0.id) }
        let away = on.contains { remotePeers.contains($0.id) } ? " · away from home" : ""
        if on.count == 2 { return "Connected to \(displayName(on[0])) and \(displayName(on[1]))\(away)" }
        if on.count > 2 { return "Connected to \(on.count) iPhones\(away)" }
        if let p = on.first { return "Connected to \(displayName(p))\(away)" }
        if peers.isEmpty { return "No iPhone paired yet" }
        return "Waiting for your iPhone"
    }

    // MARK: LinkServerDelegate

    func linkServer(_ server: LinkServer, approveCode code: String, phoneName: String) async -> Bool {
        answerCode(false)
        log.add("code pairing: waiting for the person")
        return await withCheckedContinuation { c in
            codeContinuation = c
            codeRequest = CodeRequest(code: code, phoneName: phoneName)
            AppDelegate.shared?.showCodeApproval()
        }
    }

    func linkServerCodePairingEnded(_ server: LinkServer) {
        // The phone gave up or the code expired: take the prompt down.
        if codeRequest != nil { answerCode(false) }
    }

    func linkServer(_ server: LinkServer, didPair peer: PairedPeer) {
        peers = server.store.peers()
        justPaired = peer
        inviteTimer?.invalidate()
        invite = nil
        pushStatus()
    }

    func linkServer(_ server: LinkServer, didUnpair peerID: UUID) {
        peers = server.store.peers()
        connected.remove(peerID)
        pushStatus()
    }

    func linkServer(_ server: LinkServer, peerConnected peer: PairedPeer, appVersion: String, os: String) {
        connected.insert(peer.id)
        if server.isRemote(peer.id) { remotePeers.insert(peer.id) } else { remotePeers.remove(peer.id) }
        phoneVersions[peer.id] = "\(appVersion) · \(os)"
        // A phone renamed on the iPhone brings its new name in its hello; the store has it and
        // so does `peer`. (A name given on this Mac still wins — displayName.)
        var list = server.store.peers()
        if let i = list.firstIndex(where: { $0.id == peer.id }) { list[i].name = peer.name }
        peers = list
        log.add("phone connected (app \(appVersion))\(remotePeers.contains(peer.id) ? " from away" : "")")
        pushStatus()
        attention.update()
    }

    func linkServer(_ server: LinkServer, peerDisconnected peerID: UUID) {
        connected.remove(peerID)
        remotePeers.remove(peerID)
        peers = server.store.peers()
        log.add("phone disconnected")
        pushStatus()
        attention.update()
    }

    func linkServer(_ server: LinkServer, deliver dictation: Dictation, delayed: Bool, from peer: PairedPeer) async -> (DeliveryOutcome, String?) {
        connected.insert(peer.id)
        return delivery.handle(dictation, delayed: delayed, from: peer)
    }

    func linkServer(_ server: LinkServer, listenerChanged state: LinkServer.ListenerState) {
        listenerState = state
        if case .ready = state { refreshRemoteAddresses() }
    }

    func remoteAddresses(_ server: LinkServer) -> [RemoteAddress] { remoteAddresses }

    /// Whether that phone's link runs beyond this network (watching sends it smaller pictures).
    func isRemote(_ peerID: UUID) -> Bool { remotePeers.contains(peerID) }

    func linkServer(_ server: LinkServer, selectionChanged selection: SendSelection, from peer: PairedPeer) {
        // The phone's choice wins (on connect it sends its own first).
        let sel = SendSelection(target: Self.named(selection.target), send: selection.send)
        if sel != settings.selection {
            settings.selection = sel
            log.add("send to changed on the phone (\(Self.kind(sel)))")
        }
        normalizeSelection(targets)
    }

    func linkServerRefreshTargets(_ server: LinkServer) {
        updateScanning()
        scanner.refresh()
    }

    func liveTargets(_ server: LinkServer) -> [LiveTarget] { targets }

    func linkServer(_ server: LinkServer, watch target: TargetRef?, from peerID: UUID) {
        watch.set(target.map(Self.named), for: peerID)
    }

    func linkServer(_ server: LinkServer, watchAction action: WatchAction, from peerID: UUID) {
        watch.perform(action, for: peerID)
    }

    func linkServer(_ server: LinkServer, watchClick point: CGPoint, from peerID: UUID) {
        watch.click(point, for: peerID)
    }

    func linkServer(_ server: LinkServer, watchChoose promptID: String, index: Int, from peerID: UUID) {
        watch.choose(promptID, index: index, for: peerID)
    }

    func linkServer(_ server: LinkServer, watchKeyframeFrom peerID: UUID) {
        watch.keyframe(for: peerID)
    }

    func linkServer(_ server: LinkServer, watchFit fit: WatchFit, from peerID: UUID) {
        watch.fit(fit, for: peerID)
    }

    func installedApps(_ server: LinkServer) async -> [MacApp] {
        let list = await AppCatalog.installed()
        log.add("sent the phone \(list.count) installed apps")
        return list
    }

    func linkServer(_ server: LinkServer, openApp bundleID: String, from peerID: UUID) async -> (Bool, String) {
        let (ok, detail) = await AppCatalog.open(bundleID)
        log.add(ok ? "opened an app for the phone" : "couldn't open an app for the phone")
        // It shows up in Send to once its window is there (the scanner watches launches).
        if ok { updateScanning(); scanner.refresh() }
        return (ok, detail)
    }

    /// The menu's Stop: stop sending this phone pictures and tell it.
    func stopWatching(_ peerID: UUID) {
        watch.stop(peerID)
        Task { await server.send(.watchState(.stopped), to: peerID) }
    }
}
