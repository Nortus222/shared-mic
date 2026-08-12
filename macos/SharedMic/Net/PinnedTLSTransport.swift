import CryptoKit
import Foundation
import Network

public enum TransportError: Error, Equatable {
    case fingerprintMismatch(expected: String, presented: String)
    case noCertificatePresented
    case connectionFailed(String)
    case timedOut
    case closed
}

extension TransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fingerprintMismatch(let expected, let presented):
            return "certificate fingerprint mismatch — pinned \(expected), presented \(presented)"
        case .noCertificatePresented:
            return "the peer presented no certificate"
        case .connectionFailed(let detail):
            return "connection failed: \(detail)"
        case .timedOut:
            return "connection timed out"
        case .closed:
            return "connection closed"
        }
    }
}

public enum PinningMode: Equatable {
    /// Every connection after pairing. The pin is the only certificate check.
    case pinned(fingerprint: String)
    /// **Pairing only.** Accepts whatever certificate is presented and reports its
    /// fingerprint so the caller can pin it — but only after the HMAC handshake on
    /// that same connection proves the peer holds the pairing token. A certificate
    /// from a peer that cannot answer the challenge is never persisted.
    case trustOnFirstUse
}

/// A framed byte-stream transport, deliberately narrow so the protocol layer can
/// be tested against a double.
public protocol MessageTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func close()
}

/// TLS 1.3 over `NWConnection` with SHA-256-of-DER certificate pinning.
///
/// protocol-v1 §2 and §11.3: there is no CA anywhere in this design, and the
/// client must explicitly opt out of both CA and hostname validation.
/// `sec_protocol_options_set_verify_block` **replaces** the default trust
/// evaluation rather than running after it, so neither check ever executes —
/// which is precisely why `Network.framework` was chosen over `URLSession`.
///
/// Two traps this class exists to contain:
///
/// 1. On a rejected verify block `NWConnection` enters `.waiting`, not `.failed`,
///    and retries **forever**. protocol-v1 §2 forbids any automatic retry after a
///    fingerprint mismatch, so any `.waiting` is treated as terminal here.
/// 2. The `NWError` that surfaces is `-9808 bad certificate format`, which says
///    nothing about pinning. The verify block therefore records *why* it refused
///    in `pinFailure` and that recorded reason wins over the opaque network error.
public final class PinnedTLSTransport: MessageTransport {
    /// Installed by `ControlClient.begin()` — which the coordinator only reaches
    /// *after* `connect`'s completion has hopped to its own queue, so bytes can
    /// already be in hand by the time this is set. Anything that arrives first is
    /// buffered by `pumpReceive` and flushed here rather than dropped; see the
    /// `pendingReceived` comment.
    public var onReceive: ((Data) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedOnReceive
        }
        set {
            lock.lock()
            storedOnReceive = newValue
            lock.unlock()
            guard newValue != nil else { return }
            // Flushed on the transport queue, never inline: every other delivery
            // runs there, so hopping keeps buffered bytes strictly ahead of the
            // next `receive` completion instead of racing it.
            queue.async { [weak self] in self?.pumpReceive() }
        }
    }

    /// Same window as `onReceive`: a close that lands before this is installed is
    /// held in `pendingClose` and delivered when it is. `didReportClose` is only
    /// set once the handler has actually been called, so a close is delivered
    /// exactly once — never zero times, never twice.
    public var onClose: ((Error?) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedOnClose
        }
        set {
            lock.lock()
            storedOnClose = newValue
            lock.unlock()
            guard newValue != nil else { return }
            queue.async { [weak self] in self?.pumpClose() }
        }
    }

    private let queue = DispatchQueue(label: "com.sharedmic.transport")
    private let lock = NSLock()

    private var storedOnReceive: ((Data) -> Void)?
    private var storedOnClose: ((Error?) -> Void)?
    /// Bytes that arrived before `onReceive` existed. protocol-v1 §6 has the
    /// server send GREETING immediately after the TLS handshake, and under
    /// TLS 1.3 the server Finished and that first application record are 0.5-RTT
    /// apart and can arrive coalesced — so this buffer is the normal case on a
    /// real link, not a corner case.
    private var pendingReceived = Data()
    /// A close that happened before `onClose` existed. Boxed so that "a clean
    /// close is pending" (`.some` carrying a nil error) stays distinguishable
    /// from "nothing is pending".
    private struct PendingClose { let error: Error? }
    private var pendingClose: PendingClose?

    private var connection: NWConnection?
    private var presentedFingerprint: String?
    private var pinFailure: TransportError?
    private var connectCompletion: ((Result<String, Error>) -> Void)?
    private var didCompleteConnect = false
    private var didReportClose = false
    private var closingIntentionally = false

    public init() {}

    public func connect(host: String,
                        port: UInt16,
                        mode: PinningMode,
                        timeout: TimeInterval = 10.0,
                        completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        connectCompletion = completion
        didCompleteConnect = false
        didReportClose = false
        closingIntentionally = false
        presentedFingerprint = nil
        pinFailure = nil
        pendingReceived = Data()
        pendingClose = nil
        lock.unlock()

        let tlsOptions = NWProtocolTLS.Options()
        let security = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { [weak self] _, trustRef, verifyComplete in
            guard let self else { verifyComplete(false); return }
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                self.record(pinFailure: .noCertificatePresented)
                verifyComplete(false)
                return
            }
            // NOTE: SecTrustEvaluate is never called. There is no CA and no
            // hostname to match — the pin below is the entire trust decision.
            let der = SecCertificateCopyData(leaf) as Data
            let fingerprint = AuthProof.fingerprint(ofDER: der)
            self.record(fingerprint: fingerprint)

            switch mode {
            case .trustOnFirstUse:
                verifyComplete(true)
            case .pinned(let expected):
                let normalized = expected.lowercased()
                if fingerprint == normalized {
                    verifyComplete(true)
                } else {
                    self.record(pinFailure: .fingerprintMismatch(expected: normalized,
                                                                 presented: fingerprint))
                    verifyComplete(false)
                }
            }
        }, queue)

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(integerLiteral: port),
                                      using: parameters)
        lock.lock(); self.connection = connection; lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.finishConnect(.success(self.currentFingerprint() ?? ""))
                self.receiveLoop()
            case .waiting(let error):
                // See the class comment: `.waiting` is where a rejected pin lands,
                // and NWConnection would otherwise retry it indefinitely.
                self.fail(with: self.recordedFailure(or: .connectionFailed("\(error)")))
            case .failed(let error):
                self.fail(with: self.recordedFailure(or: .connectionFailed("\(error)")))
            case .cancelled:
                self.reportClose(self.wasClosingIntentionally() ? nil : TransportError.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.connectIsPending() else { return }
            self.fail(with: TransportError.timedOut)
        }
    }

    public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock(); let connection = self.connection; lock.unlock()
        guard let connection else {
            completion(TransportError.closed)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

    public func close() {
        lock.lock()
        closingIntentionally = true
        let connection = self.connection
        lock.unlock()
        connection?.cancel()
    }

    // MARK: - Receive

    private func receiveLoop() {
        lock.lock(); let connection = self.connection; lock.unlock()
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.pumpReceive(appending: data)
            }
            if let error {
                self.fail(with: TransportError.connectionFailed("\(error)"))
                return
            }
            if isComplete {
                self.fail(with: TransportError.closed)
                return
            }
            self.receiveLoop()
        }
    }

    /// Appends `data` to the pending buffer and drains the whole buffer to
    /// `onReceive` if one is installed. Buffering unconditionally — rather than
    /// delivering `data` directly when a handler exists — is what keeps a late
    /// handler from receiving the newest chunk ahead of older buffered bytes.
    ///
    /// The handler is called with the lock released: it belongs to
    /// `ControlClient`, and calling out to another object while holding this
    /// class's lock would invite exactly the deadlock this transport has no way
    /// to see coming.
    private func pumpReceive(appending data: Data = Data()) {
        lock.lock()
        if !data.isEmpty { pendingReceived.append(data) }
        guard let handler = storedOnReceive, !pendingReceived.isEmpty else {
            lock.unlock()
            return
        }
        let payload = pendingReceived
        pendingReceived = Data()
        lock.unlock()
        handler(payload)
    }

    /// Delivers a close that was recorded before `onClose` existed. Same
    /// call-out-with-the-lock-released discipline as `pumpReceive`.
    private func pumpClose() {
        lock.lock()
        guard !didReportClose, let handler = storedOnClose, let pending = pendingClose else {
            lock.unlock()
            return
        }
        pendingClose = nil
        didReportClose = true
        lock.unlock()
        handler(pending.error)
    }

    // MARK: - State bookkeeping

    private func record(fingerprint: String) {
        lock.lock(); presentedFingerprint = fingerprint; lock.unlock()
    }

    private func record(pinFailure: TransportError) {
        lock.lock(); self.pinFailure = pinFailure; lock.unlock()
    }

    private func currentFingerprint() -> String? {
        lock.lock(); defer { lock.unlock() }
        return presentedFingerprint
    }

    private func recordedFailure(or fallback: TransportError) -> TransportError {
        lock.lock(); defer { lock.unlock() }
        return pinFailure ?? fallback
    }

    private func wasClosingIntentionally() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return closingIntentionally
    }

    private func connectIsPending() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !didCompleteConnect && connectCompletion != nil
    }

    private func finishConnect(_ result: Result<String, Error>) {
        lock.lock()
        guard !didCompleteConnect, let completion = connectCompletion else {
            lock.unlock()
            return
        }
        didCompleteConnect = true
        connectCompletion = nil
        lock.unlock()
        completion(result)
    }

    /// A failure before `connect` completes is reported through `connect`'s
    /// completion and nowhere else. A failure afterwards is reported through
    /// `onClose`. Either way it happens exactly once, and the connection is
    /// cancelled so nothing retries.
    ///
    /// `close()` sets `closingIntentionally` and cancels the connection before
    /// this is ever called for that shutdown. Cancelling an in-flight `receive`
    /// races the `.cancelled` state update: the receive completion can arrive
    /// first, carrying a synthetic "closed" error that would otherwise be
    /// reported as a failure even though the close was requested. Capturing
    /// whether `closingIntentionally` was *already* true — before this call
    /// sets it for its own reason — lets an intentional close win that race
    /// and always surface as `nil`, regardless of which path fires first.
    private func fail(with error: Error) {
        let pending = connectIsPending()
        lock.lock()
        let wasAlreadyClosingIntentionally = closingIntentionally
        closingIntentionally = true
        if pending { didReportClose = true }
        let connection = self.connection
        lock.unlock()

        if pending {
            finishConnect(.failure(error))
            connection?.cancel()
            return
        }
        reportClose(wasAlreadyClosingIntentionally ? nil : error)
        connection?.cancel()
    }

    /// Records the close if no handler is installed yet — deliberately *without*
    /// setting `didReportClose`, which would latch the close as delivered and
    /// leave the `ControlClient` installed a moment later unable to ever learn
    /// the connection died. `pumpClose` sets it when the handler actually runs.
    private func reportClose(_ error: Error?) {
        lock.lock()
        guard !didReportClose else { lock.unlock(); return }
        guard let handler = storedOnClose else {
            // First close wins; a second one cannot overwrite it.
            if pendingClose == nil { pendingClose = PendingClose(error: error) }
            lock.unlock()
            return
        }
        didReportClose = true
        pendingClose = nil
        lock.unlock()
        handler(error)
    }
}
