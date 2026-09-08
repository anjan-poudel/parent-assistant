import XCTest
#if canImport(SherpaOnnx)
import SherpaOnnx
#endif
@testable import ElderlyAssistant

/// Evidence harness for the 2026-09-08 wake-word fix: feeds the user's
/// three real "ये कान्छी" recordings through the ACTUAL sherpa GigaSpeech
/// model (the same files the KWS engine loads) and prints the ground
/// truth:
///
///   1. TRANSCRIPT — the model run as a plain streaming ASR recognizer
///      (identical encoder/decoder/joiner + tokens.txt), showing exactly
///      which English tokens the user's Nepali phrase decodes to. (Run 5
///      proved a drain-only recognizer returns '' even on audio the
///      engine fires — text must be collected at every decode.)
///   2. SHIPPED-FILE — the engine path (SherpaKWSWakeWordEngine +
///      keywords.txt as fetched): did onDetection fire?
///   3. SPOTTER-MATCHES — a direct spotter drain over the same keywords
///      file, printing WHICH candidate line matched (the engine hides the
///      text by design).
///
/// The later test methods are the measurement trail that produced the
/// fix: gold-pair control (proves feed/engine/recognizer machinery on
/// known English speech), whole-vocab reveal (which tokens the model
/// hears at all), ASR transcripts (interior decode), and the
/// decode-derived candidate matrix + timing that selected the shipped
/// keywords (see tools/fetch-kws-model.sh). Every probe prints and never
/// asserts — the verdicts are read from the log. Skipped when the model
/// dir, test_wavs, or the recordings are not bundled (user recordings
/// are gitignored, next to the model).
@MainActor
final class WakeWordUserRecordingProbeTests: XCTestCase {

    /// One full second of silence — the streaming KWS finalizes a keyword
    /// only after ~1 trailing blank (320 ms), which the mic stream provides
    /// naturally but a clip that ends AT the keyword does not.
    private static let padSamples = 16_000

    // MARK: - WAV plumbing (header-aware, same approach as the acoustic harness)

    private static func wavSamples(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44,
              String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              let dataRange = chunkRange(in: data, id: "data"),
              let fmtRange = chunkRange(in: data, id: "fmt ") else {
            throw NSError(domain: "WakeWordProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not a readable PCM WAV"])
        }
        let fmt = data.subdata(in: fmtRange)
        let fmtInts = fmt.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            (0..<fmt.count / 2).map { buf.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self).littleEndian }
        }
        let channels = Int(fmtInts[1])
        let rate = Double(fmtInts[2].littleEndian)
        // Accept classic PCM (tag 1) and WAVE_FORMAT_EXTENSIBLE wrapping
        // PCM (tag 0xFFFE with subformat-GUID first word == 1) — the
        // user recordings were converted by afconvert, which writes the
        // extensible container.
        let isPCM = fmtInts[0] == 1
            || (fmtInts[0] == 0xFFFE && fmtInts.count > 12 && fmtInts[12] == 1)
        guard isPCM else {
            throw NSError(domain: "WakeWordProbe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "WAV is not 16-bit PCM"])
        }
        let pcm = data.subdata(in: dataRange)
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
        guard rate == 16_000 else {
            throw NSError(domain: "WakeWordProbe", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "expected 16 kHz, got \(rate)"])
        }
        return source.map { Float($0) / 32_768.0 }
    }

    private static func chunkRange(in data: Data, id: String) -> Range<Data.Index>? {
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

    // MARK: - Model/config builders (values mirror SherpaKWSWakeWordEngine.makeSpotter)

    private static func bundledModelDir() -> URL? {
        guard let dir = SherpaKWSModelFile.bundledDirectory() else { return nil }
        switch SherpaKWSModelFiles.resolve(in: dir) {
        case .success: return dir
        case .failure: return nil
        }
    }

    /// NOTE: the sherpa C-struct types (SherpaOnnxOnlineModelConfig etc.)
    /// are clang-imported from the SherpaOnnxC module and are NOT re-exported
    /// by the Swift wrapper module — the app target compiles by never NAMING
    /// them (only the builder functions). The probe follows the same rule:
    /// no C type name in any signature, only local `var config` inference.
    private func makeSpotter(files: SherpaKWSModelFiles,
                             keywordsFileName: String,
                             keywordsThreshold: Float = 0.25) -> SherpaOnnxKeywordSpotterWrapper? {
        let keywordsURL = files.directory.appendingPathComponent(keywordsFileName)
        guard FileManager.default.fileExists(atPath: keywordsURL.path) else { return nil }
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: files.encoder.path,
            decoder: files.decoder.path,
            joiner: files.joiner.path
        )
        let model = sherpaOnnxOnlineModelConfig(
            tokens: files.tokens.path,
            transducer: transducer,
            numThreads: 1,
            provider: "cpu",
            debug: 0,
            modelType: "",
            modelingUnit: "bpe"
        )
        let features = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxKeywordSpotterConfig(
            featConfig: features,
            modelConfig: model,
            keywordsFile: keywordsURL.path,
            maxActivePaths: 4,
            numTrailingBlanks: 1,
            keywordsScore: 1.0,
            keywordsThreshold: keywordsThreshold
        )
        return SherpaOnnxKeywordSpotterWrapper(config: &config)
    }

    // MARK: - Transcribe: run the model as plain ASR to reveal the decode

    private func transcribe(_ samples: [Float]) -> String {
        #if canImport(SherpaOnnx)
        guard let dir = Self.bundledModelDir(),
              case .success(let files) = SherpaKWSModelFiles.resolve(in: dir) else {
            return "<model unavailable>"
        }
        let features = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: files.encoder.path,
            decoder: files.decoder.path,
            joiner: files.joiner.path
        )
        // NOTE: the recognizer's model-config Validate requires
        // bpe_vocab (bpe.model) whenever modelingUnit == "bpe"
        // (online-model-config.cc:166) — the KWS spotter skips that check,
        // the ASR recognizer does not.
        let bpeVocab = files.directory.appendingPathComponent("bpe.model").path
        let model = sherpaOnnxOnlineModelConfig(
            tokens: files.tokens.path,
            transducer: transducer,
            numThreads: 1,
            provider: "cpu",
            debug: 0,
            modelType: "",
            modelingUnit: "bpe",
            bpeVocab: bpeVocab
        )
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: features,
            modelConfig: model,
            enableEndpoint: false,
            decodingMethod: "greedy_search",
            maxActivePaths: 4
        )
        let recognizer = SherpaOnnxRecognizer(config: &config)
        // Chunked feed like a mic stream. Text is collected at EVERY decode
        // (during the feed AND the post-inputFinished drain) — run 5 showed
        // the drain-only version returned '' even on audio the KWS engine
        // demonstrably decodes (gold 0.wav), so any accumulation is kept.
        var transcript = ""
        func collect() {
            let text = recognizer.getResult().text
            if text.count > transcript.count { transcript = text }
        }
        let feed = samples + [Float](repeating: 0, count: Self.padSamples)
        var offset = 0
        while offset < feed.count {
            let end = min(offset + 512, feed.count)
            recognizer.acceptWaveform(samples: Array(feed[offset..<end]))
            offset = end
            if recognizer.isReady() {
                recognizer.decode()
                collect()
            }
        }
        // NOTE: sherpa's features.cc CHECK aborts the process if decode()
        // is called when the stream is NOT ready (GetFrames overrun on the
        // final partial chunk) — only decode while isReady(), never force.
        recognizer.inputFinished()
        while recognizer.isReady() {
            recognizer.decode()
            collect()
        }
        return transcript
        #else
        return "<sherpa not linked>"
        #endif
    }

    // MARK: - Engine-path detection (SherpaKWSWakeWordEngine.process, real keywords file)

    private func engineDetects(files: SherpaKWSModelFiles,
                               samples: [Float],
                               keywordsFile: String? = nil,
                               timeoutSeconds: TimeInterval = 10) async -> Bool {
        var engineFiles = files
        if let keywordsFile {
            engineFiles = SherpaKWSModelFiles(
                directory: files.directory, encoder: files.encoder,
                decoder: files.decoder, joiner: files.joiner,
                tokens: files.tokens,
                keywords: files.directory.appendingPathComponent(keywordsFile))
        }
        guard let engine = try? SherpaKWSWakeWordEngine(files: engineFiles,
                                                        observabilityBus: nil) else {
            return false
        }
        let lock = NSLock()
        var fired = false
        engine.onDetection = {
            lock.lock(); fired = true; lock.unlock()
        }
        try? engine.start()
        let feed = samples.map { Int16($0 * 32_767) }
            + [Int16](repeating: 0, count: Self.padSamples)
        var fed = 0
        while fed < feed.count {
            engine.process(Array(feed[fed..<min(fed + 512, feed.count)]))
            fed += 512
            await Task.yield()
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            lock.lock(); let hit = fired; lock.unlock()
            if hit { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return fired
    }

    // MARK: - Direct spotter drain (prints WHICH keywords matched)

    private func spotterMatches(spotter: SherpaOnnxKeywordSpotterWrapper?,
                                samples: [Float]) -> [String] {
        guard let spotter else { return ["<spotter init failed>"] }
        var matches: [String] = []
        let feed = samples + [Float](repeating: 0, count: Self.padSamples)
        var offset = 0
        while offset < feed.count {
            let end = min(offset + 512, feed.count)
            spotter.acceptWaveform(samples: Array(feed[offset..<end]), sampleRate: 16_000)
            offset = end
            while spotter.isReady() {
                spotter.decode()
                let result = spotter.getResult()
                if !result.keyword.isEmpty {
                    matches.append(result.keyword)
                    spotter.reset()
                }
            }
        }
        spotter.inputFinished()
        while spotter.isReady() {
            spotter.decode()
            let result = spotter.getResult()
            if !result.keyword.isEmpty {
                matches.append(result.keyword)
                spotter.reset()
            }
        }
        return matches
    }

    // MARK: - The probes (one per user recording)

    private func probeRecording(named name: String, label: String) async throws {
        guard let dir = Self.bundledModelDir() else {
            throw XCTSkip("kws model not bundled — run tools/fetch-kws-model.sh")
        }
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) not bundled next to the model — cannot probe")
        }
        guard case .success(let files) = SherpaKWSModelFiles.resolve(in: dir) else {
            throw XCTSkip("bundled model dir failed to resolve")
        }
        let samples = try Self.wavSamples(from: url)
        let keywordsText = try String(contentsOf: files.keywords, encoding: .utf8)
            .split(separator: "\n")
        print("PROBE-\(label) wav=\(name) samples=\(samples.count) "
              + "keywords-lines=\(keywordsText.count)")
        print("PROBE-\(label) shipped keywords=\(keywordsText)")

        let transcript = transcribe(samples)
        print("PROBE-\(label) TRANSCRIPT='\(transcript)'")

        let fired = await engineDetects(files: files, samples: samples)
        print("PROBE-\(label) ENGINE-FIRED=\(fired)")

        let matches = spotterMatches(spotter: makeSpotter(files: files,
                                                          keywordsFileName: "keywords.txt"),
                                     samples: samples)
        print("PROBE-\(label) SHIPPED-MATCHES=\(matches)")
    }

    func testProbeUserRecording1() async throws {
        try await probeRecording(named: "user_recording.wav", label: "1")
    }

    func testProbeUserRecording2() async throws {
        try await probeRecording(named: "user_recording2.wav", label: "2")
    }

    func testProbeUserRecording3() async throws {
        try await probeRecording(named: "user_recording3.wav", label: "3")
    }

    // MARK: - Controls (2026-09-08 run 6)

    /// Controls after run 5 proved the ENGINE path is sound (gold 0.wav
    /// fired) while the recognizer-drain was silently empty. Run 6:
    ///
    ///   1. GOLD: 0.wav through the recognizer again (fixed collection) and
    ///      through the engine with the archive's own test_keywords.txt.
    ///   2. GAIN: the user recordings through the ENGINE at 1x and 4x —
    ///      correct labels this time (run 5's tie-break printed x1 twice).
    ///   3. REVEAL: one keyword per vocab token (whole tokens.txt, minus
    ///      <blk>/<sos/eos>/<unk>) through the SPOTTER at a permissive
    ///      threshold (0.1). Whatever fires tells us exactly which English
    ///      tokens the GigaSpeech model hears in the user's Nepali phrase —
    ///      the ground truth the shipped candidate set must match.
    func testGoldControlAndGainSweepDiagnostics() async throws {
        guard let dir = Self.bundledModelDir() else {
            throw XCTSkip("kws model not bundled — run tools/fetch-kws-model.sh")
        }
        guard case .success(let files) = SherpaKWSModelFiles.resolve(in: dir) else {
            throw XCTSkip("bundled model dir failed to resolve")
        }
        let goldDir = dir.appendingPathComponent("test_wavs")
        let gold0 = goldDir.appendingPathComponent("0.wav")
        let hasGold = FileManager.default.fileExists(atPath: gold0.path)
            && FileManager.default.fileExists(
                atPath: goldDir.appendingPathComponent("test_keywords.txt").path)

        // --- Gold control: known English human speech ---------------------
        if hasGold {
            let gold = try Self.wavSamples(from: gold0)
            let goldPeak = gold.map { abs($0) }.max() ?? 0
            print("GOLD wav=0.wav samples=\(gold.count) peak=\(goldPeak)")
            print("GOLD TRANSCRIPT='\(transcribe(gold))'")
            let goldFired = await engineDetects(files: files, samples: gold,
                                                keywordsFile: "test_wavs/test_keywords.txt")
            print("GOLD ENGINE-FIRED=\(goldFired) (keywords=test_keywords.txt)")
        } else {
            print("GOLD SKIPPED — test_wavs not bundled")
        }

        func boosted(_ base: [Float], by gain: Int) -> [Float] {
            base.map { max(-0.98, min(0.98, $0 * Float(gain))) }
        }

        // --- Whole-vocab reveal: what does the model HEAR? ---------------
        do {
            let tokensText = try String(contentsOf: files.tokens, encoding: .utf8)
            var reveal: [String] = []
            for line in tokensText.split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count >= 2, let id = Int(fields[1]) else { continue }
                if id <= 2 { continue } // <blk>, <sos/eos>, <unk>
                reveal.append(String(fields[0]))
            }
            print("REVEAL vocab-keywords=\(reveal.count)")
            let revealURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kws-reveal-\(UUID().uuidString).txt")
            try reveal.joined(separator: "\n").write(to: revealURL,
                                                     atomically: true,
                                                     encoding: .utf8)
            let revealFiles = SherpaKWSModelFiles(
                directory: FileManager.default.temporaryDirectory,
                encoder: files.encoder, decoder: files.decoder,
                joiner: files.joiner, tokens: files.tokens,
                keywords: revealURL)
            for (name, label) in [("user_recording.wav", "1"),
                                  ("user_recording2.wav", "2"),
                                  ("user_recording3.wav", "3")] {
                let url = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let base = try Self.wavSamples(from: url)
                for gain in [1, 4] {
                    guard let spotter = makeSpotter(files: revealFiles,
                                                    keywordsFileName: revealURL.lastPathComponent,
                                                    keywordsThreshold: 0.1) else {
                        print("REVEAL-\(label) x\(gain) SPOTTER-INIT-FAILED")
                        continue
                    }
                    let fired = spotterMatches(spotter: spotter,
                                               samples: boosted(base, by: gain))
                    print("REVEAL-\(label) x\(gain) FIRED-TOKENS=\(fired)")
                }
            }
        } catch {
            print("REVEAL FAILED: \(error)")
        }

        // --- ASR transcripts of the user recordings -----------------------
        // The reveal only catches utterance-final tokens (trailing-blank
        // requirement), so the model's INTERIOR decode of the phrase is
        // invisible to it. The recognizer drains full continuous speech —
        // whatever words come out ARE the tokens the KWS graph would see.
        for (name, label) in [("user_recording.wav", "1"),
                              ("user_recording2.wav", "2"),
                              ("user_recording3.wav", "3")] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let base = try Self.wavSamples(from: url)
            for gain in [1, 4] {
                let text = transcribe(boosted(base, by: gain))
                print("ASR-\(label) x\(gain) TRANSCRIPT='\(text)'")
            }
        }

        // --- Engine gain sweep on the user recordings ---------------------
        for (name, label) in [("user_recording.wav", "1"),
                              ("user_recording2.wav", "2"),
                              ("user_recording3.wav", "3")] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("GAIN-\(label) \(name) MISSING — skipped")
                continue
            }
            let base = try Self.wavSamples(from: url)
            let peak = base.map { abs($0) }.max() ?? 0
            print("GAIN-\(label) wav=\(name) samples=\(base.count) peak=\(peak)")
            let fired1x = await engineDetects(files: files, samples: base,
                                              timeoutSeconds: 4)
            print("GAIN-\(label) x1 ENGINE-FIRED=\(fired1x)")
            let fired4x = await engineDetects(files: files,
                                              samples: boosted(base, by: 4),
                                              timeoutSeconds: 4)
            print("GAIN-\(label) x4 ENGINE-FIRED=\(fired4x)")
        }
    }

    // MARK: - Candidate timing + threshold robustness (2026-09-08 run 9)

    /// GUNCI fired on every take in run 8 — but WHERE in the clip? A fire
    /// aligned with each phrase utterance is a true detection; a fire in
    /// the silent gaps would be noise. This drain prints the sample offset
    /// of every fire, and re-checks the winning candidates at the product
    /// threshold (0.25) and a stricter 0.30 to measure margin.
    func testCandidateTimingAndThresholdRobustness() async throws {
        guard let dir = Self.bundledModelDir() else {
            throw XCTSkip("kws model not bundled — run tools/fetch-kws-model.sh")
        }
        guard case .success(let files) = SherpaKWSModelFiles.resolve(in: dir) else {
            throw XCTSkip("bundled model dir failed to resolve")
        }
        let candidates = [
            "▁GU N CI",
            "▁IT ▁CAN ▁SEE",
            "▁A ▁GU N CI",
        ]
        let matrixURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kws-timing-\(UUID().uuidString).txt")
        try candidates.joined(separator: "\n").write(to: matrixURL,
                                                     atomically: true,
                                                     encoding: .utf8)
        let matrixFiles = SherpaKWSModelFiles(
            directory: FileManager.default.temporaryDirectory,
            encoder: files.encoder, decoder: files.decoder,
            joiner: files.joiner, tokens: files.tokens,
            keywords: matrixURL)

        for threshold in [Float(0.25), Float(0.30)] {
            guard let spotter = makeSpotter(files: matrixFiles,
                                            keywordsFileName: matrixURL.lastPathComponent,
                                            keywordsThreshold: threshold) else {
                throw XCTSkip("spotter init failed")
            }
            for (name, label) in [("user_recording.wav", "1"),
                                  ("user_recording2.wav", "2"),
                                  ("user_recording3.wav", "3")] {
                let url = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let samples = try Self.wavSamples(from: url)
                // Timed drain: record the sample offset of every fire.
                let feed = samples + [Float](repeating: 0, count: Self.padSamples)
                var offset = 0
                var fires: [String] = []
                while offset < feed.count {
                    let end = min(offset + 512, feed.count)
                    spotter.acceptWaveform(samples: Array(feed[offset..<end]),
                                           sampleRate: 16_000)
                    offset = end
                    while spotter.isReady() {
                        spotter.decode()
                        let result = spotter.getResult()
                        if !result.keyword.isEmpty {
                            fires.append("\(result.keyword)@\(offset)ms")
                            spotter.reset()
                        }
                    }
                }
                spotter.inputFinished()
                while spotter.isReady() {
                    spotter.decode()
                    let result = spotter.getResult()
                    if !result.keyword.isEmpty {
                        fires.append("\(result.keyword)@\(offset)ms")
                        spotter.reset()
                    }
                }
                print("TIMING-\(label) thr=\(threshold) fires=\(fires)")
            }
        }
    }

    // MARK: - Decode-derived candidate matrix (2026-09-08 run 8)

    /// Run 7's ASR transcripts revealed what the model actually hears in the
    /// user's "ये कान्छी" takes: rec1 → "IT CAN SEE", rec2 → "A GUNCI A
    /// COUNTY", rec3 → "CANCEANSY KANTI". Those decode-derived phrases,
    /// bpe-tokenized, are the keyword lines the model can genuinely lock
    /// onto (unlike the romanization candidates, which never appear in any
    /// decode). This matrix runs them through the spotter at the PRODUCT
    /// threshold (0.25) and reports which lines fire on which take.
    func testDecodeDerivedCandidateMatrix() async throws {
        guard let dir = Self.bundledModelDir() else {
            throw XCTSkip("kws model not bundled — run tools/fetch-kws-model.sh")
        }
        guard case .success(let files) = SherpaKWSModelFiles.resolve(in: dir) else {
            throw XCTSkip("bundled model dir failed to resolve")
        }
        func boosted(_ base: [Float], by gain: Int) -> [Float] {
            base.map { max(-0.98, min(0.98, $0 * Float(gain))) }
        }

        // Every line bpe-tokenized from run 7 transcripts, all vocab-safe.
        let candidates = [
            "▁IT ▁CAN ▁SEE",            // rec1 phrase decode (×3 repeats)
            "▁CAN ▁SEE",                // rec1 without the stray IT prefix
            "▁A ▁GU N CI",              // rec2 "a gunci"
            "▁GU N CI",                 // rec2 without the A prefix
            "▁A ▁COUNT Y",              // rec2 "a county"
            "▁COUNT Y",                 // rec2 without the A prefix
            "▁K ANT I",                 // rec3 second-word decode ("kanti")
            "▁CAN CE AN S Y",           // rec3 first-part decode
            "▁A ▁CAN CE AN S Y ▁K ANT I", // rec3 x4 full-phrase decode
            "▁GU N S Y ▁GU N CI",       // rec2 x4 full decode
        ]
        print("MATRIX candidates=\(candidates.count)")
        let matrixURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kws-matrix-\(UUID().uuidString).txt")
        try candidates.joined(separator: "\n").write(to: matrixURL,
                                                     atomically: true,
                                                     encoding: .utf8)
        let matrixFiles = SherpaKWSModelFiles(
            directory: FileManager.default.temporaryDirectory,
            encoder: files.encoder, decoder: files.decoder,
            joiner: files.joiner, tokens: files.tokens,
            keywords: matrixURL)
        for (name, label) in [("user_recording.wav", "1"),
                              ("user_recording2.wav", "2"),
                              ("user_recording3.wav", "3")] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let base = try Self.wavSamples(from: url)
            for gain in [1, 4] {
                guard let spotter = makeSpotter(files: matrixFiles,
                                                keywordsFileName: matrixURL.lastPathComponent,
                                                keywordsThreshold: 0.25) else {
                    print("MATRIX-\(label) x\(gain) SPOTTER-INIT-FAILED")
                    continue
                }
                let fired = spotterMatches(spotter: spotter,
                                           samples: boosted(base, by: gain))
                print("MATRIX-\(label) x\(gain) FIRED=\(fired)")
            }
        }
    }
}
