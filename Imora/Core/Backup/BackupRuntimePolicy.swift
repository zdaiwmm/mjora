import Foundation
import UIKit

nonisolated enum BackupRuntimePolicy {
    static let preparationWorkerOptions = [1, 2, 3]
    static let defaultPreparationWorkers = 2

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
        case .nominal, .fair: false
        case .serious, .critical: true
        @unknown default: true
        }
    }

    static func workers(requested: Int, background: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Int {
        if pausesWork(thermal: thermal) { return 0 }
        return background || lowPower || thermal == .fair ? 1 : max(1, requested)
    }

    static func requireThermalBudget(_ thermal: ProcessInfo.ThermalState) throws {
        if pausesWork(thermal: thermal) { throw BackupThermalHold() }
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
