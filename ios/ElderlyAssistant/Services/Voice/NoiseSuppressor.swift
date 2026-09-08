import Foundation

/// The pipeline mode a denoising stage is currently serving. The research
/// doc (docs/research-sections/noise-filter.md, P1 step 3) prescribes
/// per-state presets: mild suppression while wake-listening, full during
/// capture. In this phase only capture audio is processed at all — the
/// idle/wake path stays raw until a wake-FRR measurement exists (doc open
/// question 7) — but the mode enum is part of the stage contract now so
/// the stronger presets can engage without a protocol change.
enum NoiseSuppressorMode: Equatable {
    /// Pipeline is `.idle`, listening for the wake word. Mild preset.
    case idleListening
    /// Pipeline is `.capturingCommand` (VAD + STT consuming audio). Full preset.
    case capturing
}

/// Denoising stage for the voice pipeline's shared 16 kHz int16 mono
/// capture stream — the front-end of the noise-filter research
/// (docs/research-sections/noise-filter.md, P1 step 1).
///
/// Contract:
///  - Applied at the single choke point, `VoicePipeline.feedCapture` —
///    AFTER the 48 kHz → 16 kHz int16 conversion, BEFORE the fan-out to
///    the endpointing VAD and the STT push. Exactly once per sample; the
///    recognizers are never rewritten for this stage.
///  - `process(_:)` is a STREAMING stage with an internal frame buffer:
///    the per-call output length may differ from the input length by up
///    to `latencySamples` (a chunk's tail stays buffered until its frame
///    completes). Cumulative contract: after A input samples the stage has
///    emitted between A − latency − hop and A samples, every sample
///    emitted exactly once and in order, and the emitted stream is the
///    input delayed by `latencySamples` after the passthrough warmup
///    prefix (the first `latencySamples` samples pass through raw — the
///    stage cannot have processed them yet). A uniform delay of the whole
///    utterance, not just the tail (the doc's latency rationale).
///    Callers buffer/slice frames downstream anyway (the pipeline does —
///    VAD frame accumulator, per-chunk STT buffer), so per-call length
///    variation is harmless; the stream is what matters.
///  - Thread-confined: the pipeline calls `process` on its processing
///    queue; `reset`/`setMode`/`captureStarted`/`captureEnded` may arrive
///    from the main queue — implementations must synchronize internally.
///  - Honest by construction: `name` never claims a model is running
///    unless one is, and every observability event says what the stage
///    actually is.
protocol NoiseSuppressor: AnyObject {
    /// Sample rate the stage operates at (the pipeline's converted
    /// format — 16 kHz today).
    var requiredSampleRate: Double { get }

    /// Honest engine name for observability ("null", "spectral_gate").
    /// Deliberately not called a neural denoiser: the current stage is a
    /// classic DSP spectral gate; a DeepFilterNet3-class model would be a
    /// different implementation of this protocol with its own name.
    var name: String { get }

    /// Constant algorithmic delay in samples at `requiredSampleRate`.
    /// 0 for a null/identity stage.
    var latencySamples: Int { get }

    /// Streaming denoise: frames in → frames out. Per-call output length
    /// may differ from input by up to `latencySamples` (see the protocol
    /// doc); the emitted stream is the input uniformly delayed by
    /// `latencySamples` after the warmup prefix, nothing dropped.
    func process(_ samples: [Int16]) -> [Int16]

    /// Capture boundary: clears streaming state (overlap tail, warmup,
    /// frame counters). Learned noise estimates may persist across
    /// captures — room calibration, mirroring EnergyVAD's `noiseFloor`.
    func reset()

    /// Pipeline mode transition (idle ↔ capture).
    func setMode(_ mode: NoiseSuppressorMode)

    /// Per-utterance observability bookends: implementations accumulate
    /// input/output RMS between these and emit ONE per-utterance event at
    /// `captureEnded` (doc §5 telemetry). Must be idempotent: a second
    /// `captureEnded` without an intervening `captureStarted` emits nothing.
    func captureStarted()
    func captureEnded()
}

extension NoiseSuppressor {
    func reset() {}
    func setMode(_ mode: NoiseSuppressorMode) {}
    func captureStarted() {}
    func captureEnded() {}
}

/// No-op stage — what the pipeline runs when the noise filter is OFF
/// (today's default). Byte-identical legacy behavior: zero latency, zero
/// cost, and the observability name says exactly what it is.
final class NullNoiseSuppressor: NoiseSuppressor {
    let requiredSampleRate: Double = 16_000
    let name = "null"
    let latencySamples = 0

    func process(_ samples: [Int16]) -> [Int16] {
        samples
    }
}
