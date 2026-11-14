import Darwin
import Foundation
import UIKit

/// A snapshot of this process and its app-support volume only. The diagnostics
/// writer invokes it at lifecycle events or a coalesced progress checkpoint.
@MainActor
enum BackgroundRuntimeResources {
    static func capture() -> BackgroundTaskDiagnostics.Environment {
        let process = ProcessInfo.processInfo
        let thermal: BackgroundTaskDiagnostics.ThermalState
        switch process.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }
        let volume = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let disk = try? volume?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return BackgroundTaskDiagnostics.Environment(lowPowerMode: process.isLowPowerModeEnabled,
            thermalState: thermal, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            residentMemoryBytes: residentMemoryBytes(), availableMemoryBytes: availableMemoryBytes(),
            availableDiskBytes: disk?.volumeAvailableCapacityForImportantUsage,
            processIdentifier: process.processIdentifier)
    }

    private static func residentMemoryBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(exactly: info.resident_size)
    }

    private static func availableMemoryBytes() -> Int64? {
        #if os(iOS) || os(tvOS) || os(watchOS)
        // This is process-limit headroom, not device-wide free memory.
        return Int64(exactly: os_proc_available_memory())
        #else
        return nil
        #endif
    }
}
