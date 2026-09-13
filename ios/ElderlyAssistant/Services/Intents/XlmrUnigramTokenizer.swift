import Foundation

/// [ENCODER-RUNTIME-READY] The Swift implementation of the intent encoder's
/// XLM-R Unigram tokenizer — the piece that T-037-a left as an explicit gap
/// (`UnavailableIntentEncoderTokenizer`).
///
/// ## What it is
///
/// A faithful port of the pipeline the T-033/T-036 training code runs through
/// HuggingFace: `tok(words, is_split_into_words=True, add_special_tokens=True,
/// truncation=True, max_length=64)`, i.e. the XLM-R 250k SentencePiece Unigram
/// vocabulary with the precompiled-character-map normalizer, the Metaspace
/// pre-tokenizer, the `<s> A </s>` template and truncation to the manifest's
/// `maxSequenceLength`. Training and runtime must produce IDENTICAL ids and
/// word alignment or the span decoder silently mislabels — which is why the
/// design is a line-by-line mirror of the reviewed Python reference
/// (`tools/train-intent/src/xlmr_unigram_ref.py`) rather than an independent
/// re-derivation, and why the golden-fixture gate
/// (`XlmrUnigramTokenizerTests`) compares against the Python tokenizer's own
/// output for every fixture row.
///
/// The pipeline, per word (the `is_split_into_words` path encodes each word
/// separately — that is what stamps the word index and keeps the BIO
/// alignment stable):
///
///  1. added-token extraction — longest literal match at each position
///     (`<s>`, `<pad>`, `</s>`, `<unk>`, `<mask>` are ids, not text);
///  2. `Precompiled` normalization — grapheme clusters shorter than 6 bytes
///     are looked up whole, everything else scalar by scalar; a lookup is the
///     SHORTEST key that is a prefix of the query (spm's `results[0]`);
///  3. `Replace` normalization — runs of two or more spaces collapse to one;
///  4. `Metaspace` — spaces become `▁`, a leading `▁` is prepended when
///     absent, and the text splits before every `▁`;
///  5. Unigram Viterbi per piece — every vocabulary piece that is a prefix of
///     the suffix becomes a lattice node, one synthetic unk node is injected
///     per scalar position that has no single-scalar piece, ties keep the
///     FIRST (earliest-beginning) predecessor, consecutive unk nodes fuse
///     into one token and are re-looked-up in the vocabulary;
///  6. `<s>` + sequence + `</s>`, truncated to `maxSequenceLength` with the
///     two processor-added tokens reserved — HF truncates before the
///     post-processor runs, so the template's specials always survive.
///
/// ## The resource
///
/// Everything (vocabulary bytes + ids + scores, the character-map table, the
/// added tokens, the special ids) lives in one committed binary built by
/// `tools/train-intent/src/encoder_tokenizer_export.py` from the checkpoint's
/// `tokenizer.json` — provenance and licence in that script's docstring.
/// `isReady` is false ONLY when that resource is missing or unusable; a
/// tokenizer that exists can always encode (there is no path here that
/// reports success without doing the work).
final class XlmrUnigramTokenizer: IntentEncoderTokenizing {

    /// Identifies this tokenizer + vocab revision in observability events.
    /// Never contains user content.
    static let identifier = "xlmr-250k-unigram-v1"

    /// Bundled resource coordinates (`Resources/Intents/` — a folder
    /// reference in `project.yml`, so the directory lands in the app bundle
    /// as `Intents/`).
    static let resourceName = "encoder_xlmr_unigram"
    static let resourceExtension = "dat"
    static let resourceSubdirectory = "Intents"

    let tokenizerID = XlmrUnigramTokenizer.identifier

    /// True: an instance only exists once its vocabulary resource loaded.
    /// `XlmrUnigramTokenizer.load` throws (and returns nothing) when the
    /// resource is absent, truncated or not an XLMU0001 file — callers fall
    /// back to `UnavailableIntentEncoderTokenizer`, so the interpreter's
    /// `isAvailable` stays honest instead of the tokenizer failing per turn.
    var isReady: Bool { true }

    private let tables: Tables

    // MARK: - Loading

    enum LoadError: Error, Equatable {
        case resourceMissing
        case unreadable(String)
        case corrupt(String)
    }

    /// Loads the bundled vocabulary resource, or throws `LoadError`.
    static func load(bundle: Bundle = .main) throws -> XlmrUnigramTokenizer {
        guard let url = bundle.url(forResource: resourceName,
                                   withExtension: resourceExtension,
                                   subdirectory: resourceSubdirectory) else {
            throw LoadError.resourceMissing
        }
        return try load(contentsOf: url)
    }

    /// Loads a vocabulary resource from an explicit location (used by the
    /// tests, and by any future side-loaded vocabulary).
    static func load(contentsOf url: URL) throws -> XlmrUnigramTokenizer {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(url.lastPathComponent)
        }
        let tables = try Tables(data: data)
        return XlmrUnigramTokenizer(tables: tables)
    }

    private init(tables: Tables) {
        self.tables = tables
    }

    // MARK: - IntentEncoderTokenizing

    func tokenize(sanitisedTranscript: String,
                  maxSequenceLength: Int) -> IntentEncoderTokenization? {
        // The template always contributes `<s>` and `</s>`; a budget that
        // cannot hold them is not a budget this tokenizer can serve.
        guard maxSequenceLength >= 2 else { return nil }

        let words = Self.splitWords(sanitisedTranscript)
        var ids: [Int32] = []
        var wordIndices: [Int?] = []
        for (wordIndex, word) in words.enumerated() {
            for segment in splitAddedTokens(word) {
                if let addedID = segment.id {
                    ids.append(addedID)
                    wordIndices.append(wordIndex)
                    continue
                }
                let normalised = normalise(segment.text)
                for piece in metaspacePieces(normalised) {
                    for tokenID in unigramTokenIDs(piece) {
                        ids.append(tokenID)
                        wordIndices.append(wordIndex)
                    }
                }
            }
        }

        // Truncate BEFORE templating, reserving the two processor tokens —
        // the order HuggingFace uses.
        let keep = max(0, maxSequenceLength - 2)
        let truncatedIDs = ids.prefix(keep)
        let truncatedWordIndices = wordIndices.prefix(keep)
        let tokenIds = [tables.bosID] + truncatedIDs + [tables.eosID]
        let indices: [Int?] = [nil] + Array(truncatedWordIndices) + [nil]
        return IntentEncoderTokenization(
            tokenIds: tokenIds,
            attentionMask: [Int32](repeating: 1, count: tokenIds.count),
            wordIndices: indices,
            words: words)
    }

    // MARK: - Word splitting

    /// Whitespace words, exactly as `IntentEncoderDecoder.wordScalarOffsets`
    /// slices them: Unicode scalars, `CharacterSet.whitespacesAndNewlines` as
    /// the separator set, runs collapsed and leading/trailing separators
    /// dropped. The decoder compares its own split against these words
    /// before emitting any span, so the two must never drift.
    static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: - Stage 1: added tokens

    /// Splits one word into (text, added-token id?) segments. Special literals
    /// are extracted before normalization — the Rust `extract_and_normalize`
    /// order — so `<s>` typed by a user arrives as id 0, not as its pieces.
    private func splitAddedTokens(_ word: String) -> [(text: String, id: Int32?)] {
        guard !word.isEmpty else { return [("", nil)] }
        let scalars = Array(word.unicodeScalars)
        var segments: [(text: String, id: Int32?)] = []
        var index = 0
        while index < scalars.count {
            var match: (scalars: [UnicodeScalar], id: Int32)?
            for added in tables.addedTokens where Self.matches(scalars, at: index, added.scalars) {
                if match == nil || added.scalars.count > match!.scalars.count {
                    match = (added.scalars, added.id)
                }
            }
            if let match {
                segments.append((Self.string(from: match.scalars), match.id))
                index += match.scalars.count
                continue
            }
            var next = index + 1
            while next < scalars.count, !startsAddedToken(scalars, at: next) {
                next += 1
            }
            segments.append((Self.string(from: scalars[index..<next]), nil))
            index = next
        }
        return segments
    }

    /// Does an added-token literal start at `index`? (ASCII contents, so a
    /// scalar-wise comparison is exact.)
    private static func matches(_ scalars: [UnicodeScalar],
                                at index: Int,
                                _ content: [UnicodeScalar]) -> Bool {
        guard content.count <= scalars.count - index else { return false }
        for offset in 0..<content.count where scalars[index + offset] != content[offset] {
            return false
        }
        return true
    }

    private func startsAddedToken(_ scalars: [UnicodeScalar], at index: Int) -> Bool {
        for added in tables.addedTokens where Self.matches(scalars, at: index, added.scalars) {
            return true
        }
        return false
    }

    private static func string<S: Sequence>(from scalars: S) -> String
    where S.Element == UnicodeScalar {
        var text = ""
        for scalar in scalars { text.unicodeScalars.append(scalar) }
        return text
    }

    // MARK: - Stages 2-3: normalization

    /// `Precompiled` then `Replace`, in the pipeline's order.
    private func normalise(_ text: String) -> String {
        collapseSpaces(normalisePrecompiled(text))
    }

    /// The spm precompiled character map: a grapheme cluster shorter than six
    /// bytes is looked up whole; whatever is left (and every scalar of a
    /// longer cluster) is looked up scalar by scalar. A lookup returns the
    /// replacement for the SHORTEST key that prefixes the query; no match
    /// leaves the text unchanged.
    private func normalisePrecompiled(_ text: String) -> String {
        var output = ""
        for cluster in text {
            let clusterText = String(cluster)
            if clusterText.utf8.count < 6,
               let replacement = tables.charmapReplacement(Array(clusterText.utf8)) {
                output += replacement
                continue
            }
            for scalar in cluster.unicodeScalars {
                if let replacement = tables.charmapReplacement(Array(String(scalar).utf8)) {
                    output += replacement
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

    /// `Replace` with the pattern ` {2,}`: runs of two or more ASCII spaces
    /// become one space (single spaces are untouched).
    private func collapseSpaces(_ text: String) -> String {
        var output = ""
        var previousWasSpace = false
        for scalar in text.unicodeScalars {
            if scalar == " " {
                if previousWasSpace { continue }
                previousWasSpace = true
            } else {
                previousWasSpace = false
            }
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    // MARK: - Stage 4: metaspace

    /// Spaces become `▁`, a leading `▁` is prepended when the text does not
    /// already start with one, and the text splits before every `▁`
    /// (`MergedWithNext`: the marker stays with the piece it introduces).
    ///
    /// An EMPTY input is a hard early return with no pieces at all — the
    /// rule tokenizers' `Metaspace` implements (`pre_tokenize_str("")` is
    /// `[]`, and a word that normalised to the empty string, e.g. one made
    /// only of scalars the character map deletes, contributes no ids and no
    /// word index). The guard must run BEFORE the prefix insertion: after it
    /// the condition is unreachable, because inserting `▁` turns `""` into
    /// `"▁"` and that spurious piece encodes as a real token.
    private func metaspacePieces(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var scalars = Array(text.unicodeScalars)
        for index in scalars.indices where scalars[index] == " " {
            scalars[index] = "▁"
        }
        if scalars.first != "▁" { scalars.insert("▁", at: 0) }
        var pieces: [String] = []
        var current = ""
        for scalar in scalars {
            if scalar == "▁", !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: - Stage 5: Unigram Viterbi

    /// One piece's Viterbi path as token ids. Mirrors the lattice semantics
    /// the Rust `Unigram` model implements (and the Python reference
    /// reproduces), including the tie-breaks: the first-inserted (earliest
    /// beginning) predecessor wins, and the final node is the first of the
    /// best-scoring nodes that end at the last scalar.
    private func unigramTokenIDs(_ piece: String) -> [Int32] {
        guard !piece.isEmpty else { return [] }
        let bytes = Array(piece.utf8)
        var scalarStarts: [Int] = []
        var scalarByteLengths: [Int] = []
        var offset = 0
        for scalar in piece.unicodeScalars {
            scalarStarts.append(offset)
            let length = String(scalar).utf8.count
            scalarByteLengths.append(length)
            offset += length
        }
        let scalarCount = scalarStarts.count
        let byteCount = bytes.count
        var scalarIndexByByteOffset = [Int](repeating: -1, count: byteCount + 1)
        for (index, start) in scalarStarts.enumerated() {
            scalarIndexByByteOffset[start] = index
        }
        scalarIndexByByteOffset[byteCount] = scalarCount

        var nodes: [Node] = []
        nodes.reserveCapacity(scalarCount * 4)
        var beginNodes = [[Int]](repeating: [], count: scalarCount)
        var endNodes = [[Int]](repeating: [], count: scalarCount + 1)
        // Structural BOS (id -1) so every node's DP has a predecessor; it is
        // excluded from the backtracked path.
        nodes.append(Node(begin: 0, end: 0, endScalar: 0, id: -1, score: 0,
                          bestPrevious: -1, backtrace: 0))
        endNodes[0].append(0)

        let unkScore = tables.minScore - 10.0
        for position in 0..<scalarCount {
            let base = scalarStarts[position]
            let singleScalarBytes = scalarByteLengths[position]
            let maximum = min(tables.maxPieceBytes, byteCount - base)
            var hasSingleScalarPiece = false
            var length = 1
            while length <= maximum {
                let end = base + length
                if let sortedIndex = tables.vocabularyIndex(bytes[base..<end]) {
                    // A vocabulary piece is valid UTF-8, so a match always
                    // ends on a scalar boundary; a non-boundary hit would be
                    // a corrupt resource and is skipped rather than trusted.
                    let endScalar = scalarIndexByByteOffset[end]
                    if endScalar >= 0 {
                        nodes.append(Node(begin: base,
                                          end: end,
                                          endScalar: endScalar,
                                          id: Int32(bitPattern: tables.pieceIDs[sortedIndex]),
                                          score: Double(tables.pieceScores[sortedIndex]),
                                          bestPrevious: -1,
                                          backtrace: 0))
                        beginNodes[position].append(nodes.count - 1)
                        if length == singleScalarBytes { hasSingleScalarPiece = true }
                    }
                }
                length += 1
            }
            if !hasSingleScalarPiece {
                nodes.append(Node(begin: base,
                                  end: base + singleScalarBytes,
                                  endScalar: position + 1,
                                  id: tables.unkID,
                                  score: unkScore,
                                  bestPrevious: -1,
                                  backtrace: 0))
                beginNodes[position].append(nodes.count - 1)
            }
        }
        for position in 0..<scalarCount {
            for nodeIndex in beginNodes[position] {
                endNodes[nodes[nodeIndex].endScalar].append(nodeIndex)
            }
        }

        for position in 0..<scalarCount {
            for rightIndex in beginNodes[position] {
                var bestPrevious = -1
                var bestScore = 0.0
                for leftIndex in endNodes[position] {
                    let score = nodes[leftIndex].backtrace + nodes[rightIndex].score
                    if bestPrevious == -1 || score > bestScore {
                        bestPrevious = leftIndex
                        bestScore = score
                    }
                }
                guard bestPrevious >= 0 else { return [] }
                nodes[rightIndex].bestPrevious = bestPrevious
                nodes[rightIndex].backtrace = bestScore
            }
        }

        var best: Int?
        var bestScore = 0.0
        for nodeIndex in endNodes[scalarCount] {
            if best == nil || nodes[nodeIndex].backtrace > bestScore {
                best = nodeIndex
                bestScore = nodes[nodeIndex].backtrace
            }
        }
        guard var cursor = best else { return [] }

        var path: [Int] = []
        while cursor >= 0, nodes[cursor].id != -1 {
            path.append(cursor)
            cursor = nodes[cursor].bestPrevious
        }
        path.reverse()

        // fuse_unk: consecutive unk nodes become ONE token; the fused surface
        // is looked up in the vocabulary and falls back to unk.
        var tokenIDs: [Int32] = []
        var unkBytes: [UInt8] = []
        func flushUnknown() {
            guard !unkBytes.isEmpty else { return }
            tokenIDs.append(tables.vocabularyIndex(unkBytes[...]).map { Int32(bitPattern: tables.pieceIDs[$0]) } ?? tables.unkID)
            unkBytes.removeAll(keepingCapacity: true)
        }
        for nodeIndex in path {
            let node = nodes[nodeIndex]
            if node.id == tables.unkID {
                unkBytes.append(contentsOf: bytes[node.begin..<node.end])
            } else {
                flushUnknown()
                tokenIDs.append(node.id)
            }
        }
        flushUnknown()
        return tokenIDs
    }

    private struct Node {
        /// Byte offsets into the piece (the fused-unk surface is sliced from
        /// them).
        let begin: Int
        let end: Int
        /// Scalar index the node ends at — the lattice's DP coordinate.
        let endScalar: Int
        let id: Int32
        let score: Double
        var bestPrevious: Int
        var backtrace: Double
    }

    // MARK: - Resource tables

    /// The parsed vocabulary resource. Sections are copied out of the mapped
    /// file into native arrays, so nothing here points into the mapping.
    private struct Tables {
        let pieces: [UInt8]
        let pieceOffsets: [UInt32]
        let pieceIDs: [UInt32]
        let pieceScores: [Float]
        let charmapKeys: [UInt8]
        let charmapKeyOffsets: [UInt32]
        let charmapValues: [UInt8]
        let charmapValueOffsets: [UInt32]
        let addedTokens: [(scalars: [UnicodeScalar], id: Int32)]
        let bosID: Int32
        let eosID: Int32
        let unkID: Int32
        let pieceCount: Int
        let charmapCount: Int
        let maxPieceBytes: Int
        let minScore: Double

        static let magic: [UInt8] = Array("XLMU0001".utf8)
        static let headerBytes = 88

        init(data: Data) throws {
            guard data.count >= Tables.headerBytes else {
                throw LoadError.corrupt("resource shorter than its header")
            }
            let header = [UInt8](data.prefix(Tables.headerBytes))
            guard Array(header[0..<8]) == Tables.magic else {
                throw LoadError.corrupt("bad magic")
            }
            func u32(_ index: Int) -> UInt32 {
                UInt32(header[index]) | UInt32(header[index + 1]) << 8
                    | UInt32(header[index + 2]) << 16 | UInt32(header[index + 3]) << 24
            }
            // Header layout (little-endian, mirrors encoder_tokenizer_export):
            //   0..7   magic "XLMU0001" (the trailing digits carry the version)
            //   8..39  piece_count, charmap_count, added_count,
            //          bos, eos, unk, pad, mask
            //   40..83 the eleven section byte lengths, in file order
            let pieces = Int(u32(8))
            let charmap = Int(u32(12))
            let added = Int(u32(16))
            bosID = Int32(bitPattern: u32(20))
            eosID = Int32(bitPattern: u32(24))
            unkID = Int32(bitPattern: u32(28))
            let lengths = (0..<11).map { Int(u32(40 + 4 * $0)) }
            pieceCount = pieces
            charmapCount = charmap

            var cursor = Tables.headerBytes
            func take(_ length: Int) throws -> [UInt8] {
                guard length >= 0, cursor + length <= data.count else {
                    throw LoadError.corrupt("section overruns the resource")
                }
                let range = cursor..<(cursor + length)
                let bytes = [UInt8](data[range])
                cursor += length + (4 - length % 4) % 4
                return bytes
            }
            let pieceIDBytes = try take(lengths[0])
            let pieceScoreBytes = try take(lengths[1])
            let pieceOffsetBytes = try take(lengths[2])
            let pieceBlob = try take(lengths[3])
            let keyOffsetBytes = try take(lengths[4])
            let valueOffsetBytes = try take(lengths[5])
            let keyBlob = try take(lengths[6])
            let valueBlob = try take(lengths[7])
            let addedIDBytes = try take(lengths[8])
            let addedOffsetBytes = try take(lengths[9])
            let addedBlob = try take(lengths[10])
            guard cursor == data.count else {
                throw LoadError.corrupt("trailing bytes after the last section")
            }

            func u32Array(_ bytes: [UInt8]) -> [UInt32] {
                var values = [UInt32](repeating: 0, count: bytes.count / 4)
                values.withUnsafeMutableBytes { destination in
                    bytes.withUnsafeBytes { source in
                        destination.copyMemory(from: source)
                    }
                }
                return values
            }
            func f32Array(_ bytes: [UInt8]) -> [Float] {
                var values = [Float](repeating: 0, count: bytes.count / 4)
                values.withUnsafeMutableBytes { destination in
                    bytes.withUnsafeBytes { source in
                        destination.copyMemory(from: source)
                    }
                }
                return values
            }

            pieceIDs = u32Array(pieceIDBytes)
            pieceScores = f32Array(pieceScoreBytes)
            pieceOffsets = u32Array(pieceOffsetBytes)
            self.pieces = pieceBlob
            charmapKeyOffsets = u32Array(keyOffsetBytes)
            charmapValueOffsets = u32Array(valueOffsetBytes)
            charmapKeys = keyBlob
            charmapValues = valueBlob
            let addedIDs = u32Array(addedIDBytes)
            let addedOffsets = u32Array(addedOffsetBytes)

            guard pieceIDs.count == pieces, pieceScores.count == pieces,
                  pieceOffsets.count == pieces + 1,
                  Int(pieceOffsets[pieces]) == pieceBlob.count,
                  charmapKeyOffsets.count == charmap + 1,
                  charmapValueOffsets.count == charmap + 1,
                  Int(charmapKeyOffsets[charmap]) == keyBlob.count,
                  Int(charmapValueOffsets[charmap]) == valueBlob.count,
                  addedIDs.count == added, addedOffsets.count == added + 1,
                  Int(addedOffsets[added]) == addedBlob.count else {
                throw LoadError.corrupt("section tables disagree with their lengths")
            }

            var maximumPiece = 0
            for index in 0..<pieces {
                maximumPiece = max(maximumPiece,
                                   Int(pieceOffsets[index + 1] - pieceOffsets[index]))
            }
            maxPieceBytes = maximumPiece
            minScore = pieceScores.min().map(Double.init) ?? 0

            var tokens: [(scalars: [UnicodeScalar], id: Int32)] = []
            for index in 0..<added {
                let start = Int(addedOffsets[index])
                let end = Int(addedOffsets[index + 1])
                let content = String(decoding: addedBlob[start..<end], as: UTF8.self)
                tokens.append((Array(content.unicodeScalars), Int32(bitPattern: addedIDs[index])))
            }
            addedTokens = tokens
        }

        /// Binary search over the byte-sorted vocabulary: the sorted index of
        /// an exact match, nil otherwise. Unsigned byte ordering, so it agrees
        /// with the exporter's `sorted()`.
        func vocabularyIndex(_ query: ArraySlice<UInt8>) -> Int? {
            var low = 0
            var high = pieceCount
            while low < high {
                let mid = (low + high) / 2
                if comparePiece(mid, query) < 0 { low = mid + 1 } else { high = mid }
            }
            guard low < pieceCount, comparePiece(low, query) == 0 else { return nil }
            return low
        }

        /// Sorted piece `index` compared with `query` in memcmp order:
        /// negative when the stored piece sorts first, positive when it sorts
        /// last, zero on equality.
        private func comparePiece(_ index: Int, _ query: ArraySlice<UInt8>) -> Int {
            let start = Int(pieceOffsets[index])
            let length = Int(pieceOffsets[index + 1]) - start
            var offset = 0
            for byte in query {
                if offset >= length { return -1 }   // stored ran out first
                let stored = pieces[start + offset]
                if stored != byte { return stored < byte ? -1 : 1 }
                offset += 1
            }
            return offset == length ? 0 : 1         // stored is longer
        }

        /// The replacement for the SHORTEST charmap key that prefixes `query`
        /// (at most five bytes — longer keys can never be reached, see the
        /// exporter). Nil when nothing matches.
        func charmapReplacement(_ query: [UInt8]) -> String? {
            let limit = min(query.count, 5)
            var length = 1
            while length <= limit {
                let end = length
                var low = 0
                var high = charmapCount
                while low < high {
                    let mid = (low + high) / 2
                    if compareCharmapKey(mid, query[0..<end]) < 0 { low = mid + 1 } else { high = mid }
                }
                if low < charmapCount, compareCharmapKey(low, query[0..<end]) == 0 {
                    let start = Int(charmapValueOffsets[low])
                    let stop = Int(charmapValueOffsets[low + 1])
                    return String(bytes: charmapValues[start..<stop], encoding: .utf8)
                }
                length += 1
            }
            return nil
        }

        private func compareCharmapKey(_ index: Int, _ query: ArraySlice<UInt8>) -> Int {
            let start = Int(charmapKeyOffsets[index])
            let length = Int(charmapKeyOffsets[index + 1]) - start
            var offset = 0
            for byte in query {
                if offset >= length { return -1 }   // stored ran out first
                let stored = charmapKeys[start + offset]
                if stored != byte { return stored < byte ? -1 : 1 }
                offset += 1
            }
            return offset == length ? 0 : 1         // stored is longer
        }
    }
}
