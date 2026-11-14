import Foundation

/// shared by preparation, backlog uploads, and the recent-capture worker.
/// overrides last for a condition episode, independently of individual runs.
nonisolated struct BackupConditions {
    var networkKnown = false
    var connected = false
    var metered = false
    var wifi = false
    var cellular = false
    var batteryPercent: Int?
    var cellularOverride = false
    var batteryOverride = false

    mutating func updateNetwork(connected: Bool, metered: Bool, wifi: Bool, cellular: Bool = false) {
        networkKnown = true
        self.connected = connected
        self.metered = connected && metered
        self.wifi = connected && wifi
        self.cellular = connected && cellular
        // a metered Wi-Fi path still has the same hold. keep a one-time
        // approval until an unmetered connection actually clears that hold.
        if connected && !metered { cellularOverride = false }
    }

    mutating func updateBattery(_ percent: Int?, threshold: Int) {
        batteryPercent = percent
        if let percent, percent > threshold { batteryOverride = false }
    }

    func heldForCellular(allowCellular: Bool) -> Bool {
        connected && metered && !allowCellular && !cellularOverride
    }

    func heldForBattery(pauseOnLowBattery: Bool, threshold: Int) -> Bool {
        pauseOnLowBattery && (batteryPercent.map { $0 <= threshold } ?? false) && !batteryOverride
    }

    func allowsWork(allowCellular: Bool, pauseOnLowBattery: Bool, threshold: Int) -> Bool {
        networkKnown && connected && !heldForCellular(allowCellular: allowCellular)
            && !heldForBattery(pauseOnLowBattery: pauseOnLowBattery, threshold: threshold)
    }

    mutating func overrideCurrentHolds(allowCellular: Bool, pauseOnLowBattery: Bool, threshold: Int) {
        if heldForCellular(allowCellular: allowCellular) { cellularOverride = true }
        if heldForBattery(pauseOnLowBattery: pauseOnLowBattery, threshold: threshold) { batteryOverride = true }
    }
}
