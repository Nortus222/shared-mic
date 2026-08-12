import Foundation

public enum ControlClientError: Error, Equatable {
    case unexpectedMessageBeforeAuthentication(String)
    case unexpectedAudioFrame
    case handshakeTimedOut
    case peerDead
    case protocolViolation(String)
}

extension ControlClientError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unexpectedMessageBeforeAuthentication(let type):
            return "received \(type) before authentication completed"
        case .unexpectedAudioFrame:
            return "received an AUDIO frame outside an active session"
        case .handshakeTimedOut:
            return "the handshake did not complete within 5 s"
        case .peerDead:
            return "no PONG for 45 s — the peer is dead"
        case .protocolViolation(let detail):
            return "protocol violation: \(detail)"
        }
    }
}

public protocol ControlClientDelegate: AnyObject {
    func controlClientDidAuthenticate(_ client: ControlClient, micPresent: Bool, deviceLabel: String)
    func controlClient(_ client: ControlClient, didReceive message: ControlMessage)
    func controlClient(_ client: ControlClient, didCloseWith error: Error?)
}

/// Owns one authenticated connection: the protocol-v1 §6 handshake, the §8
/// heartbeat, and dispatch of every other control message to the delegate.
///
/// It does **not** decide what to do about those messages — that is
/// `SessionController`'s job. This class only guarantees that what reaches the
/// delegate is a valid, authenticated, protocol-conformant message.
public final class ControlClient {
    public weak var delegate: ControlClientDelegate?

    private enum Phase {
        case awaitingGreeting
        case awaitingHelloAck
        case authenticated
        case finished
    }

    private let transport: MessageTransport
    private let token: Data
    private let clientId: String
    private let pingInterval: TimeInterval
    private let peerDeadTimeout: TimeInterval
    private let handshakeDeadline: TimeInterval
    private let queue = DispatchQueue(label: "com.sharedmic.control")

    private var phase: Phase = .awaitingGreeting
    private var buffer = FrameBuffer()
    private var heartbeat = HeartbeatMonitor(now: ProcessInfo.processInfo.systemUptime)
    private var heartbeatTimer: DispatchSourceTimer?
    private var handshakeTimer: DispatchSourceTimer?

    private var frameCount = 0
    private var byteCount = 0
    private var gapCount = 0
    private var lastSequence: UInt32?

    public init(transport: MessageTransport,
                token: Data,
                clientId: String,
                pingInterval: TimeInterval = SharedMicProtocol.pingInterval,
                peerDeadTimeout: TimeInterval = SharedMicProtocol.peerDeadTimeout,
                handshakeDeadline: TimeInterval = SharedMicProtocol.helloDeadline) {
        self.transport = transport
        self.token = token
        self.clientId = clientId
        self.pingInterval = pingInterval
        self.peerDeadTimeout = peerDeadTimeout
        self.handshakeDeadline = handshakeDeadline
    }

    public var isAuthenticated: Bool {
        queue.sync { phase == .authenticated }
    }

    /// Counters only — the PCM itself is discarded the moment it is validated.
    /// Phase 1 has no renderer, and audio payload is never logged or persisted.
    ///
    /// `audioFramesReceived`/`audioBytesReceived` are cumulative for the whole
    /// connection, by design — they are what makes "an idle connection carries
    /// zero audio bytes" assertable. `sequenceGaps` is also connection-lifetime,
    /// but its baseline is reset on every `START_ACK` (protocol-v1 §4: sequence
    /// starts at 0 per session), so a legitimate session restart on the same
    /// connection is never counted as a gap.
    public var audioFramesReceived: Int { queue.sync { frameCount } }
    public var audioBytesReceived: Int { queue.sync { byteCount } }
    public var sequenceGaps: Int { queue.sync { gapCount } }

    public func begin() {
        transport.onReceive = { [weak self] data in
            self?.queue.async { self?.ingest(data) }
        }
        transport.onClose = { [weak self] error in
            self?.queue.async { self?.finish(with: error) }
        }
        queue.async { [weak self] in
            self?.startHandshakeDeadline()
        }
    }

    public func send(_ message: ControlMessage) {
        queue.async { [weak self] in
            self?.write(message)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelTimers()
            self.phase = .finished
        }
        transport.close()
    }

    // MARK: - Receive path (always on `queue`)

    private func ingest(_ data: Data) {
        guard phase != .finished else { return }
        buffer.append(data)
        while true {
            let frame: DecodedFrame?
            do {
                frame = try buffer.nextFrame()
            } catch {
                abort(with: ControlClientError.protocolViolation(String(describing: error)))
                return
            }
            guard let frame else { return }
            switch frame.type {
            case .control:
                do {
                    try handle(try ControlCodec.decode(frame.payload))
                } catch let error as ControlClientError {
                    abort(with: error)
                    return
                } catch {
                    abort(with: ControlClientError.protocolViolation(String(describing: error)))
                    return
                }
            case .audio:
                do {
                    try handleAudio(frame.payload)
                } catch {
                    abort(with: ControlClientError.protocolViolation(String(describing: error)))
                    return
                }
            }
            if phase == .finished { return }
        }
    }

    private func handle(_ message: ControlMessage) throws {
        switch phase {
        case .awaitingGreeting:
            guard case .greeting(_, let nonceHex) = message else {
                throw ControlClientError.unexpectedMessageBeforeAuthentication(message.typeName)
            }
            // protocol-v1 §6 step 2: HMAC over the RAW nonce bytes, not the hex.
            guard let nonce = Hex.decode(nonceHex), nonce.count == SharedMicProtocol.nonceBytes else {
                throw ControlClientError.protocolViolation("GREETING nonce is not 32 hex-encoded bytes")
            }
            phase = .awaitingHelloAck
            write(.hello(clientId: clientId, mac: AuthProof.proof(token: token, nonce: nonce)))

        case .awaitingHelloAck:
            guard case .helloAck(_, let micPresent, let deviceLabel) = message else {
                throw ControlClientError.unexpectedMessageBeforeAuthentication(message.typeName)
            }
            phase = .authenticated
            cancelHandshakeDeadline()
            startHeartbeat()
            let client = self
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.controlClientDidAuthenticate(client,
                                                            micPresent: micPresent,
                                                            deviceLabel: deviceLabel)
            }

        case .authenticated:
            if case .pong(let seq) = message {
                do {
                    try heartbeat.handlePong(seq: seq, now: ProcessInfo.processInfo.systemUptime)
                } catch {
                    throw ControlClientError.protocolViolation("PONG seq \(seq) matches no outstanding PING")
                }
                return
            }
            if case .stopAck = message {
                // protocol-v1 §4: audio `sequence` starts at 0 per session. Reset
                // the gap-detection baseline the moment a session is confirmed
                // over, so the next AUDIO frame — from whichever session sends it
                // next — establishes a fresh baseline instead of being compared
                // against this session's tail.
                //
                // Deliberately anchored to STOP_ACK rather than the next
                // START_ACK: the mock (and, per protocol-v1 §7, a legitimate
                // Windows implementation) may start a new session's audio thread
                // before it enqueues that session's own START_ACK for sending, so
                // the new session's frame 0 can race ahead of its own START_ACK on
                // the wire. STOP_ACK carries no such race — the outgoing session's
                // audio thread is joined and its queue drained synchronously
                // before STOP_ACK is ever enqueued, and the next session's first
                // control or audio byte cannot reach this client until this
                // client's own STOP request — and therefore this STOP_ACK — has
                // already been sent and observed, by the ordering guarantee of a
                // single TCP stream.
                lastSequence = nil
            }
            let client = self
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.controlClient(client, didReceive: message)
            }

        case .finished:
            break
        }
    }

    private func handleAudio(_ payload: Data) throws {
        guard phase == .authenticated else {
            throw ControlClientError.unexpectedAudioFrame
        }
        // Strict: protocol-v1 §4 requires exactly 1932 bytes. decodePayload throws
        // otherwise, which closes the connection.
        let frame = try AudioFrameCodec.decodePayload(payload)
        if let previous = lastSequence, frame.sequence != previous &+ 1 {
            gapCount += 1
        }
        lastSequence = frame.sequence
        frameCount += 1
        byteCount += frame.pcm.count
        // The PCM goes no further. Phase 2 hands it to PCMRingBuffer here.
    }

    // MARK: - Send path

    private func write(_ message: ControlMessage) {
        guard phase != .finished else { return }
        let bytes: Data
        do {
            bytes = try ControlCodec.encodeFrame(message)
        } catch {
            abort(with: ControlClientError.protocolViolation("could not encode \(message.typeName)"))
            return
        }
        transport.send(bytes) { [weak self] error in
            guard let error else { return }
            self?.queue.async {
                self?.abort(with: ControlClientError.protocolViolation("send failed: \(error)"))
            }
        }
    }

    // MARK: - Timers

    private func startHandshakeDeadline() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + handshakeDeadline)
        timer.setEventHandler { [weak self] in
            guard let self, self.phase != .authenticated, self.phase != .finished else { return }
            self.abort(with: ControlClientError.handshakeTimedOut)
        }
        timer.resume()
        handshakeTimer = timer
    }

    private func cancelHandshakeDeadline() {
        handshakeTimer?.cancel()
        handshakeTimer = nil
    }

    private func startHeartbeat() {
        heartbeat = HeartbeatMonitor(now: ProcessInfo.processInfo.systemUptime)
        // Tick at a tenth of the ping interval so both the send schedule and the
        // dead-peer deadline are checked with useful resolution without a timer
        // per deadline.
        let tick = max(pingInterval / 10.0, 0.05)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self, self.phase == .authenticated else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.heartbeat.isPeerDead(now: now, timeout: self.peerDeadTimeout) {
                self.abort(with: ControlClientError.peerDead)
                return
            }
            if self.heartbeat.shouldSendPing(now: now, interval: self.pingInterval) {
                self.write(self.heartbeat.makePing(now: now))
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func cancelTimers() {
        cancelHandshakeDeadline()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - Teardown

    /// Every protocol violation in this protocol has the same consequence:
    /// close the connection (protocol-v1 §1, §3, §4, §6).
    private func abort(with error: Error) {
        guard phase != .finished else { return }
        finish(with: error)
        transport.close()
    }

    private func finish(with error: Error?) {
        guard phase != .finished else { return }
        phase = .finished
        cancelTimers()
        let client = self
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.controlClient(client, didCloseWith: error)
        }
    }
}
