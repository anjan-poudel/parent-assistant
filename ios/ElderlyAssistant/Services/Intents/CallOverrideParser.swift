import Foundation

/// Parses a correction utterance during call confirmation into a method
/// override (spec 2026-09-05 §7.2 correction protocol): "होइन, फोन नै गर"
/// — no, plain phone — rebuilds the pending call with `tel:` and
/// re-confirms once, rather than cancelling outright.
///
/// Deterministic keyword scan, no LLM: the vocabulary of calling methods
/// is tiny and closed, and a wrong guess here means re-asking, not
/// misdialing (the re-confirmation prompt still discloses the method).
/// Any method keyword present at all counts as an override — the user
/// need not say "no" first ("फेसटाइममा गर" mid-confirmation is equally a
/// correction). An utterance with NO method keyword returns nil and the
/// normal yes/no flow proceeds.
enum CallOverrideParser {

    static func parseMethodOverride(_ raw: String) -> CallMethod? {
        let text = NepaliTextNormalizer.normalize(raw)
        guard !text.isEmpty else { return nil }

        // Order matters: check the most specific compounds first. "भिडियो"
        // alone implies FaceTime video regardless of what else is said;
        // "whatsapp" wins over a stray "call/फोन" token ("whatsapp ma call gara").
        if text.contains("whatsapp") || text.contains("ह्वाट्सएप") || text.contains("वाट्सएप") {
            return .whatsappChat
        }
        if text.contains("video") || text.contains("भिडियो") {
            return .facetimeVideo
        }
        if text.contains("facetime") || text.contains("फेसटाइम") {
            return .facetimeAudio
        }
        // A bare "फोन" / "phone" / "कल" — but NOT when it's only part of
        // the original request being confirmed, which is why this parser
        // runs ONLY on the confirmation-response turn, never on the
        // initial command.
        if text.contains("phone") || text.contains("फोन") || text.contains("कल") {
            return .phone
        }
        return nil
    }
}
