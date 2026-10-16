import Foundation

// [CNR-GUARD] (T-169, feature `conversational-nepali-replies`) The pure,
// total, synchronous Nepali grammar guard: it VERIFIES a chat reply's
// spoken text and returns a verdict — pass, flag(classes:) or
// unavailable(reason:) — and nothing else. It never rewrites: no code road
// returns corrected, truncated or substituted words (FR-CNR-005). The
// doctrine is the polisher's (SpokenReplyPolisher.swift:21-26 —
// deterministic, context-free, idempotent, "grammar stays the models'
// job"); the design of record is design-l1 §7.1-7.4, and the resolution of
// a flag (escalation, safe template, degraded event) is T-174's, not here.
//
// THE SPEC IS THE ONLY ORIGIN OF THE CHECK DATA (FR-CNR-001). The four
// machine blocks below are embedded BYTE-VERBATIM from
// tools/train-intent/seeds/nepali-chat-style-spec, and the compiled tables
// are decoded from exactly those bytes — there is no hand-authored copy of
// any lexicon that could drift. Each block constant sits between the markers
//   // @style-spec-block: <name>   ...   // @style-spec-block-end: <name>
// (the declaration line after the begin marker through the closing delimiter
// before the end marker), and the LITERAL VALUE equals the spec's fenced
// block body byte-for-byte (Swift multiline-literal semantics: dedented by
// the closing delimiter's indentation; the newline before the closing
// delimiter is not part of the value). T-170's mirror check is the gate that
// compares them byte-for-byte; this unit's suite pins the same equality
// in-process (it re-reads the spec artifact and compares the constants'
// values). The rule PROSE the guard executes is cited in place between
// `@style-spec-section:` / `@style-spec-section-end:` markers, which
//   python3 tools/train-intent/src/style_spec.py --check-consumers <file>
// verifies byte-for-byte against the section text.
//
// PURITY (FR-CNR-005 "no rewrite path exists"; NFR-CNR-006): no I/O, no
// async, no state, no clock, no randomness and no logging — nothing
// content-bearing can leave this type; the verdict is the only output.
// `unavailable` means "not verified" and is never a pass; the caller
// (T-174) owns what a flag or an unavailable turn does.

/// The guard's check inventory (design-l1 §7.2; the spec's `guard_checks`
/// block names the same three ids). A `flag` carries its failing classes in
/// this declaration order — the canonical order, pinned by test.
enum GrammarCheckClass: String, CaseIterable, Equatable {
    case honorificAgreement
    case devanagariPurity
    case danglingParticle
}

/// The guard's ONLY output (FR-CNR-005): a classification, never text.
///
/// - `pass` — every check ran and found nothing.
/// - `flag(classes:)` — the named checks found their own evidence; the
///   classes are in `GrammarCheckClass.allCases` order. The verdict says
///   WHAT failed, never what to say instead.
/// - `unavailable(reason:)` — the guard could not verify (a reason code
///   from `GrammarGuardUnavailableReason`); callers treat this as "not
///   verified", NEVER as pass (design §7.4).
enum GrammarGuardVerdict: Equatable {
    case pass
    case flag(classes: [GrammarCheckClass])
    case unavailable(reason: String)
}

/// The closed set of `unavailable` reason codes (design-l1 §7.4). Reasons
/// are classification only — never reply text. Adding a case is a contract
/// change; the unit suite pins this set.
enum GrammarGuardUnavailableReason: String, CaseIterable, Equatable {
    /// The session locale is not Nepali, so the Nepali register is not this
    /// session's contract — the guard declines instead of misjudging.
    case localeNotNepali = "localeNotNepali"
    /// The compiled lexicons failed to load or validate: "not verified",
    /// the state design §7.4 describes.
    case lexiconsUnavailable = "lexiconsUnavailable"
    /// The reply carries no Devanagari letters — a romanized or English
    /// reply is outside this guard's competence (the P2 romanized leg's
    /// seam, FR-CNR-027): declined, never flagged and never passed.
    case inputNotDevanagari = "inputNotDevanagari"
    /// The reply carries no letters at all (empty, whitespace, punctuation,
    /// digits or symbols only) — there is nothing to verify.
    case inputEmpty = "inputEmpty"
}

enum NepaliGrammarGuard {

    // MARK: - Entry point (design-l1 §7.1)

    /// The contract entry point: pure, total, synchronous. `locale` names
    /// the session's language ("ne", "ne-NP", "en", …); the guard judges
    /// Devanagari replies in Nepali sessions only and declines otherwise.
    static func verdict(spokenText: String, locale: String) -> GrammarGuardVerdict {
        verdict(spokenText: spokenText, locale: locale, lexicons: compiledLexicons)
    }

    /// The same pipeline with the lexicon load result supplied explicitly —
    /// the seam the failure-path tests exercise (and a future
    /// lexicon-loading change would land on). No overload can return text.
    static func verdict(spokenText: String,
                        locale: String,
                        lexicons: Result<Lexicons, LexiconLoadFailure>) -> GrammarGuardVerdict {
        guard isNepaliLocale(locale) else {
            return .unavailable(reason: GrammarGuardUnavailableReason.localeNotNepali.rawValue)
        }
        let tables: Lexicons
        switch lexicons {
        case .success(let loaded): tables = loaded
        case .failure:
            return .unavailable(reason: GrammarGuardUnavailableReason.lexiconsUnavailable.rawValue)
        }
        if case .declined(let reason) = inputClass(of: spokenText) {
            return .unavailable(reason: reason.rawValue)
        }
        let tokens = tokenize(spokenText)
        var classes: [GrammarCheckClass] = []
        if honorificViolation(in: tokens, lexicons: tables) {
            classes.append(.honorificAgreement)
        }
        if purityViolation(in: spokenText, tokens: tokens, lexicons: tables) {
            classes.append(.devanagariPurity)
        }
        if particleViolation(in: tokens, lexicons: tables) {
            classes.append(.danglingParticle)
        }
        return classes.isEmpty ? .pass : .flag(classes: classes)
    }

    // MARK: - The compiled lexicons (decoded from the embedded spec blocks)

    /// The guard's compiled data tables. Every value is decoded from the
    /// embedded, byte-verbatim spec blocks — the tables ARE the spec bytes,
    /// not a transcription of them (T-170's drift check compares the
    /// embedded literals with the spec's block bodies byte-for-byte).
    struct Lexicons: Equatable {

        struct CodeSwitchNoun: Equatable {
            let english: String
            let spoken: String
        }

        // register (the honorificAgreement class's data)
        let addressPronoun: String
        let attentionMarker: String
        /// familiar form → its honorific partner (`register.honorific_pairs`):
        /// the reference for what the honorific partner of a familiar form is
        /// (the register section's words). Carried and structure-validated;
        /// the executable flag set does not gate on it (the banned list is
        /// the curated flag set, checked exactly as the eval checks it).
        let honorificPartners: [String: String]
        /// `register.forbidden_address_forms` — the तिमी-family class.
        let forbiddenAddressForms: [String]
        /// `register.non_honorific_verb_forms` — the curated banned list.
        let nonHonorificVerbForms: [String]

        // particles (the danglingParticle class's data)
        let particleBudget: Int
        /// The spec's lexicon, validated longest-match-first (design §7.2):
        /// the first matching unit wins, so "हुन्छ नि" counts once.
        let particleUnits: [String]

        // code_switch (the devanagariPurity class's allowance property)
        let codeSwitchNouns: [CodeSwitchNoun]

        // guard_checks
        /// The Latin-token allowlist — empty in the shipped spec, because
        /// the code-switched nouns are Devanagari renderings and need no
        /// exception (validated at compile).
        let latinAllowlist: [String]
        /// The spec's check-inventory ids (design §7.2's three checks).
        let checkInventory: [String]

        /// The honorific check's flag set: the address class plus the curated
        /// banned verb list — exactly the set the eval's `honorific_violations`
        /// checks (one rule, two execution sites; the register section: "the
        /// guard and the eval check exactly that set"). The ambiguous forms
        /// भयो and छ stay in the pair table but out of the banned list, so they
        /// are not flagged.
        var honorificFlagSet: Set<String> {
            Set(forbiddenAddressForms).union(nonHonorificVerbForms)
        }
    }

    /// A lexicon compile/validation failure. Content-free by construction:
    /// block and field names only, never reply text. `verdict` maps any
    /// failure to `.unavailable(reason: "lexiconsUnavailable")`.
    enum LexiconLoadFailure: Error, Equatable {
        case malformedJSON(block: String, detail: String)
        case missingField(block: String, field: String)
        case invalidField(block: String, field: String, detail: String)
    }

    /// The load result the production entry point uses. Computed once and
    /// immutable — the guard holds no mutable state.
    static let compiledLexicons: Result<Lexicons, LexiconLoadFailure> = decodeLexicons(
        registerBlock: registerBlockJSON,
        particlesBlock: particlesBlockJSON,
        codeSwitchBlock: codeSwitchBlockJSON,
        guardChecksBlock: guardChecksBlockJSON)

    /// Compiles the data tables from the four block texts. Pure and total:
    /// any malformed input is a `LexiconLoadFailure`, never a default, and
    /// never a crash.
    static func decodeLexicons(registerBlock: String,
                               particlesBlock: String,
                               codeSwitchBlock: String,
                               guardChecksBlock: String) -> Result<Lexicons, LexiconLoadFailure> {
        do {
            return .success(try decodeLexiconsOrThrow(
                registerBlock: registerBlock,
                particlesBlock: particlesBlock,
                codeSwitchBlock: codeSwitchBlock,
                guardChecksBlock: guardChecksBlock))
        } catch let failure as LexiconLoadFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON(block: "lexicons",
                                           detail: "unexpected decode failure"))
        }
    }

    /// The throwing decoder behind `decodeLexicons` — the boundary is total,
    /// the internals are not.
    private static func decodeLexiconsOrThrow(registerBlock: String,
                                              particlesBlock: String,
                                              codeSwitchBlock: String,
                                              guardChecksBlock: String) throws -> Lexicons {
        let register = try jsonObject(registerBlock, block: "register")
        let particles = try jsonObject(particlesBlock, block: "particles")
        let codeSwitch = try jsonObject(codeSwitchBlock, block: "code_switch")
        let guardChecks = try jsonObject(guardChecksBlock, block: "guard_checks")

        let addressPronoun = try string(register["address_pronoun"],
                                        block: "register", field: "address_pronoun")
        let attentionMarker = try string(register["attention_marker"],
                                         block: "register", field: "attention_marker")
        let forbiddenAddressForms = try stringArray(register["forbidden_address_forms"],
                                                    block: "register",
                                                    field: "forbidden_address_forms",
                                                    allowEmpty: false)
        let nonHonorificVerbForms = try stringArray(register["non_honorific_verb_forms"],
                                                    block: "register",
                                                    field: "non_honorific_verb_forms",
                                                    allowEmpty: false)
        let honorificPartners = try honorificPairs(register["honorific_pairs"],
                                                   block: "register",
                                                   field: "honorific_pairs")

        let particleBudget = try nonNegativeInteger(particles["budget"],
                                                    block: "particles", field: "budget")
        let particleUnits = try stringArray(particles["units"],
                                            block: "particles", field: "units",
                                            allowEmpty: false)
        try validateLongestMatchOrder(particleUnits, block: "particles", field: "units")

        let codeSwitchNouns = try codeSwitchNounList(codeSwitch["nouns"],
                                                     block: "code_switch", field: "nouns")
        // The spec's code_switch section: the renderings are Devanagari, so
        // the purity check needs no Latin exception list. That property is
        // validated here — a spec that ever broke it degrades the guard
        // (unavailable) instead of false-flagging everyday nouns.
        for noun in codeSwitchNouns where !latinRuns(in: noun.spoken).isEmpty {
            throw LexiconLoadFailure.invalidField(
                block: "code_switch", field: "nouns",
                detail: "a code-switched rendering carries Latin letters; "
                    + "the no-exception property is broken")
        }

        let latinAllowlist = try stringArray(guardChecks["latin_allowlist"],
                                             block: "guard_checks",
                                             field: "latin_allowlist",
                                             allowEmpty: true)
        let checkIds = try checkEntries(guardChecks["checks"],
                                        block: "guard_checks", field: "checks")

        return Lexicons(addressPronoun: addressPronoun,
                        attentionMarker: attentionMarker,
                        honorificPartners: honorificPartners,
                        forbiddenAddressForms: forbiddenAddressForms,
                        nonHonorificVerbForms: nonHonorificVerbForms,
                        particleBudget: particleBudget,
                        particleUnits: particleUnits,
                        codeSwitchNouns: codeSwitchNouns,
                        latinAllowlist: latinAllowlist,
                        checkInventory: checkIds)
    }

    // MARK: - Decode helpers (block and field names only, never content)

    private static func jsonObject(_ text: String,
                                   block: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else {
            throw LexiconLoadFailure.malformedJSON(block: block, detail: "not UTF-8")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LexiconLoadFailure.malformedJSON(block: block, detail: "not valid JSON")
        }
        guard let dictionary = object as? [String: Any] else {
            throw LexiconLoadFailure.malformedJSON(block: block,
                                                   detail: "top level is not an object")
        }
        return dictionary
    }

    private static func string(_ value: Any?,
                               block: String,
                               field: String) throws -> String {
        guard let value = value else {
            throw LexiconLoadFailure.missingField(block: block, field: field)
        }
        guard let string = value as? String, !string.isEmpty else {
            throw LexiconLoadFailure.invalidField(block: block, field: field,
                                                  detail: "expected a non-empty string")
        }
        return string
    }

    private static func stringArray(_ value: Any?,
                                    block: String,
                                    field: String,
                                    allowEmpty: Bool) throws -> [String] {
        guard let value = value else {
            throw LexiconLoadFailure.missingField(block: block, field: field)
        }
        guard let entries = value as? [Any], allowEmpty || !entries.isEmpty else {
            throw LexiconLoadFailure.invalidField(
                block: block, field: field,
                detail: allowEmpty ? "expected a list of strings"
                                   : "expected a non-empty list of strings")
        }
        var strings: [String] = []
        for entry in entries {
            guard let string = entry as? String, !string.isEmpty else {
                throw LexiconLoadFailure.invalidField(
                    block: block, field: field,
                    detail: "an entry is not a non-empty string")
            }
            strings.append(string)
        }
        return strings
    }

    private static func nonNegativeInteger(_ value: Any?,
                                           block: String,
                                           field: String) throws -> Int {
        guard let value = value else {
            throw LexiconLoadFailure.missingField(block: block, field: field)
        }
        guard let number = value as? NSNumber, !isBoolean(number) else {
            throw LexiconLoadFailure.invalidField(block: block, field: field,
                                                  detail: "expected a number")
        }
        let integer = number.intValue
        guard integer >= 0, Double(integer) == number.doubleValue else {
            throw LexiconLoadFailure.invalidField(
                block: block, field: field,
                detail: "expected a non-negative integer")
        }
        return integer
    }

    /// JSONSerialization wraps `true`/`false` as CFBoolean, which bridges to
    /// NSNumber (and to Int as 1/0) — a boolean is not a number here.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func honorificPairs(_ value: Any?,
                                       block: String,
                                       field: String) throws -> [String: String] {
        guard let value = value else {
            throw LexiconLoadFailure.missingField(block: block, field: field)
        }
        guard let rawPairs = value as? [Any], !rawPairs.isEmpty else {
            throw LexiconLoadFailure.invalidField(
                block: block, field: field,
                detail: "expected a non-empty list of [familiar, honorific] pairs")
        }
        var partners: [String: String] = [:]
        for rawPair in rawPairs {
            guard let pair = rawPair as? [Any], pair.count == 2,
                  let familiar = pair[0] as? String, !familiar.isEmpty,
                  let honorific = pair[1] as? String, !honorific.isEmpty else {
                throw LexiconLoadFailure.invalidField(
                    block: block, field: field,
                    detail: "an entry is not a [familiar, honorific] pair "
                        + "of non-empty strings")
            }
            guard partners[familiar] == nil else {
                throw LexiconLoadFailure.invalidField(
                    block: block, field: field,
                    detail: "a familiar form is paired twice")
            }
            partners[familiar] = honorific
        }
        return partners
    }

    private static func codeSwitchNounList(_ value: Any?,
                                           block: String,
                                           field: String) throws -> [Lexicons.CodeSwitchNoun] {
        guard let value = value else {
            throw LexiconLoadFailure.missingField(block: block, field: field)
        }
        guard let rawNouns = value as? [Any], !rawNouns.isEmpty else {
            throw LexiconLoadFailure.invalidField(
                block: block, field: field,
                detail: "expected a non-empty list of noun entries")
        }
        var nouns: [Lexicons.CodeSwitchNoun] = []
        for rawNoun in rawNouns {
            guard let entry = rawNoun as? [String: Any] else {
                throw LexiconLoadFailure.invalidField(block: block, field: field,
                                                      detail: "an entry is not an object")
            }
            let english = try string(entry["english"], block: block,
                                     field: "nouns[].english")
            let spoken = try string(entry["spoken"], block: block,
                                    field: "nouns[].spoken")
            nouns.append(Lexicons.CodeSwitchNoun(english: english, spoken: spoken))
        }
        return nouns
    }

    private static func checkEntries(_ value: Any?,
                                     block: String,
                                     field: String) throws -> [String] {
        guard let value = value else {
            throw LexiconLoadFailure.missingField(block: block, field: field)
        }
        guard let rawChecks = value as? [Any], !rawChecks.isEmpty else {
            throw LexiconLoadFailure.invalidField(
                block: block, field: field,
                detail: "expected a non-empty list of check entries")
        }
        var ids: [String] = []
        for rawCheck in rawChecks {
            guard let entry = rawCheck as? [String: Any],
                  let id = entry["id"] as? String, !id.isEmpty else {
                throw LexiconLoadFailure.invalidField(
                    block: block, field: field,
                    detail: "a check entry has no string id")
            }
            ids.append(id)
        }
        return ids
    }

    /// The spec's stated lexicon property, executed: word count descending,
    /// then character count descending (the same measure the loader
    /// validates at source — Python `len()` counts scalars, so
    /// `unicodeScalars.count` is the aligned length). Ties may appear in any
    /// order; a violation means longest-match tokenization cannot be
    /// trusted, so the guard declines rather than miscounts.
    private static func validateLongestMatchOrder(_ units: [String],
                                                  block: String,
                                                  field: String) throws {
        func key(_ unit: String) -> (Int, Int) {
            (unit.split(whereSeparator: { $0.isWhitespace }).count,
             unit.unicodeScalars.count)
        }
        for (left, right) in zip(units, units.dropFirst()) where key(left) < key(right) {
            throw LexiconLoadFailure.invalidField(
                block: block, field: field,
                detail: "units are not longest-match-first")
        }
    }

    // MARK: - The embedded spec blocks (byte-verbatim; T-170's mirror gate)

    /// @style-spec-section: guard_checks
    /// Executable inputs for the runtime grammar guard and the eval's deterministic checkers. The lexicons are NOT restated here: honorific agreement reads the register block, the particle check reads the particles block, the AI-ism check reads the ai_isms block and the code-switch allowance reads the code_switch block. This section adds only what those blocks do not carry: the check inventory with its sources, and the Latin-token allowlist (empty by default — code-switched nouns are Devanagari renderings and pass the script check without an exception).
    /// @style-spec-section-end: guard_checks

    // @style-spec-block: register
    /// The style spec's `register` machine block, embedded byte-verbatim:
    /// the literal value is the block body (Swift dedents by the closing
    /// delimiter's indentation; the newline before it is not part of the
    /// value). `compiledLexicons` decodes this text; T-170's mirror check
    /// compares it against the spec block byte-for-byte.
    static let registerBlockJSON = """
    {
      "address_pronoun": "तपाईं",
      "attention_marker": "हजुर",
      "honorific_pairs": [
        ["भन्यो", "भन्नुभयो"],
        ["गर्यो", "गर्नुभयो"],
        ["खायो", "खानुभयो"],
        ["पियो", "पिउनुभयो"],
        ["हेर्यो", "हेर्नुभयो"],
        ["लियो", "लिनुभयो"],
        ["दियो", "दिनुभयो"],
        ["आयो", "आउनुभयो"],
        ["गयो", "जानुभयो"],
        ["सुत्यो", "सुत्नुभयो"],
        ["सक्यो", "सक्नुभयो"],
        ["भयो", "हुनुभयो"],
        ["छ", "हुनुहुन्छ"],
        ["गर्छ", "गर्नुहुन्छ"],
        ["खान्छ", "खानुहुन्छ"],
        ["आउँछ", "आउनुहुन्छ"],
        ["जान्छ", "जानुहुन्छ"]
      ],
      "non_honorific_verb_forms": ["भन्यो", "गर्यो", "खायो", "पियो", "हेर्यो", "लियो", "दियो", "आयो", "गयो", "सुत्यो", "सक्यो"],
      "forbidden_address_forms": ["तँ", "तलाई", "तँलाई", "तेरो", "तेरी", "तिमी", "तिमीलाई", "तिम्रो", "तिम्री", "तिम्रा", "तिमीहरू"]
    }
    """
    // @style-spec-block-end: register

    // @style-spec-block: particles
    /// The style spec's `particles` machine block, embedded byte-verbatim.
    static let particlesBlockJSON = """
    {
      "budget": 1,
      "units": ["हुन्छ नि", "होला नि", "हो नि", "छ नि", "अनि", "है", "नि", "ला", "ल"],
      "longest_match_first": true
    }
    """
    // @style-spec-block-end: particles

    // @style-spec-block: code_switch
    /// The style spec's `code_switch` machine block, embedded byte-verbatim.
    static let codeSwitchBlockJSON = """
    {
      "nouns": [
        {"english": "blood pressure", "spoken": "प्रेसर", "gloss": "the cuff reading; not the literary रक्तचाप in speech"},
        {"english": "doctor", "spoken": "डाक्टर", "gloss": "the person they visit"},
        {"english": "medicine", "spoken": "मेडिसिन", "gloss": "the pills and doses"},
        {"english": "phone", "spoken": "फोन", "gloss": "the mobile phone"},
        {"english": "charger", "spoken": "चार्जर", "gloss": "the phone charger"},
        {"english": "video call", "spoken": "भिडियो कल", "gloss": "the call kind they ask for by name"}
      ],
      "mirror_user_register": true
    }
    """
    // @style-spec-block-end: code_switch

    // @style-spec-block: guard_checks
    /// The style spec's `guard_checks` machine block, embedded byte-verbatim.
    static let guardChecksBlockJSON = """
    {
      "checks": [
        {"id": "honorificAgreement", "sources": ["register.forbidden_address_forms", "register.non_honorific_verb_forms", "register.honorific_pairs"]},
        {"id": "devanagariPurity", "sources": ["guard_checks.latin_allowlist", "code_switch.nouns"]},
        {"id": "danglingParticle", "sources": ["particles.units", "particles.budget"]}
      ],
      "latin_allowlist": []
    }
    """
    // @style-spec-block-end: guard_checks

    // MARK: - The checks (design-l1 §7.2)

    /// @style-spec-section: register
    /// Address the elder with तपाईं and honorific verb agreement at all times — भन्नुभयो, गर्नुभयो, खानुभयो, हुनुहुन्छ — and use हजुर as the polite attention marker. Never use तिमी, तँ or their possessive forms (तिम्रो, तेरो) toward the elder, and never use the familiar finite verb forms in the banned list as standalone tokens: each has an honorific partner in the pair table and the reply must use that partner.
    ///
    /// The pair table is the reference for what the honorific partner of a familiar form is. The banned list is the curated flag set (familiar past-tense forms whose subject could only be the elder): the guard and the eval check exactly that set. Forms outside the curated pairs are NOT caught — this is the honest bound of a lexicon check, not a grammar prover. The ambiguous forms भयो and छ stay in the pair table but out of the banned list, because they also occur in speaker-side and neutral sentences.
    ///
    /// Respect applies when speaking ABOUT the elder's people too: a reply about their family uses the same respectful forms. First-person forms about yourself (म, गर्छु, भन्छु) are unaffected.
    /// @style-spec-section-end: register

    /// Flag when any token equals a `forbidden_address_forms` form (the
    /// तिमी-family address class) or a `non_honorific_verb_forms` form (the
    /// familiar finite-verb class) — exact token membership, the same two
    /// data classes the eval checks. It is lexicon-bounded by design: forms
    /// outside the curated list are NOT caught (the honest limit of a
    /// lexicon check, not a grammar prover — the register section's words).
    private static func honorificViolation(in tokens: [Token],
                                           lexicons: Lexicons) -> Bool {
        let flagged = lexicons.honorificFlagSet
        return tokens.contains { flagged.contains($0.text) }
    }

    /// @style-spec-section: code_switch
    /// Health and technology nouns stay as the elder actually speaks them: the Devanagari rendering of the English word, never the bare Latin spelling and never a literary translation. प्रेसर, डाक्टर, मेडिसिन, फोन, चार्जर are the everyday forms. Mirror the elder's own register: if they say प्रेसर, the reply says प्रेसर. Because the renderings are Devanagari, a Nepali reply needs no Latin-token exception list (the guard's Latin allowlist is empty); a bare Latin token in a Nepali reply is a defect.
    /// @style-spec-section-end: code_switch

    /// Flag Latin-letter runs that are not in the spec's allowlist, and
    /// mixed-script tokens outright. Script classification only — not a
    /// spell checker. A Latin-free Devanagari token always passes, which is
    /// exactly why the code-switched nouns (Devanagari renderings) need no
    /// exception list; the empty allowlist is the spec's, decoded not
    /// hard-coded.
    private static func purityViolation(in text: String,
                                        tokens: [Token],
                                        lexicons: Lexicons) -> Bool {
        for token in tokens where isMixedScript(token.text) {
            return true
        }
        let allowed = Set(lexicons.latinAllowlist)
        return latinRuns(in: text).contains { !allowed.contains($0) }
    }

    /// @style-spec-section: particles
    /// Use at most ONE particle per reply — overuse is a failure, not a style. The particle set is है, नि, ल, ला, अनि, हुन्छ नि. A particle is a gentle human marker: है a soft tag, नि emphasis or a check-in question tag ("औषधि खानुभयो नि?"), ल and ला softening, अनि continuation, हुन्छ नि a warm confirmation tag. Never stack particles, and never open a reply with one: a particle with no clause to attach to (the first token of the reply, or one following only a sentence terminator) is dangling and reads as noise.
    ///
    /// Multi-word units match as ONE occurrence — "हुन्छ नि" counts once, not twice — so the lexicon is matched longest-first and the multi-word units are listed before the single words that also occur inside them. When in doubt, use none: a reply with zero particles is always grammatical, a reply with two never is.
    /// @style-spec-section-end: particles

    /// Flag more occurrences than the spec's budget, or a dangling clitic.
    /// Occurrences are counted longest-match-first over the spec's lexicon
    /// ("हुन्छ नि" counts once; the contained "नि" is not double-counted),
    /// and the positional rule is the spec's: a particle with no clause to
    /// attach to — the first token of the reply, or one following only a
    /// sentence terminator — is dangling. A multi-word unit carries its own
    /// clause head ("हुन्छ नि" — हुन्छ is the clause), so only a one-token
    /// clitic can be positionally dangling (the shipped golden replies open
    /// with "हुन्छ नि" and never with a bare clitic — the boundary this rule
    /// encodes). The unit holds together only inside one clause: a sentence
    /// terminator between its words means the run is not the tag
    /// ("हुन्छ। नि" is not "हुन्छ नि"), so the later word is judged on its
    /// own position and flags as a dangling clitic.
    private static func particleViolation(in tokens: [Token],
                                          lexicons: Lexicons) -> Bool {
        var count = 0
        var index = 0
        while index < tokens.count {
            guard let parts = particleMatch(at: index, in: tokens,
                                            units: lexicons.particleUnits) else {
                index += 1
                continue
            }
            count += 1
            if isDangling(parts: parts, at: index, in: tokens) {
                return true
            }
            index += parts.count
        }
        return count > lexicons.particleBudget
    }

    /// The word parts of the first (longest — the lexicon is validated
    /// longest-first) unit matching the token run at `index`. A multi-word
    /// unit must be contiguous inside one clause: a sentence terminator in
    /// the gap between its words breaks the run (the eval's sentence
    /// boundaries, the same `_SENTENCE_SPLIT_RE` class the dangling rule
    /// reads), so "हुन्छ। नि" never matches "हुन्छ नि" and the "नि" is then
    /// judged — and flagged — on its own position.
    private static func particleMatch(at index: Int,
                                      in tokens: [Token],
                                      units: [String]) -> [String]? {
        for unit in units {
            let parts = unit.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard index + parts.count <= tokens.count else { continue }
            var matches = true
            for offset in 0..<parts.count where tokens[index + offset].text != parts[offset] {
                matches = false
                break
            }
            if matches && parts.count > 1 {
                for offset in 1..<parts.count
                where tokens[index + offset].precedingGap.contains(where: sentenceTerminators.contains) {
                    matches = false
                    break
                }
            }
            if matches {
                return parts
            }
        }
        return nil
    }

    /// The spec's positional rule, applied to the matched occurrence: only a
    /// one-token clitic can be positionally dangling.
    private static func isDangling(parts: [String],
                                   at index: Int,
                                   in tokens: [Token]) -> Bool {
        guard parts.count == 1 else { return false }
        if index == 0 { return true }
        return tokens[index].precedingGap.contains { sentenceTerminators.contains($0) }
    }

    /// The sentence enders the eval's sentence splitter uses
    /// (author_chat_golden.py `_SENTENCE_SPLIT_RE` = "[।॥!?\n]+") — the two
    /// execution sites count sentences over the same boundaries, so the
    /// dangling rule reads the same text the same way.
    private static let sentenceTerminators: Set<Character> = ["।", "॥", "!", "?", "\n"]

    // MARK: - Input classification (design-l1 §7.1's locale, §7.2's script)

    private enum InputClass {
        case judgeable
        case declined(GrammarGuardUnavailableReason)
    }

    /// The guard judges Devanagari replies: the first Devanagari letter makes
    /// a reply judgeable (a mixed reply is judged — its Latin runs are the
    /// purity check's evidence). Latin letters without Devanagari are a
    /// romanized/English reply — declined, never flagged (FR-CNR-027's seam);
    /// no letters at all is nothing to verify. The boundary is pinned by
    /// test.
    private static func inputClass(of text: String) -> InputClass {
        var sawLatin = false
        for scalar in text.unicodeScalars {
            if isDevanagariLetter(scalar) { return .judgeable }
            if isLatinLetter(scalar) { sawLatin = true }
        }
        let reason: GrammarGuardUnavailableReason =
            sawLatin ? .inputNotDevanagari : .inputEmpty
        return .declined(reason)
    }

    /// The locale's language subtag must be `ne` — "ne", "ne-NP" and
    /// "ne_Latn" are Nepali sessions; anything else ("en", "") declines. The
    /// Nepali register is not another session's contract, and judging it
    /// anyway would be a false verdict. Total: never throws, never guesses.
    private static func isNepaliLocale(_ locale: String) -> Bool {
        let normalized = locale
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let language = normalized.split(separator: "-").first.map(String.init) ?? ""
        return language == "ne"
    }

    /// The Devanagari block (U+0900–U+097F), letters only: digits, danda and
    /// signs are not letters; the block is the classification bound.
    private static func isDevanagariLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard (0x0900...0x097F).contains(scalar.value) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    /// ASCII A–Z/a–z — the same class the eval's `_LATIN_RUN_RE` ("[A-Za-z]+")
    /// matches, so the two execution sites agree on what a Latin run is.
    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value)
    }

    /// A token carrying both scripts (e.g. "चार्जer") is a mixed-script
    /// defect on its own evidence, allowlist or not.
    private static func isMixedScript(_ token: String) -> Bool {
        var sawDevanagari = false
        var sawLatin = false
        for scalar in token.unicodeScalars {
            if isDevanagariLetter(scalar) { sawDevanagari = true }
            else if isLatinLetter(scalar) { sawLatin = true }
        }
        return sawDevanagari && sawLatin
    }

    /// Every maximal ASCII-Latin run in the text, in order — the eval's
    /// `_LATIN_RUN_RE.findall` over the same bytes.
    static func latinRuns(in text: String) -> [String] {
        var runs: [String] = []
        var run = ""
        for scalar in text.unicodeScalars {
            if isLatinLetter(scalar) {
                run.unicodeScalars.append(scalar)
            } else if !run.isEmpty {
                runs.append(run)
                run = ""
            }
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    // MARK: - Tokenization (the checks' shared, deterministic token rule)

    /// A word token plus the raw text between it and the previous token (the
    /// leading separators for the first token) — the dangling rule's
    /// positional evidence.
    struct Token: Equatable {
        let text: String
        let precedingGap: String
    }

    /// Whitespace/punctuation/symbol-separated word tokens, in order. The
    /// eval's simplified splitter (`_TOKEN_SPLIT_RE`) approximates this
    /// class, so the particle rules agree on realistic text.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var gap = ""
        for character in text {
            if isSeparator(character) {
                if current.isEmpty {
                    gap.append(character)
                } else {
                    tokens.append(Token(text: current, precedingGap: gap))
                    current = ""
                    gap = String(character)
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(Token(text: current, precedingGap: gap))
        }
        return tokens
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }
}
