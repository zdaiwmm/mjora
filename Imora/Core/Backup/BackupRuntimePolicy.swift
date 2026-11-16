import Foundation
import UIKit

nonisolated enum BackupRuntimePolicy {
    static func workers(requested: Int, background: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Int {
        if thermal == .critical { return 0 }
        return background || lowPower || thermal == .serious ? 1 : max(1, requested)
    }

    @MainActor
    static func currentWorkers(_ requested: Int) -> Int {
        workers(requested: requested, background: UIApplication.shared.applicationState != .active,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }
}
