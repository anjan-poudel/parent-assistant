import Foundation
import Darwin

/// Thin wrapper over `os_proc_available_memory()`, `task_info(TASK_VM_INFO)`
/// and `ProcessInfo.physicalMemory` for gating LLM size choices.
///
/// - `physicalMemoryBytes` is the device's total RAM (constant per device).
/// - `availableProcessMemoryBytes` is the app's *current* memory ceiling —
///   the OS-imposed limit before the app gets jetsam'd. This is what we
///   actually care about for deciding whether a 3 GB LLM will run.
/// - `physFootprintBytes` is what the app is *actually* holding right now —
///   the same number jetsam and the CPU resource watchdog report. It is the
///   other half of that pair: the ceiling says how much room there is, the
///   footprint says how much of it is already spent. Until this existed the
///   app could only *infer* its own residency (the ledger's arithmetic) and
///   never observe it; a field capture carrying `phys_footprint` next to
///   `ceiling_bytes` is what turns `peak_footprint(t)` from a model into a
///   measurement
///   (`docs/superpowers/specs/2026-09-18-model-memory-manager-proposal.md`
///   §3.1, §6.3).
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

    /// The app's own resident footprint — `phys_footprint` out of
    /// `task_info(TASK_VM_INFO)`, the number the kernel charges us for.
    ///
    /// Not derivable from the other two readings. `availableProcessMemory-
    /// Bytes` is `ceiling − footprint`, so subtracting it from a *guessed*
    /// ceiling gives a footprint that is only as good as the guess — and the
    /// ceiling is exactly the thing iOS does not let an app read. This is
    /// the direct measurement.
    ///
    /// It counts what the ledger cannot: `phys_footprint` includes the
    /// camera/Vision working set, the audio graph, the Swift runtime and
    /// every `mmap`'d page currently *resident*, which is why it can read
    /// higher than the sum of the catalog sizes and lower than it after the
    /// kernel reclaims pageable GGUF weights. Both readings are useful and
    /// neither is an error.
    ///
    /// Returns 0 when the call fails (a sandbox restriction or an
    /// unexpected ABI shape). Zero is the honest "not measured" value here:
    /// a caller that gates on a footprint must never read a failed probe as
    /// "the app holds nothing".
    static var physFootprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self,
                                      capacity: Int(count)) { rebound in
                task_info(mach_task_self_,
                          task_flavor_t(TASK_VM_INFO),
                          rebound,
                          &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
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
