import Foundation

/// Thin wrapper over `os_proc_available_memory()` and
/// `ProcessInfo.physicalMemory` for gating LLM size choices.
///
/// - `physicalMemoryBytes` is the device's total RAM (constant per device).
/// - `availableProcessMemoryBytes` is the app's *current* memory ceiling —
///   the OS-imposed limit before the app gets jetsam'd. This is what we
///   actually care about for deciding whether a 3 GB LLM will run.
enum MemoryProbe {

    static var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// The app's available memory ceiling in bytes. Falls back to a fraction
    /// of physical memory on older OS versions.
    static var availableProcessMemoryBytes: UInt64 {
        if #available(iOS 13.0, *) {
            let value = os_proc_available_memory()
            if value > 0 { return UInt64(value) }
        }
        // Rough heuristic: assume ~55% of physical is available to a single
        // app on iPhones with 4–8 GB RAM.
        return UInt64(Double(physicalMemoryBytes) * 0.55)
    }

    /// Whether a model with the given RAM floor is safe to load right now.
    /// Adds a 200 MB working-set headroom on top of the model's own claim.
    static func canFit(_ requiredBytes: UInt64) -> Bool {
        let headroom: UInt64 = 200_000_000
        return availableProcessMemoryBytes >= requiredBytes + headroom
    }
}
