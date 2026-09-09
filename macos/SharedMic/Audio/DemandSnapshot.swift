import CoreAudio
import Foundation

public struct DemandingProcess: Equatable {
    public let pid: Int32
    public let bundleID: String
    public init(pid: Int32, bundleID: String) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

public struct DemandSnapshot: Equatable {
    public let processes: [DemandingProcess]
    public init(processes: [DemandingProcess] = []) {
        self.processes = processes
    }
    public var hasDemand: Bool { !processes.isEmpty }
    public var demandCount: Int { processes.count }
}

public enum DemandGate {
    public static func snapshot(
        blackHoleID: AudioObjectID,
        rows: [(pid: Int32, bundleID: String, inputDevices: [AudioObjectID])],
        ownPID: Int32
    ) -> DemandSnapshot {
        var holders: [DemandingProcess] = []
        for row in rows {
            if row.pid == ownPID { continue }
            if row.inputDevices.contains(blackHoleID) {
                holders.append(DemandingProcess(pid: row.pid, bundleID: row.bundleID))
            }
        }
        return DemandSnapshot(processes: holders)
    }
}
