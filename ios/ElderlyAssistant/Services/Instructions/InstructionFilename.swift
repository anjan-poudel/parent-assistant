/// The one bare-filename rule the instruction feature uses (design L2
/// §3.4, §3.5; must-carry N-1 and N-4).
///
/// The rule is deliberately identical to the shipping image stores'
/// `isPlainFilename` (`VisualAidStore`, `ContactPhotoStore`): a name is one
/// non-empty path component, never `.` or `..`, and never contains either
/// separator. It runs *before* any URL is built from a payload-supplied
/// name. The non-empty clause is the safety-critical one:
/// `URL.appendingPathComponent("")` resolves to the owner directory, so a
/// guard without it would let a delete remove every live byte in the owner's
/// folder.
///
/// The model itself never sanitises (design §4.1 rule 2); the video store
/// and the image loaders are the security boundary that calls this.
enum InstructionFilename {
    /// `true` only for a plain, traversal-free single path component.
    static func isPlain(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }

    /// 1–8 lowercase alphanumerics, else `"mov"` (design §3.4, §9.3). The
    /// input is lowercased first, so a recorder's `"MOV"` keeps its
    /// extension instead of collapsing to the fallback.
    static func sanitizedExtension(_ ext: String) -> String {
        let lowered = ext.lowercased()
        guard (1...8).contains(lowered.count),
              lowered.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return "mov"
        }
        return lowered
    }
}
