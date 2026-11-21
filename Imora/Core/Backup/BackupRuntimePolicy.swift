import Foundation
import UIKit

nonisolated enum BackupRuntimePolicy {
    static let preparationWorkerOptions = [1, 2, 3]
    static let defaultPreparationWorkers = 2
    static let criticalThermalCooldown: TimeInterval = 3 * 60
    static let fairThermalCooldown: TimeInterval = 60

    static func preparationRequest(stored: Int?) -> Int {
        guard let stored, stored > 0 else { return defaultPreparationWorkers }
        return min(stored, 3)
    }

    static func loadPreparationRequest(from defaults: UserDefaults, key: String) -> Int {
        let stored = defaults.object(forKey: key) as? Int
        let requested = preparationRequest(stored: stored)
        if let stored, stored != requested { defaults.set(requested, forKey: key) }
        return requested
    }

    static func preparationWorkers(requested: Int, background: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Int {
        workers(requested: preparationRequest(stored: requested), background: background, lowPower: lowPower, thermal: thermal)
    }

    @MainActor
    static func currentPreparationWorkers(_ requested: Int) -> Int {
        preparationWorkers(requested: requested, background: UIApplication.shared.applicationState != .active,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }

    static func pausesWork(thermal: ProcessInfo.ThermalState) -> Bool {
        switch thermal {
        case .nominal, .fair, .serious: false
        case .critical: true
        @unknown default: true
        }
    }

    static func workers(requested: Int, background: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Int {
        if pausesWork(thermal: thermal) { return 0 }
        return background || lowPower || thermal == .fair || thermal == .serious ? 1 : max(1, requested)
    }

    static func requireThermalBudget(_ thermal: ProcessInfo.ThermalState) throws {
        if pausesWork(thermal: thermal) { throw BackupThermalHold() }
    }

    /// A critical heat event must not restart the instant iOS reports fair.
    /// Extend an existing cooldown deterministically so recovery is testable.
    static func thermalCooldownDeadline(
        current: TimeInterval,
        observedAt: TimeInterval,
        thermal: ProcessInfo.ThermalState
    ) -> TimeInterval {
        switch thermal {
        case .critical:
            max(current, observedAt + criticalThermalCooldown)
        case .fair:
            current > observedAt ? max(current, observedAt + fairThermalCooldown) : current
        default:
            current
        }
    }

    static func isCoolingDown(
        now: TimeInterval,
        deadline: TimeInterval,
        thermal: ProcessInfo.ThermalState
    ) -> Bool {
        pausesWork(thermal: thermal) || now < deadline
    }

    @MainActor
    static func currentWorkers(_ requested: Int) -> Int {
        workers(requested: requested, background: UIApplication.shared.applicationState != .active,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }
}

nonisolated struct BackupThermalHold: Error, LocalizedError {
    var errorDescription: String? {
        String(localized: "Device is too warm. Backup will resume when it cools.")
    }
}
