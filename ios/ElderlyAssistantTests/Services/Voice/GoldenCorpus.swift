import Foundation

/// Golden Nepali utterance corpus (spec §5.3).
///
/// Each entry pairs an utterance with its expected intent (snake_case raw
/// value matching `InterpretedCommand.Action`) and extracted entities.
/// Code-switched and dialectal variants are included deliberately — this
/// is the same set the fine-tuned STT will be evaluated against later
/// (slow/nightly E2E).
///
/// The corpus is a test fixture, not a shipped asset.
struct CorpusEntry {
    let utterance: String
    let intent: String
    let time: String?
    let medication: String?
    let contact: String?

    init(_ utterance: String, intent: String, time: String? = nil,
         medication: String? = nil, contact: String? = nil) {
        self.utterance = utterance
        self.intent = intent
        self.time = time
        self.medication = medication
        self.contact = contact
    }
}

enum GoldenCorpus {

    static let entries: [CorpusEntry] = ackMed + emergency + call + setReminder
        + healthQuery + music + query + none

    // MARK: - ack_med

    static let ackMed: [CorpusEntry] = [
        .init("औषधि खाएँ", intent: "ack_med"),
        .init("मैले औषधि लिइसकें", intent: "ack_med"),
        .init("औषधि खाइसकेँ", intent: "ack_med"),
        .init("दवाई खाएँ", intent: "ack_med"),
        .init("औषधी खाए", intent: "ack_med"),
        .init("मैले अहिले औषधि खाएँ", intent: "ack_med"),
        .init("मैले दबाइ लिएको छु", intent: "ack_med"),
        .init("मैले औषधि लिएको छु", intent: "ack_med"),
        .init("yes i took it", intent: "ack_med"),
        .init("I took my medication", intent: "ack_med"),
        .init("i've taken my medicine", intent: "ack_med"),
        .init("took my medicine", intent: "ack_med"),
        .init("खाइसकें औषधि", intent: "ack_med"),
        .init("लिइसकेँ दवाई", intent: "ack_med"),
        .init("औषधि लिइयो", intent: "ack_med"),
    ]

    // MARK: - emergency

    static let emergency: [CorpusEntry] = [
        .init("साहयता चाहियो", intent: "emergency"),
        .init("इमर्जेन्सी", intent: "emergency"),
        .init("मलाई साहयता चाहिएको छ", intent: "emergency"),
        .init("छिटो आउनुहोस्", intent: "emergency"),
        .init("म बिरामी छु, साहयता चाहियो", intent: "emergency"),
        .init("help", intent: "emergency"),
        .init("emergency", intent: "emergency"),
        .init("मलाई तुरुन्तै मद्दत चाहियो", intent: "emergency"),
        .init("अहिले नै साहयता पठाउनुहोस्", intent: "emergency"),
        .init("म लडें, साहयता चाहियो", intent: "emergency"),
        .init("तुरुन्तै साहयता", intent: "emergency"),
        .init("सास फेर्न गाह्रो भयो", intent: "emergency"),
        .init("छाती दुखेको छ, साहयता चाहियो", intent: "emergency"),
        .init("मद्दत", intent: "emergency"),
        .init("जल्दी मद्दत गर्नुहोस्", intent: "emergency"),
    ]

    // MARK: - call

    static let call: [CorpusEntry] = [
        .init("छोरालाई फोन गर", intent: "call", contact: "छोरा"),
        .init("फोन गर", intent: "call"),
        .init("छोरीलाई फोन गरिदेऊ", intent: "call", contact: "छोरी"),
        .init("भाइलाई कल गर", intent: "call", contact: "भाइ"),
        .init("मेरो छोरालाई फोन", intent: "call", contact: "छोरा"),
        .init("call my son", intent: "call", contact: "son"),
        .init("फोन लगाऊ", intent: "call"),
        .init("म्यासेन्जरमा फोन गर", intent: "call"),
        .init("व्हाट्सएपमा कल गर", intent: "call"),
        .init("भिडियो कल गर", intent: "call"),
        .init("रामलाई फोन गर्नुस्", intent: "call", contact: "राम"),
        .init("नातिलाई फोन गर", intent: "call", contact: "नाति"),
        .init("फोन लगाइदिनु", intent: "call"),
        .init("मेरो परिवारलाई कल गर", intent: "call", contact: "परिवार"),
        .init("फोन नम्बर लगाऊ", intent: "call"),
    ]

    // MARK: - set_reminder

    static let setReminder: [CorpusEntry] = [
        .init("बिहान ८ बजे औषधि खान सम्झाउनु", intent: "set_reminder",
              time: "बिहान ८ बजे", medication: "औषधि"),
        .init("बेलुका ७ बजे सम्झाउनुहोस्", intent: "set_reminder", time: "बेलुका ७ बजे"),
        .init("दिउँसो २ बजे प्रेसरको औषधि सम्झाउनु", intent: "set_reminder",
              time: "दिउँसो २ बजे", medication: "प्रेसरको औषधि"),
        .init("राति ९ बजे औषधि खान भन्नु", intent: "set_reminder",
              time: "राति ९ बजे", medication: "औषधि"),
        .init("८ बजे सम्झाउनु", intent: "set_reminder", time: "८ बजे"),
        .init("साढे ८ मा सम्झाउनु", intent: "set_reminder", time: "साढे ८"),
        .init("remind me at 8 am", intent: "set_reminder", time: "8 am"),
        .init("बिहान ६ बजे उठाउनु", intent: "set_reminder", time: "बिहान ६ बजे"),
        .init("१० बजे औषधि सम्झाउनु", intent: "set_reminder",
              time: "१० बजे", medication: "औषधि"),
        .init("दिउँसो १२ बजे खाना खान सम्झाउनु", intent: "set_reminder",
              time: "दिउँसो १२ बजे"),
        .init("साँझ ५ बजे सम्झाउनु", intent: "set_reminder", time: "साँझ ५ बजे"),
        .init("भोलि बिहान ७ बजे सम्झाउनु", intent: "set_reminder", time: "बिहान ७ बजे"),
        .init("अब १० मिनेटपछि सम्झाउनु", intent: "set_reminder", time: "अब"),
        .init("8:30 मा सम्झाउनु", intent: "set_reminder", time: "8:30"),
        .init("बिहान ८॥३० मा औषधि सम्झाउनु", intent: "set_reminder",
              time: "बिहान ८॥३०", medication: "औषधि"),
    ]

    // MARK: - health_query

    static let healthQuery: [CorpusEntry] = [
        .init("मेरो प्रेसर कति छ", intent: "health_query"),
        .init("मेरो स्वास्थ्य कस्तो छ", intent: "health_query"),
        .init("रक्तचाप जाँच गर", intent: "health_query"),
        .init("मेरो मुटुको धड्कन कति छ", intent: "health_query"),
        .init("मलाई ज्वरो छ कि", intent: "health_query"),
        .init("मेरो तौल कति भयो", intent: "health_query"),
        .init("सुगर लेभल कति छ", intent: "health_query"),
        .init("check my heart rate", intent: "health_query"),
        .init("how is my health", intent: "health_query"),
        .init("म आज कति हिँडें", intent: "health_query"),
        .init("मेरो अक्सिजन लेभल कति छ", intent: "health_query"),
        .init("मलाई चक्कर लाग्यो", intent: "health_query"),
        .init("मेरो रगतमा चिनी कति छ", intent: "health_query"),
        .init("मेरो औषधिको असर कस्तो छ", intent: "health_query"),
        .init("कति पानी पिउनुपर्छ", intent: "health_query"),
    ]

    // MARK: - music

    static let music: [CorpusEntry] = [
        .init("भजन बजाउनुस्", intent: "music"),
        .init("गीत चलाऊ", intent: "music"),
        .init("रामायणको भजन लगाइदेऊ", intent: "music"),
        .init("गाना बजाऊ", intent: "music"),
        .init("कुनै भजन सुनाऊ", intent: "music"),
        .init("शिवको भजन बजाऊ", intent: "music"),
        .init("नयाँ गीत सुनाउनुस्", intent: "music"),
        .init("play a song", intent: "music"),
        .init("पुरानो हिन्दी गीत बजाऊ", intent: "music"),
        .init("भजन गाउनुस्", intent: "music"),
        .init("संगीत बजाऊ", intent: "music"),
        .init("लोक गीत सुनाऊ", intent: "music"),
        .init("देवीको भजन", intent: "music"),
        .init("कृष्ण भजन बजाऊ", intent: "music"),
        .init("गीत सुनाउनुस्", intent: "music"),
    ]

    // MARK: - query

    static let query: [CorpusEntry] = [
        .init("भोलि मौसम कस्तो छ", intent: "query"),
        .init("आज कति बजे छ", intent: "query"),
        .init("मौसम कस्तो छ", intent: "query"),
        .init("भोलि पानी पर्छ कि", intent: "query"),
        .init("आजको खबर सुनाऊ", intent: "query"),
        .init("काठमाडौंको मौसम कस्तो छ", intent: "query"),
        .init("what time is it", intent: "query"),
        .init("मलाई कथा सुनाऊ", intent: "query"),
        .init("नेपालको राजधानी के हो", intent: "query"),
        .init("भोलि चाड के हो", intent: "query"),
        .init("मेरो उमेर कति भयो", intent: "query"),
        .init("आज कुन दिन हो", intent: "query"),
        .init("हजुरबुबाको कथा", intent: "query"),
        .init("दशैं कहिले हो", intent: "query"),
        .init("अहिले कुन मौसम हो", intent: "query"),
    ]

    // MARK: - none

    static let none: [CorpusEntry] = [
        .init("नमस्ते", intent: "none"),
        .init("धन्यवाद", intent: "none"),
        .init("ठीक छ", intent: "none"),
        .init("हस", intent: "none"),
        .init("ल ल", intent: "none"),
        .init("मलाई भोक लाग्यो", intent: "none"),
        .init("आज धेरै गर्मी छ", intent: "none"),
        .init("म छोराको कुरा गर्दै थिएँ", intent: "none"),
        .init("hello", intent: "none"),
        .init("हुन्छ", intent: "none"),
        .init("मलाई निद्रा लाग्यो", intent: "none"),
        .init("केही छैन", intent: "none"),
        .init("छोरा आउँदैछ", intent: "none"),
        .init("आज बजार गएँ", intent: "none"),
        .init("राम्रो", intent: "none"),
    ]
}
