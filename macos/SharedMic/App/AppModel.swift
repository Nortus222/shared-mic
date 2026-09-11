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
    @Published public private(set) var demandProcesses: [DemandingProcess] = []
    @Published public private(set) var holdRemaining: TimeInterval?
    @Published public private(set) var systemInputName: String?
    @Published public private(set) var systemInputIsBlackHole: Bool = false
    @Published public private(set) var stopDebounceMs: Int = DemandSettings.defaultStopDebounceMs
    @Published public private(set) var debounceFireCount: Int = 0
    @Published public private(set) var lastActivationLatencyMs: Double?
    @Published public private(set) var sessionCount: Int = 0
    @Published public private(set) var loginLaunchEnabled: Bool = false

    @Published public var hostField: String = ""
    @Published public var portField: String = String(SharedMicProtocol.defaultPort)
    @Published public var pairingField: String = ""

    private let coordinator: ConnectionCoordinator
    private let readSystemInput: () -> SystemInputInfo?
    private let loginItems: LoginItemManager
    private var refreshTimer: Timer?

    public init(store: PairingStore = KeychainPairingStore(),
                clientId: String = Host.current().localizedName ?? "mac",
                autoStart: Bool = true,
                makeRenderer: (() -> RendererControl)? = nil,
                demandSettings: DemandSettingsStore = UserDefaultsDemandSettingsStore(),
                makeObserver: ((@escaping (DemandSnapshot) -> Void) -> AudioDemandObserver)? = nil,
                readSystemInput: (() -> SystemInputInfo?)? = nil,
                loginItems: LoginItemManager = LoginItemManager()) {
        // Production default is the live Core Audio observer; tests inject a
        // fake (or an empty one for hermetic non-demand tests) so unit tests
        // never depend on what the host machine happens to be recording.
        let observerFactory = makeObserver ?? { onChange in
            AudioDemandObserver(query: LiveCoreAudioQuery(), onChange: onChange)
        }
        coordinator = ConnectionCoordinator(store: store, clientId: clientId,
                                            makeRenderer: makeRenderer,
                                            demandSettings: demandSettings,
                                            makeObserver: observerFactory)
        self.loginItems = loginItems
        self.readSystemInput = readSystemInput ?? SystemInputDevice.current
        loginLaunchEnabled = loginItems.isEnabled
        pairedHost = coordinator.pairedHost
        hostField = coordinator.pairedHost ?? ""
        state = coordinator.state
        demandProcesses = coordinator.demandSnapshot.processes
        stopDebounceMs = coordinator.stopDebounceMs

        coordinator.onStateChange = { [weak self] newState in
            guard let self else { return }
            Task { @MainActor in
                self.state = newState
                self.deviceLabel = self.coordinator.deviceLabel
                self.micPresent = self.coordinator.micPresent
                self.pairedHost = self.coordinator.pairedHost
                self.audioBytesReceived = self.coordinator.audioBytesReceived
                self.refreshDemandDerived()
            }
        }
        coordinator.onDemandChange = { [weak self] snapshot in
            Task { @MainActor in
                self?.demandProcesses = snapshot.processes
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

        // The byte counter is the only value here that changes without a state
        // change, and "zero bytes while idle" is this project's headline
        // invariant — a readout frozen at whatever it was when streaming began
        // would be worse than none. 1 Hz with generous tolerance is enough for a
        // human reading a menu and cheap enough to leave running. The hold
        // countdown, system-input row, and debounce diagnostics ride the same
        // tick: all slow-moving, all human-read.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.audioBytesReceived = self.coordinator.audioBytesReceived
                self.refreshDemandDerived()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refreshDemandDerived()

        if autoStart {
            coordinator.startIfPaired()
        }
    }

    deinit {
        // The timer holds only a weak reference back here, so it never keeps
        // this object alive; invalidating releases it from the main run loop.
        // This type is `@MainActor` and is only ever released from the main
        // thread, which is where `invalidate()` has to run.
        refreshTimer?.invalidate()
    }

    private func refreshDemandDerived() {
        holdRemaining = coordinator.holdRemaining
        stopDebounceMs = coordinator.stopDebounceMs
        debounceFireCount = coordinator.debounceFireCount
        lastActivationLatencyMs = coordinator.lastActivationLatencyMs
        sessionCount = coordinator.sessionCountValue
        if let input = readSystemInput() {
            systemInputName = input.name
            systemInputIsBlackHole = input.isBlackHole
        } else {
            systemInputName = nil
            systemInputIsBlackHole = false
        }
    }

    public var statusText: String {
        if case .disabled = state { return "Disabled — remote microphone off" }
        if let remaining = holdRemaining, remaining > 0 {
            return "Held \(Self.formatRemaining(remaining)) remaining"
        }
        return state.displayName
    }

    public var demandCount: Int { demandProcesses.count }

    public var holdDisplay: String? {
        guard let remaining = holdRemaining, remaining > 0 else { return nil }
        return "Held \(Self.formatRemaining(remaining)) remaining"
    }

    public static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public var isDisabled: Bool {
        if case .disabled = state { return true }
        return false
    }

    public func disable() { coordinator.disable() }
    public func enable() { coordinator.enable() }
    public func beginHold() { coordinator.beginHold() }
    public func cancelHold() { coordinator.cancelHold() }
    public func setStopDebounceMs(_ ms: Int) { coordinator.setStopDebounceMs(ms) }

    public func refreshLoginLaunchStatus() {
        loginLaunchEnabled = loginItems.isEnabled
    }

    public func setLoginLaunch(_ enabled: Bool) {
        do {
            try loginItems.setEnabled(enabled)
            loginLaunchEnabled = loginItems.isEnabled
        } catch {
            loginLaunchEnabled = loginItems.isEnabled
            lastNotice = "Could not change launch-at-login: \(error.localizedDescription)"
        }
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
                // Never keep the pairing string in memory or on screen once it has
                // served its purpose — on failure just as much as on success. A
                // failed attempt is not a reason to leave a bearer secret sitting
                // in a @Published property.
                self.pairingField = ""
                switch result {
                case .success(let record):
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

    public func quit() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        // Terminate only once the coordinator has actually torn down, rather
        // than racing its `queue.async`. Phase 2 wants to send a STOP on the way
        // out; a terminate that beats the teardown would silently skip it.
        coordinator.shutdown {
            NSApplication.shared.terminate(nil)
        }
    }
}
