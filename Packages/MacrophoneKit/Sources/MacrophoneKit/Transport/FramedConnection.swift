import CryptoKit
import Foundation
import Network

/// Length-prefixed frames over one NWConnection, with async send/receive.
/// Frames are capped at 2 MB — a dictation is a few KB; a watched window's picture a few
/// hundred (the Mac keeps each under 900 KB of JPEG).
public final class FramedConnection: @unchecked Sendable {
    public static let maxFrame = 2 << 20

    public let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var closed = false
    private var stateHandlers: [(NWConnection.State) -> Void] = []

    public init(_ connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "macrophone.conn")) {
        self.connection = connection
        self.queue = queue
    }

    public var endpoint: NWEndpoint { connection.endpoint }

    /// Called on every state change (on the connection's queue).
    public func onState(_ handler: @escaping (NWConnection.State) -> Void) {
        lock.lock(); stateHandlers.append(handler); lock.unlock()
    }

    /// Starts the connection and waits until it is ready (or fails, or times out).
    public func start(timeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); readyContinuation = c; lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.lock.lock(); let handlers = self.stateHandlers; self.lock.unlock()
                handlers.forEach { $0(state) }
                switch state {
                case .ready:
                    self.resumeReady(nil)
                case .failed(let e):
                    self.resumeReady(LinkError.connectionFailed(e.localizedDescription))
                case .waiting(let e):
                    // .waiting means "no route right now" — for a dial with a timeout, that's a failure.
                    self.resumeReady(LinkError.connectionFailed(e.localizedDescription))
                case .cancelled:
                    self.resumeReady(LinkError.cancelled)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resumeReady(LinkError.timedOut) }
        }
    }

    /// For connections the listener already accepted: they still need `start`, but the
    /// caller doesn't want to dial with a timeout.
    public func startAccepted() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.lock(); let handlers = self.stateHandlers; self.lock.unlock()
            handlers.forEach { $0(state) }
        }
        connection.start(queue: queue)
    }

    /// Why the dial failed, in a few words (for the log: never an address).
    public private(set) var lastFailure: String?

    private func resumeReady(_ error: Error?) {
        lock.lock()
        let c = readyContinuation
        readyContinuation = nil
        if error == nil { isReady = true }
        if let error, c != nil {
            switch error as? LinkError {
            case .timedOut?: lastFailure = "timed out"
            case let .connectionFailed(why)?: lastFailure = why
            default: lastFailure = "\(error)"
            }
        }
        lock.unlock()
        guard let c else { return }
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    public func send(_ payload: Data) async throws {
        guard payload.count <= Self.maxFrame else { throw LinkError.protocolError("frame too large") }
        var frame = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: LinkError.connectionFailed(error.localizedDescription)) } else { c.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        let header = try await read(exactly: 4)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length <= Self.maxFrame else { throw LinkError.protocolError("frame too large") }
        if length == 0 { return Data() }
        return try await read(exactly: length)
    }

    /// Receive with a deadline.
    public func receive(timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LinkError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LinkError.timedOut }
            return first
        }
    }

    private func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error { c.resume(throwing: LinkError.connectionFailed(error.localizedDescription)); return }
                if let data, data.count == count { c.resume(returning: data); return }
                if isComplete { c.resume(throwing: LinkError.connectionFailed("closed")); return }
                c.resume(throwing: LinkError.protocolError("short read"))
            }
        }
    }

    public func cancel() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        if !already { connection.cancel() }
        resumeReady(LinkError.cancelled)
    }

    // MARK: JSON helpers

    func sendHandshake(_ h: Handshake) async throws {
        try await send(WireCoding.encoder.encode(h))
    }

    func receiveHandshake(timeout: TimeInterval = 15) async throws -> Handshake {
        let d = try await receive(timeout: timeout)
        do { return try WireCoding.decoder.decode(Handshake.self, from: d) } catch {
            throw LinkError.protocolError("bad handshake frame")
        }
    }
}

extension FramedConnection {
    /// The route this connection takes, from its path (the interface in use and the other end).
    public var route: LinkRoute {
        let path = connection.currentPath
        var host: String?
        switch path?.remoteEndpoint ?? connection.endpoint {
        case let .hostPort(h, _):
            switch h {
            case let .ipv4(a): host = "\(a)"
            case let .ipv6(a): host = "\(a)"
            case let .name(n, _): host = n
            @unknown default: host = nil
            }
        default: host = nil
        }
        return LinkRoute.classify(host: host, interface: path?.availableInterfaces.first?.name)
    }
}

/// A connection after the handshake: every frame sealed.
public final class SecureSession: @unchecked Sendable {
    public let connection: FramedConnection
    public let peerID: UUID
    /// The link runs beyond the local network (a Tailscale or forwarded-port address, not
    /// Bonjour): a slower path, so watching favours smaller pictures.
    public let isRemote: Bool
    /// How it's connected (home network, nearby, Tailscale, internet), read when it opened.
    public let route: LinkRoute
    private var sealer: FrameSealer
    private var opener: FrameOpener
    private let sendLock = AsyncLock()
    /// The video lane's secrets (VideoLane.swift) and the lane, once one joins.
    let laneSecrets: LaneSecrets?
    let laneSlot = LaneSlot()

    init(connection: FramedConnection, peerID: UUID, sendKey: SymmetricKey, receiveKey: SymmetricKey, isRemote: Bool = false,
         laneSecrets: LaneSecrets? = nil) {
        self.connection = connection
        self.peerID = peerID
        self.isRemote = isRemote
        self.route = connection.route
        self.sealer = FrameSealer(key: sendKey)
        self.opener = FrameOpener(key: receiveKey)
        self.laneSecrets = laneSecrets
    }

    public func send(_ message: Message) async throws {
        // The window's pictures go on the video lane when there is one; if it fails they come
        // back here (the phone asks for a keyframe for any it missed).
        if VideoLane.rides(message), let lane = laneSlot.get() {
            do { try await lane.send(message); return } catch { detachLane(lane) }
        }
        try await sendLock.withLock {
            let plain = try WireCoding.encoder.encode(message)
            let sealed = try self.sealer.seal(plain)
            try await self.connection.send(sealed)
        }
    }

    /// Only one task reads a session at a time (its receive loop).
    public func receive() async throws -> Message {
        let frame = try await connection.receive()
        let plain: Data
        do { plain = try opener.open(frame) } catch { throw LinkError.protocolError("frame failed to open") }
        do { return try WireCoding.decoder.decode(Message.self, from: plain) } catch {
            throw LinkError.protocolError("unreadable message")
        }
    }

    public func close() {
        laneSlot.closeAll()
        connection.cancel()
    }
}

/// A tiny async mutex so sends never interleave their counters.
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
