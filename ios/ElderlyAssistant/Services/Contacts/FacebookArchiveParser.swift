import Foundation

// MARK: - Facebook "Download Your Information" friends-list parser (2026-09-07)
//
// Feature #4 question: do current (2025-2026) Facebook DYI JSON exports
// carry anything that helps find/add Messenger friends — names, phone
// numbers, vanity usernames? This parser is the pure, UI-free evidence
// layer for that question. It parses the friends-list file(s) a family
// member downloads on the user's behalf and answers, per archive,
// whether the data can enrich the app's contacts.
//
// RESEARCHED ARCHIVE SHAPE (all sources cited inline below; full
// source list lives with the integration report):
//
// 1. WHERE THE FILE LIVES (path differs by export generation, content
//    is what we parse, so path knowledge only guides the picker):
//    - Classic generation (exports through ~2021):
//        friends/friends.json
//      (github.com/epogrebnyak/facebook-json-to-csv, friends.py;
//       github.com/purvaudai/facebook-archive, plot_friends.py)
//    - Current generation (2022+ nests most categories under
//      your_facebook_activity/; the DYI "Friends and Followers"
//      category, JSON format, is documented to yield):
//        friends_and_followers/friends.json
//      (github.com/MRH-Romit/facebook-unfriend-tracker README, the
//      2024-2025 DYI walk-through; your_facebook_activity wrapper seen
//      across current export tooling, e.g. MetaBridge and Hugging Face
//      export parsers).
//    Content of both files is the same JSON object, so a document-
//    picker flow can hand either file to `parseFriendsJSON`.
//
// 2. ENTRY SHAPE (verified by both parsing tools above): the file is
//    an object with a top-level "friends" key holding an ARRAY of
//    objects, each carrying the friend's display name and the
//    friend-since timestamp:
//        { "friends": [ { "name": "सीता शर्मा", "timestamp": 1582964988 }, … ] }
//    Timestamps appear as integer or string epoch seconds; this parser
//    ignores them (nothing downstream needs the friend-since date).
//
// 3. CONTACT FIELDS — THE QUESTION'S ANSWER: as of the 2025-2026
//    research, NO third-party parser or export walk-through documents
//    any phone, email, or vanity-username field inside friend entries;
//    the list is display names + timestamps only (Facebook stopped
//    shipping friends' contact details in downloads after the 2018
//    scrutiny of its data dumps). The `phone`/`username` probes below
//    therefore key on plausible field names (the pre-2019 dump era's
//    "contact_info", and generic "phone"/"phone_number"/"mobile"/
//    "username") as cheap insurance: if Meta ever re-adds contact
//    fields under those names the parser picks them up, and until then
//    they return nil and `isEnriching` stays false on real archives.
//
// 4. ENCODING: Facebook's JSON text values have a long-standing
//    double-encoding bug — UTF-8 bytes decoded as Latin-1 and written
//    as \u00XX escapes — so non-Latin names arrive mangled
//    ("सीता" arrives as "à¤¸à¥\u{80}à¤¤à¤¾"). Still reported in
//    exports through 2023+ (stackoverflow.com/q/52747566 "What
//    encoding Facebook uses in JSON files from data export";
//    stackoverflow.com/q/75875420). Repair = re-encode the string as
//    Latin-1 bytes, decode as UTF-8, applied only when the value is
//    provably the mangled form (see `repairedMojibakeIfNeeded`).
enum FacebookArchiveParser {

    /// One parsed friend row.
    ///
    /// `name` is the friend's display name as exported (never nil —
    /// entries without a usable name are dropped). `phone`/`username`
    /// are the enrichment probe results: nil in every documented
    /// current export, non-nil only if a future or legacy schema
    /// carries them.
    struct ParsedFriend: Equatable {
        let name: String
        let phone: String?     // E.164-ish digits (leading "+" kept) if carried
        let username: String?  // Facebook vanity username if carried
    }

    /// Keys probed (in order) for a phone number on a friend entry.
    /// None is documented in current exports — see header note 3.
    private static let phoneKeys = ["contact_info", "phone", "phone_number", "mobile"]

    /// Keys probed for a vanity username on a friend entry. Undocumented
    /// in current exports — same insurance rationale as `phoneKeys`.
    private static let usernameKeys = ["username", "vanity"]

    /// Keys probed INSIDE an object-typed `contact_info` value.
    private static let contactInfoPhoneKeys = ["phone_number", "phone", "mobile", "value"]

    // MARK: - Public API

    /// Parses the friends-list JSON from a Facebook DYI archive.
    ///
    /// Handles every shape the research found plus defensive variants:
    /// - the documented object shape `{"friends": [ {name,…}, … ]}`
    ///   (classic `friends/friends.json` and current
    ///   `friends_and_followers/friends.json` are byte-identical in
    ///   content, so one code path covers both);
    /// - a bare top-level ARRAY of friend entries;
    /// - an object whose arrays are grouped under other keys (year-key
    ///   grouping and similar drift) — merged only when no "friends"
    ///   key exists, so "followers"-style sibling arrays can never leak
    ///   people the user did not add as friends.
    ///
    /// Never throws and never crashes: malformed, empty, or garbage
    /// input yields []. Unknown fields are ignored; a bad entry is
    /// skipped, good entries around it still parse.
    static func parseFriendsJSON(data: Data) -> [ParsedFriend] {
        guard let root = jsonRoot(from: data) else { return [] }
        return friendDictionaries(from: root).compactMap(parsedFriend(from:))
    }

    /// True when the archive can meaningfully enrich the app's
    /// contacts: at least one friend carrying a phone OR a vanity
    /// username (either lets the app build a real call/Messenger
    /// affordance that a bare name cannot).
    static func isEnriching(_ friends: [ParsedFriend]) -> Bool {
        friends.contains { $0.phone != nil || $0.username != nil }
    }

    // MARK: - Top-level structure

    /// Decodes `data` into the JSON root object, tolerating a UTF-8
    /// BOM (seen on hand-re-saved copies) and any JSON value kind.
    private static func jsonRoot(from data: Data) -> Any? {
        var bytes = data
        // Drop a leading UTF-8 BOM if present; JSONSerialization
        // rejects one where a hand-edited export may have added it.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes = bytes.dropFirst(3)
        }
        return (try? JSONSerialization.jsonObject(with: bytes))
    }

    /// Flattens the researched + defensive top-level shapes into one
    /// list of entry dictionaries. See `parseFriendsJSON` for the
    /// ordering rules that keep non-friend arrays out.
    private static func friendDictionaries(from root: Any) -> [[String: Any]] {
        switch root {
        case let array as [Any]:
            // Bare top-level array (defensive: not in any documented
            // export, but a trivial drift to tolerate).
            return array.compactMap { $0 as? [String: Any] }
        case let object as [String: Any]:
            if let friends = object["friends"] as? [Any] {
                // The documented shape, both generations.
                return friends.compactMap { $0 as? [String: Any] }
            }
            // No "friends" key: merge every array of dictionaries the
            // object holds (year-keyed grouping and similar drift).
            // Groups are visited in sorted-key order so the parse is
            // deterministic (JSON object key order is unspecified) —
            // for the year-keyed drift that also reads chronologically.
            return object.keys.sorted().flatMap { key -> [[String: Any]] in
                guard let array = object[key] as? [Any] else { return [] }
                return array.compactMap { $0 as? [String: Any] }
            }
        default:
            return []
        }
    }

    // MARK: - Entry fields

    /// Maps one friend dictionary to a `ParsedFriend`, or nil when the
    /// entry carries no usable display name.
    private static func parsedFriend(from entry: [String: Any]) -> ParsedFriend? {
        guard let rawName = entry["name"] as? String else { return nil }
        let name = repairedMojibakeIfNeeded(rawName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return ParsedFriend(name: name,
                            phone: phone(from: entry),
                            username: username(from: entry))
    }

    /// Extracts an E.164-ish phone from a friend entry by probing
    /// `phoneKeys` (research note 3: none documented today — this is
    /// future/legacy insurance). Returns nil for absent, email-typed,
    /// or implausible values.
    private static func phone(from entry: [String: Any]) -> String? {
        for key in phoneKeys {
            guard let value = entry[key] else { continue }
            if let phone = phoneText(from: value) { return phone }
        }
        return nil
    }

    /// Pulls a phone string out of any value shape a contact field
    /// might take: String, [String], or an object whose phone-ish keys
    /// are probed (an email address anywhere in it disqualifies).
    private static func phoneText(from value: Any) -> String? {
        switch value {
        case let text as String:
            return e164ishDigits(from: text)
        case let array as [Any]:
            for element in array {
                if let phone = phoneText(from: element) { return phone }
            }
            return nil
        case let object as [String: Any]:
            for key in contactInfoPhoneKeys {
                guard let nested = object[key] else { continue }
                if let phone = phoneText(from: nested) { return phone }
            }
            return nil
        default:
            return nil
        }
    }

    /// Normalizes an exported contact string to E.164-ish digits:
    /// keeps ASCII digits, keeps a single leading "+", drops every
    /// separator ("+977-9841-000001" → "+9779841000001"). An email
    /// address or a URL is not a phone. Rejects implausible lengths
    /// (E.164 runs 7-15 digits) — junk text can never masquerade as a
    /// number.
    private static func e164ishDigits(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("@"),
              !trimmed.lowercased().contains("http") else { return nil }

        var digits = ""
        for scalar in trimmed.unicodeScalars
            where scalar.value >= 0x30 && scalar.value <= 0x39 { // ASCII "0"..."9"
            digits.unicodeScalars.append(scalar)
        }
        let count = digits.count
        guard count >= 7, count <= 15 else { return nil }
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }

    /// Extracts a vanity username from a friend entry. Strict on
    /// purpose: a URL or whitespace-bearing label is not a usable
    /// Messenger handle (m.me links need the bare vanity).
    private static func username(from entry: [String: Any]) -> String? {
        for key in usernameKeys {
            guard let value = entry[key] else { continue }
            let candidates: [String] = {
                switch value {
                case let text as String: return [text]
                case let array as [Any]: return array.compactMap { $0 as? String }
                default: return []
                }
            }()
            for candidate in candidates {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                // Vanity usernames are bare alphanumerics, dots and
                // underscores — never paths, queries or prose.
                if trimmed.contains("/") || trimmed.contains("?") || trimmed.contains(" ") {
                    continue
                }
                guard (2...80).contains(trimmed.count) else { continue }
                guard trimmed.unicodeScalars.allSatisfy({
                    $0.value >= 0x30 && $0.value <= 0x39 ||   // 0-9
                    $0.value >= 0x41 && $0.value <= 0x5A ||   // A-Z
                    $0.value >= 0x61 && $0.value <= 0x7A ||   // a-z
                    $0.value == 0x2E || $0.value == 0x5F      // . _
                }) else { continue }
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Encoding repair

    /// Facebook's export JSON carries non-Latin text double-encoded
    /// (UTF-8 bytes written as Latin-1, still reported in 2023+
    /// exports — header note 4). This repairs exactly that form and
    /// leaves everything else untouched:
    ///
    /// - Pure-ASCII strings pass straight through.
    /// - Clean non-Latin strings (real Devanagari, CJK, accented Latin
    ///   with glyphs above U+00FF) can never be Latin-1-encoded, so
    ///   they pass through untouched.
    /// - A mangled string occupies only U+0080…U+00FF; encoding it as
    ///   Latin-1 yields the original UTF-8 bytes. Those bytes are
    ///   adopted ONLY when they decode to a valid UTF-8 string with no
    ///   replacement characters (an intact Latin-1 word like "José"
    ///   re-encodes to bytes that are NOT valid UTF-8 and is kept
    ///   as-is).
    private static func repairedMojibakeIfNeeded(_ string: String) -> String {
        let scalars = string.unicodeScalars
        // Fast path: pure ASCII cannot be mangled.
        guard scalars.contains(where: { $0.value > 0x7F }) else { return string }
        // Mangling only produces U+0080…U+00FF code points; anything
        // above that range means the string is already clean.
        guard scalars.allSatisfy({ $0.value <= 0xFF }) else { return string }
        // Re-encode as Latin-1 bytes (always succeeds after the guard)
        // and try to read them back as UTF-8.
        guard let latin1Bytes = string.data(using: .isoLatin1),
              let repaired = String(data: latin1Bytes, encoding: .utf8),
              !repaired.contains("\u{FFFD}") else { return string }
        return repaired
    }
}
