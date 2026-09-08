import XCTest
@testable import ElderlyAssistant

/// Acoustic smoke tests for the wake phrase (2026-09-08): synthesize the
/// phrase with the app's own Piper voices and feed the samples into the
/// REAL sherpa KWS engine, verifying the detection chain end-to-end
/// without a microphone.
///
/// The English synthesis ("Yeah kanchhi") exercises the model's trained
/// domain — if THAT does not fire, the engine/model/keyword path is broken.
/// The Nepali synthesis ("ये कान्छी") measures the honest cross-lingual
/// gap: the GigaSpeech KWS model is English-trained, so the result is
/// recorded (printed + event) rather than asserted.
@MainActor
final class WakeWordAcousticSmokeTests: XCTestCase {

    /// WAV-file samples at 16 kHz for the engine: reads the ACTUAL header
    /// (sample rate + channels), downmixes stereo, and linearly resamples
    /// only when the source rate differs. Returns the samples + the
    /// header's rate for diagnostics.
    private static func engineSamples(from wav: URL,
                                      targetRate: Double = 16_000) throws
        -> (samples: [Int16], sourceRate: Double) {
        let data = try Data(contentsOf: wav)
        guard data.count > 44, String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              let chunkRange = Self.dataChunkRange(in: data, id: "data"),
              let fmtRange = Self.dataChunkRange(in: data, id: "fmt ") else {
            throw NSError(domain: "WakeWordAcoustic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not a readable PCM WAV"])
        }
        let fmt = data.subdata(in: fmtRange)
        let fmtInts = fmt.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            (0..<fmt.count / 2).map { buf.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self).littleEndian }
        }
        let channels = Int(fmtInts[1])
        let sourceRate = Double(fmtInts[2].littleEndian)
        guard fmtInts[0] == 1 else {
            throw NSError(domain: "WakeWordAcoustic", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "WAV is not 16-bit PCM"])
        }
        let pcm = data.subdata(in: chunkRange)
        var source: [Int16] = pcm.withUnsafeBytes { buf in
            Array(buf.bindMemory(to: Int16.self))
        }
        if channels == 2 {
            var mono: [Int16] = []
            mono.reserveCapacity(source.count / 2)
            for i in stride(from: 0, to: source.count - 1, by: 2) {
                mono.append(Int16((Int(source[i]) + Int(source[i + 1])) / 2))
            }
            source = mono
        }
        guard sourceRate == targetRate else {
            let ratio = sourceRate / targetRate
            var resampled: [Int16] = []
            resampled.reserveCapacity(Int(Double(source.count) / ratio) + 1)
            var i = 0.0
            while Int(i) < source.count - 1 {
                let lo = source[Int(i)]
                let frac = i - i.rounded(.down)
                let hi = source[min(Int(i) + 1, source.count - 1)]
                resampled.append(Int16(Double(lo) * (1 - frac) + Double(hi) * frac))
                i += ratio
            }
            return (resampled, sourceRate)
        }
        return (source, sourceRate)
    }

    private static func dataChunkRange(in data: Data, id: String) -> Range<Data.Index>? {
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(data: data.subdata(in: offset..<offset + 4), encoding: .ascii)
            let size = Int(data.subdata(in: offset + 4..<offset + 8)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            if chunkID == id { return (offset + 8)..<(offset + 8 + size) }
            offset += 8 + size + (size % 2)
        }
        return nil
    }

    private func synthesize(_ text: String, voiceID: ModelID, locale: Locale) throws -> [Int16] {
        let engine = SherpaTTSEngine()
        let dir = try XCTUnwrap(
            Bundle.main.url(forResource: ModelCatalog.entry(for: voiceID)?.filename,
                            withExtension: nil, subdirectory: "tts"),
            "bundled voice \(voiceID) missing — run tools/fetch-tts-voices.sh")
        let wav = try engine.synthesize(text, voiceDirectory: dir, speed: 1.0)
        defer { try? FileManager.default.removeItem(at: wav) }
        let parsed = try Self.engineSamples(from: wav)
        print("AUDIO-PROBE rate=\(parsed.sourceRate) samples=\(parsed.samples.count)")
        // Streaming KWS finalizes a keyword only with trailing context
        // (~320 ms blank after it). The mic stream provides this naturally;
        // the synthesized clip ends AT the keyword, so pad it.
        let pad = Int(parsed.sourceRate > 0 ? parsed.sourceRate : 16_000)
        return parsed.samples + [Int16](repeating: 0, count: pad)
    }

    private func detect(in samples: [Int16], engine: WakeWordEngine,
                        timeoutSeconds: Double = 10) async -> Bool {
        let lock = NSLock()
        var fired = false
        engine.onDetection = {
            lock.lock(); fired = true; lock.unlock()
        }
        try? engine.start()
        var fed = 0
        while fed < samples.count {
            engine.process(Array(samples[fed..<min(fed + 512, samples.count)]))
            fed += 512
            await Task.yield()
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            lock.lock(); let result = fired; lock.unlock()
            if result { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        engine.stop()
        lock.lock(); let result = fired; lock.unlock()
        return result
    }

    // MARK: - Tests

    // NOTE (2026-09-08): TTS-synthesized audio is NOT recognized by the
    // GigaSpeech-trained KWS model — verified empirically: even a
    // single-token "▁YEAH" keyword never fires on Piper TTS audio, while
    // real human recordings fire reliably. Do not use TTS audio to
    // validate wake-word behavior; use recorded human speech (the
    // archive's test_wavs are the shipped gold pairs).

    /// THE harness-validity test: the model archive ships recorded audio
    /// of its own keywords ("LIGHT UP" in 0.wav, "LOVELY CHILD" in 1.wav).
    /// If THIS does not fire through the harness, the feed/engine path is
    /// broken; if it fires, any other non-fire is acoustic, not mechanical.
    func testArchiveGoldPairFiresTheEngine() async throws {
        guard let dir = SherpaKWSModelFile.bundledDirectory() else {
            throw XCTSkip("kws model not bundled — run tools/fetch-kws-model.sh")
        }
        let files: SherpaKWSModelFiles
        switch SherpaKWSModelFiles.resolve(in: dir) {
        case .success(let resolved): files = resolved
        case .failure(let reason): throw XCTSkip("bundled model dir failed to resolve: \(reason)")
        }
        let gold = dir.appendingPathComponent("test_wavs")
        let goldKeywords = gold.appendingPathComponent("test_keywords.txt")
        guard FileManager.default.fileExists(atPath: goldKeywords.path),
              FileManager.default.fileExists(atPath: gold.appendingPathComponent("0.wav").path) else {
            throw XCTSkip("test_wavs not bundled — re-fetch from the kws-models archive")
        }
        let filesWithGoldKeywords = SherpaKWSModelFiles(
            directory: files.directory, encoder: files.encoder,
            decoder: files.decoder, joiner: files.joiner,
            tokens: files.tokens, keywords: goldKeywords)
        let engine = try SherpaKWSWakeWordEngine(files: filesWithGoldKeywords,
                                                 observabilityBus: nil)
        let samples = try Self.engineSamples(from: gold.appendingPathComponent("0.wav"))
        let fired = await detect(in: samples.samples, engine: engine)
        XCTAssertTrue(fired,
                      "the archive's own 'LIGHT UP' recording must fire the engine "
                      + "— the feed/harness path is broken otherwise")
    }

    /// The operative test for REAL speech: the keyword candidate set
    /// (keywords.txt) must be fire-able by a human recording containing
    /// the phrase — measured on-device; the shipped gold pairs are the
    /// automated stand-in until a real Nepali wake recording exists.
    ///
    /// 2026-09-08 wake-word fix: the shipped set is now DECODE-DERIVED —
    /// the romanization guesses ("▁YEAH ▁K AN CH H I" family) were proven
    /// by the user-recording probes to never fire (the GigaSpeech-English
    /// model does not hear Nepali-accented "ये कान्छी" as YEAH-K-AN-CH-I;
    /// its keyword-biased decode locks कान्छी as "GUNCI" = "▁GU N CI" on
    /// every take and take 1's full phrase as "IT CAN SEE"). The fire
    /// contract below pins the lines that measured fires on the user's
    /// own recordings (WakeWordUserRecordingProbeTests).
    func testCandidateKeywordsArePresentInShippedFile() throws {
        guard let dir = SherpaKWSModelFile.bundledDirectory() else {
            throw XCTSkip("kws model not bundled — run tools/fetch-kws-model.sh")
        }
        let keywords = try String(contentsOf: dir.appendingPathComponent("keywords.txt"),
                                  encoding: .utf8)
        let lines = keywords.split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2,
                                    "the shipped file carries the decode-derived "
                                    + "candidate set of the wake phrase")
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("▁GU N CI"),
                      "the कान्छी-syllable lock (GUNCI) must be present — "
                      + "it fired on every user take in measurement")
        XCTAssertTrue(joined.contains("▁IT ▁CAN ▁SEE"),
                      "the take-1 full-phrase lock (IT CAN SEE) must be "
                      + "present — it fired 3/3 utterances in measurement")
    }
}
