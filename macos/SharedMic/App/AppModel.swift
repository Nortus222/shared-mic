import Foundation
import SwiftUI

/// The SwiftUI-facing view of `ConnectionCoordinator`. Holds no protocol logic of
/// its own — every value here is published straight from the coordinator's
/// callbacks, which already arrive on the main queue.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var state: AgentState = .unpaired
    @Published public private(set) var deviceLabel: String = ""
    @Published public private(set) var micPresent: Bool = false
    @Published public private(set) var pairedHost: String?
    @Published public private(set) var lastNotice: String?
    @Published public private(set) var fingerprintWarning: String?
    @Published public private(set) var audioBytesReceived: Int = 0
    @Published public private(set) var isPairing: Bool = false

    @Published public var hostField: String = ""
    @Published public var portField: String = String(SharedMicProtocol.defaultPort)
    @Published public var pairingField: String = ""

    private let coordinator: ConnectionCoordinator
    private var refreshTimer: Timer?

    public init(store: PairingStore = KeychainPairingStore(),
                clientId: String = Host.current().localizedName ?? "mac",
                autoStart: Bool = true) {
        coordinator = ConnectionCoordinator(store: store, clientId: clientId)
        pairedHost = coordinator.pairedHost
        hostField = coordinator.pairedHost ?? ""
        state = coordinator.state

        coordinator.onStateChange = { [weak self] newState in
            guard let self else { return }
            Task { @MainActor in
                self.state = newState
                self.deviceLabel = self.coordinator.deviceLabel
                self.micPresent = self.coordinator.micPresent
                self.pairedHost = self.coordinator.pairedHost
                self.audioBytesReceived = self.coordinator.audioBytesReceived
            }
        }
        coordinator.onNotice = { [weak self] message in
            Task { @MainActor in self?.lastNotice = message }
        }
        coordinator.onFingerprintWarning = { [weak self] expected, presented in
            Task { @MainActor in
                self?.fingerprintWarning = """
                    The Windows agent presented a different certificate than the one you paired with.
                    Pinned:    \(expected)
                    Presented: \(presented)
                    SharedMic has stopped and will not reconnect. If you did not just reinstall or \
                    re-pair the Windows agent, treat this as a possible attack. Re-pair explicitly to continue.
                    """
            }
        }

        if autoStart {
            coordinator.startIfPaired()
        }
    }

    public var statusText: String { state.displayName }

    public var canStart: Bool {
        state == .idle && micPresent
    }

    public var canStop: Bool {
        if case .streaming = state { return true }
        return false
    }

    public func pair() {
        guard !isPairing else { return }
        let port = UInt16(portField) ?? SharedMicProtocol.defaultPort
        let host = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairingString = pairingField
        isPairing = true
        lastNotice = nil
        fingerprintWarning = nil

        coordinator.pair(host: host, port: port, pairingString: pairingString) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isPairing = false
                switch result {
                case .success(let record):
                    // Never keep the pairing string in memory or on screen once it
                    // has served its purpose.
                    self.pairingField = ""
                    self.pairedHost = record.host
                    self.lastNotice = "Paired with \(record.host)."
                case .failure(let error):
                    self.lastNotice = String(describing: error)
                }
            }
        }
    }

    public func unpair() {
        coordinator.unpair()
        pairedHost = nil
        fingerprintWarning = nil
        lastNotice = "Unpaired."
        // A pair() racing this unpair() may have its completion dropped by the
        // coordinator's generation guard (it belongs to a torn-down attempt) and
        // so never flip `isPairing` back off itself. Any teardown path clears it
        // here so the pairing form can never be left permanently disabled.
        isPairing = false
    }

    // TEMPORARY PHASE 1 SCAFFOLDING — replaced by AudioDemandObserver in Phase 3.
    public func startSession() { coordinator.requestStart() }

    // TEMPORARY PHASE 1 SCAFFOLDING — replaced by AudioDemandObserver in Phase 3.
    public func stopSession() { coordinator.requestStop() }

    public func quit() {
        coordinator.shutdown()
        NSApplication.shared.terminate(nil)
    }
}
