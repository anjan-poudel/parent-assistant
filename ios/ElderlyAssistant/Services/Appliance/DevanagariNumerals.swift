import Foundation

/// Western numerals → Devanagari numerals ("0"–"9" → "०"–"९") for the
/// step badges in the Nepali locale. (BikramSambat carries a private
/// copy for calendar dates; this is the appliance UI's own tiny pure
/// helper so the view layer never reaches into the calendar service.)
enum DevanagariNumerals {

    private static let digits: [Character] = Array("०१२३४५६७८९")

    /// "7" → "७", "14" → "१४", "2083" → "२०८३". Negative values keep an
    /// ASCII minus sign (step numbers are never negative; the sign path
    /// exists so the helper is total over Int).
    static func string(_ value: Int) -> String {
        let text = String(value)
        let sign = text.hasPrefix("-") ? "-" : ""
        let magnitude = sign.isEmpty ? text : String(text.dropFirst())
        return sign + String(magnitude.map { digits[Int(String($0))!] })
    }
}
