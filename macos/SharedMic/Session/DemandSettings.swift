import Foundation

/// Phase 3 persisted settings (spec §5.2–§5.4).
///
/// Only the kill switch and the tunables persist. Whether a hold is active
/// never persists: a relaunch always starts unheld, so a forgotten hold can
/// never become an always-on hot microphone.
public struct DemandSettings: Equatable {
    public static let defaultStopDebounceMs = 1000
    public static let minStopDebounceMs = 500
    public static let maxStopDebounceMs = 2000
    public static let defaultHoldSeconds: TimeInterval = 1800

    /// Kill switch (spec §5.3). While true the machine boots into `.disabled`
    /// and no START is ever sent.
    public var disabled: Bool
    /// Stop debounce in milliseconds, clamped to 500–2000 (spec §5.2).
    public var stopDebounceMs: Int
    /// Force-on hold duration in seconds (spec §5.4). Expiry is mandatory;
    /// only the duration is tunable.
    public var holdSeconds: TimeInterval

    public init(disabled: Bool = false,
                stopDebounceMs: Int = DemandSettings.defaultStopDebounceMs,
                holdSeconds: TimeInterval = DemandSettings.defaultHoldSeconds) {
        self.disabled = disabled
        self.stopDebounceMs = Self.clampDebounceMs(stopDebounceMs)
        self.holdSeconds = max(holdSeconds, 60)
    }

    public static func clampDebounceMs(_ ms: Int) -> Int {
        min(max(ms, minStopDebounceMs), maxStopDebounceMs)
    }
}

public protocol DemandSettingsStore {
    func load() -> DemandSettings
    func save(_ settings: DemandSettings)
}

public final class InMemoryDemandSettingsStore: DemandSettingsStore {
    private var settings: DemandSettings
    public init(_ settings: DemandSettings = DemandSettings()) {
        self.settings = settings
    }
    public func load() -> DemandSettings { settings }
    public func save(_ settings: DemandSettings) { self.settings = settings }
}

public final class UserDefaultsDemandSettingsStore: DemandSettingsStore {
    private static let disabledKey = "com.sharedmic.demand.disabled"
    private static let debounceMsKey = "com.sharedmic.demand.stopDebounceMs"
    private static let holdSecondsKey = "com.sharedmic.demand.holdSeconds"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> DemandSettings {
        let debounce = defaults.object(forKey: Self.debounceMsKey) as? Int
        let hold = defaults.object(forKey: Self.holdSecondsKey) as? Double
        return DemandSettings(
            disabled: defaults.bool(forKey: Self.disabledKey),
            stopDebounceMs: debounce ?? DemandSettings.defaultStopDebounceMs,
            holdSeconds: hold ?? DemandSettings.defaultHoldSeconds
        )
    }

    public func save(_ settings: DemandSettings) {
        defaults.set(settings.disabled, forKey: Self.disabledKey)
        defaults.set(settings.stopDebounceMs, forKey: Self.debounceMsKey)
        defaults.set(settings.holdSeconds, forKey: Self.holdSecondsKey)
    }
}
