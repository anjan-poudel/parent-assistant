import Foundation

/// Domain types for the appliance/vision helper (design:
/// docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md §4,
/// plus `knowledgeSource` from the live-AR/local-knowledge addendum §12.3).
///
/// These decode Gemini's prompted-JSON responses. Decoding is deliberately
/// TOLERANT of partial payloads (missing fields get safe defaults, junk
/// array elements are dropped) because the model's output is prompt-
/// engineered, not schema-enforced — but a payload with no usable identity
/// object at all throws, since there is nothing to present or cache then.

/// What Gemini identified in the photo. `brand`/`model` are nil when Gemini
/// can't tell (generic/unlabeled remote, worn-off text) — callers must treat
/// that as "no reliable cache key", not "identification failed" (§4.3).
struct ApplianceIdentity: Codable, Equatable {
    let brand: String?
    let model: String?
    /// See the design doc §3.1's category list; stored as a raw String, not
    /// a Swift enum, so an unrecognized future category from Gemini decodes
    /// instead of failing the whole payload.
    let category: String
    /// Spoken-friendly, e.g. "Panasonic microwave".
    let displayName: String

    init(brand: String?, model: String?, category: String, displayName: String) {
        self.brand = brand
        self.model = model
        self.category = category
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? "other"
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
    }

    /// Normalized "brand|model" cache key — only when BOTH fields are
    /// present and non-blank (design §4.3: identity must be reliable to
    /// generalize across photos of the same appliance model).
    var brandModelKey: String? {
        guard let brand, let model else { return nil }
        let b = brand.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let m = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, !m.isEmpty else { return nil }
        return b + "|" + m
    }
}

/// Normalized [0,1] box, origin top-left, in the ORIGINAL photo's coordinate
/// space — resolution-independent by construction (§5.3).
struct NormalizedBox: Codable, Equatable {
    let xMin: Double
    let yMin: Double
    let xMax: Double
    let yMax: Double

    var center: (x: Double, y: Double) { ((xMin + xMax) / 2, (yMin + yMax) / 2) }

    /// A box with zero/negative extent, NaN, or entirely outside [0,1] can
    /// never have come from a real localization — the policy layer drops
    /// these rather than drawing a nonsense circle (§4.1's "never draw a
    /// guessed-location circle", applied to malformed boxes too).
    var isValid: Bool {
        [xMin, yMin, xMax, yMax].allSatisfy { $0.isFinite }
            && xMax > xMin && yMax > yMin
            && xMax > 0 && yMax > 0 && xMin < 1 && yMin < 1
    }
}

struct GroundedControl: Codable, Equatable {
    let label: String
    let stepNumber: Int?
    let normalizedBox: NormalizedBox
    let confidence: Double

    init(label: String, stepNumber: Int?, normalizedBox: NormalizedBox, confidence: Double) {
        self.label = label
        self.stepNumber = stepNumber
        self.normalizedBox = normalizedBox
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        // LLM JSON is loose about numbers: accept 2, 2.0, or "2".
        if let i = try? c.decodeIfPresent(Int.self, forKey: .stepNumber) {
            stepNumber = i
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .stepNumber) {
            stepNumber = Int(d)
        } else {
            stepNumber = (try? c.decodeIfPresent(String.self, forKey: .stepNumber))
                .flatMap { Int($0) }
        }
        // The one hard requirement per control — a control we cannot place
        // is useless for overlay (its instruction still survives as plain
        // step text, so nothing user-facing is lost by dropping it here).
        normalizedBox = try c.decode(NormalizedBox.self, forKey: .normalizedBox)
        // A missing per-control confidence is treated as 0 — below the
        // overlay threshold, so the control stays text-only (§4.1).
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 0
    }
}

/// Which knowledge tier produced a guidance answer (addendum §12.3). A
/// `webSearchGrounded` entry cost a real web search and is more likely
/// model-specific, so the cache protects it from casual LRU eviction.
enum KnowledgeSource: String, Codable, Equatable {
    /// Gemini's own training knowledge, no search.
    case onDeviceModelKnowledge
    /// Gemini + google_search tool.
    case webSearchGrounded
}

/// The full result of an identify/follow-up call. Codable so it can be
/// cached as-is (§4.3) with no separate persistence model.
struct ApplianceGuidance: Codable, Equatable {
    let identity: ApplianceIdentity
    let steps: [String]
    let groundedControls: [GroundedControl]
    let spokenSummary: String
    let confidence: Double
    var knowledgeSource: KnowledgeSource

    init(identity: ApplianceIdentity, steps: [String], groundedControls: [GroundedControl],
         spokenSummary: String, confidence: Double,
         knowledgeSource: KnowledgeSource = .onDeviceModelKnowledge) {
        self.identity = identity
        self.steps = steps
        self.groundedControls = groundedControls
        self.spokenSummary = spokenSummary
        self.confidence = confidence
        self.knowledgeSource = knowledgeSource
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The ONLY hard requirement: an identity object. Everything else
        // degrades to a safe default — a missing `confidence` becomes 0,
        // which the policy layer treats as "hedge, don't present as fact"
        // (§4.1), the safest interpretation of an incomplete answer.
        identity = try c.decode(ApplianceIdentity.self, forKey: .identity)
        steps = (try? c.decodeIfPresent(LossyDecodableArray<String>.self, forKey: .steps))?
            .elements ?? []
        groundedControls = (try? c.decodeIfPresent(LossyDecodableArray<GroundedControl>.self,
                                                   forKey: .groundedControls))?
            .elements ?? []
        spokenSummary = (try? c.decodeIfPresent(String.self, forKey: .spokenSummary)) ?? ""
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 0
        // The model never emits this field — it doesn't know our tiers.
        // The client sets it from `allowSearchGrounding` after decoding;
        // decodeIfPresent only matters for re-decoding cached entries.
        knowledgeSource = (try? c.decodeIfPresent(KnowledgeSource.self, forKey: .knowledgeSource))
            ?? .onDeviceModelKnowledge
    }
}

// MARK: - Lossy decoding helpers

/// Decodes an array while dropping elements that fail to decode
/// individually (e.g. one groundedControl missing its box), rather than
/// failing the whole payload — the model's per-element shape is the least
/// reliable part of the response.
private struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else {
                // Advance past the undecodable element so the loop
                // doesn't spin forever on the same index.
                _ = try container.decode(DiscardedValue.self)
            }
        }
        elements = decoded
    }

    /// Consumes any single JSON value (object, array, string, number,
    /// bool, null) so a failed element decode can be skipped.
    private struct DiscardedValue: Decodable {
        init(from decoder: Decoder) throws {
            if var array = try? decoder.unkeyedContainer() {
                while !array.isAtEnd { _ = try array.decode(DiscardedValue.self) }
                return
            }
            if let object = try? decoder.container(keyedBy: AnyKey.self) {
                for key in object.allKeys { _ = try object.decode(DiscardedValue.self, forKey: key) }
                return
            }
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { return }
            if (try? single.decode(Bool.self)) != nil { return }
            if (try? single.decode(Double.self)) != nil { return }
            if (try? single.decode(String.self)) != nil { return }
            throw DecodingError.dataCorruptedError(
                in: single, debugDescription: "unconsumable JSON value")
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}
