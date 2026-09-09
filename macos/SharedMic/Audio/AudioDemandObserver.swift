import CoreAudio
import Foundation

public final class AudioDemandObserver {
    private struct CachedRow {
        var bundleID: String
        var devices: [AudioObjectID]
    }

    private let query: CoreAudioQuery
    private let pollInterval: TimeInterval
    private let fullRescanInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.sharedmic.demand")
    private var onChange: ((DemandSnapshot) -> Void)?

    private var blackHoleID: AudioObjectID?
    private var watchedObjects: Set<AudioObjectID> = []
    private var refusedObjects: Set<AudioObjectID> = []
    private var fallbackPIDs: Set<Int32> = []
    private var cached: [Int32: CachedRow] = [:]
    private var fallbackTimer: DispatchSourceTimer?
    private var fullPollTimer: DispatchSourceTimer?
    private var running = false
    private var _current = DemandSnapshot()

    public var current: DemandSnapshot { queue.sync { _current } }

    public init(query: CoreAudioQuery, pollInterval: TimeInterval = 0.1, fullRescanInterval: TimeInterval = 1.0, onChange: ((DemandSnapshot) -> Void)? = nil) {
        self.query = query
        self.pollInterval = pollInterval
        self.fullRescanInterval = fullRescanInterval
        self.onChange = onChange
    }

    public func setOnChange(_ handler: ((DemandSnapshot) -> Void)?) {
        queue.async { [weak self] in self?.onChange = handler }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            if self.query.addProcessListListener({ [weak self] in self?.processListChanged() }) {
                self.fullRescan()
            } else {
                self.fullRescan()
                self.startFullPolling()
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.fallbackTimer?.cancel(); self.fallbackTimer = nil
            self.fullPollTimer?.cancel(); self.fullPollTimer = nil
            self.watchedObjects.removeAll()
            self.refusedObjects.removeAll()
            self.fallbackPIDs.removeAll()
            self.query.removeAllListeners()
        }
    }

    public func rescanNow() {
        queue.async { [weak self] in self?.fullRescan() }
    }

    private func processListChanged() {
        queue.async { [weak self] in self?.fullRescan() }
    }

    private func deviceChanged() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.rereadRows()
            self.publishIfChanged()
        }
    }

    private func rereadRows() {
        for object in watchedObjects {
            guard let pid = query.pid(for: object) else { continue }
            cached[pid] = CachedRow(bundleID: query.bundleID(for: object),
                                    devices: query.inputDeviceIDs(for: object))
        }
        readAllRows()
    }

    private func fullRescan() {
        guard running else { return }
        blackHoleID = query.resolveBlackHole()
        let objects = query.processObjectIDs()
        let fresh = Set(objects)
        for gone in watchedObjects.subtracting(fresh) {
            query.removeDeviceListener(processObject: gone)
            refusedObjects.remove(gone)
        }
        let arrived = fresh.subtracting(watchedObjects)
        watchedObjects = fresh
        for object in arrived {
            if query.addDeviceListener(processObject: object, block: { [weak self] in self?.deviceChanged() }) {
                refusedObjects.remove(object)
            } else {
                refusedObjects.insert(object)
            }
        }
        cached.removeAll()
        fallbackPIDs.removeAll()
        for object in objects {
            guard let pid = query.pid(for: object) else { continue }
            let bundle = query.bundleID(for: object)
            let devices = query.inputDeviceIDs(for: object)
            cached[pid] = CachedRow(bundleID: bundle, devices: devices)
            if refusedObjects.contains(object) {
                fallbackPIDs.insert(pid)
            }
        }
        updateFallbackTimer()
        readAllRows()
        publishIfChanged()
    }

    private func readAllRows() {
        for pid in fallbackPIDs {
            guard let object = query.processObject(forPID: pid) else { continue }
            cached[pid] = CachedRow(bundleID: query.bundleID(for: object),
                                    devices: query.inputDeviceIDs(for: object))
        }
    }

    private func publishIfChanged() {
        guard let target = blackHoleID else {
            publish(DemandSnapshot())
            return
        }
        let rows = cached.map { (pid: $0.key, bundleID: $0.value.bundleID, inputDevices: $0.value.devices) }
        publish(DemandGate.snapshot(blackHoleID: target, rows: rows, ownPID: query.ownPID))
    }

    private func publish(_ snapshot: DemandSnapshot) {
        guard snapshot != _current else { return }
        _current = snapshot
        if let onChange { onChange(snapshot) }
    }

    private func updateFallbackTimer() {
        fallbackTimer?.cancel(); fallbackTimer = nil
        guard !fallbackPIDs.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.readAllRows()
            self.publishIfChanged()
        }
        timer.resume()
        fallbackTimer = timer
    }

    private func startFullPolling() {
        fullPollTimer?.cancel(); fullPollTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + fullRescanInterval, repeating: fullRescanInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.fullRescan()
        }
        timer.resume()
        fullPollTimer = timer
    }
}
