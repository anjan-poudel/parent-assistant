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

    /// Whether the DEVICE can hold a model with the given RAM floor.
    /// Catalog `minDeviceRAMBytes` values are physical-device claims (an
    /// iPhone 12 has ~4 GB, a 14 Pro Max ~6 GB). `os_proc_available_memory`
    /// — the app's *current* ceiling, typically 1–3 GB on iOS — is the
    /// wrong comparator here: it rejected every model over ~2 GB on every
    /// device ("device does not have enough memory" on a 14 Pro Max).
    /// Runtime spikes are handled by whisper.cpp's mmap + OS paging.
    static func canFit(_ requiredBytes: UInt64) -> Bool {
        physicalMemoryBytes >= requiredBytes
    }
}
