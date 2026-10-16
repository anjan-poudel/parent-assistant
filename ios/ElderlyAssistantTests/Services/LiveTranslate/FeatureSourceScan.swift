import XCTest

/// Source-tree scanning for the checks that must fail when a **rule is
/// broken in code** rather than in behaviour: T-001's operational-literal
/// check, T-004's duplicated-marker-list check, T-005's copy check.
///
/// Paths come from `#filePath` — the one path the compiler guarantees — and
/// a failure to locate the sources is an explicit test failure, never a
/// silent pass (a scan that cannot read its inputs proves nothing).
enum FeatureSourceScan {

    static let liveTranslateSources = "ElderlyAssistant/Services/LiveTranslate"

    /// The `ios/` directory, found by walking up from a test file's own path
    /// until the production source root (`ios/ElderlyAssistant/`) is
    /// visible. Structure is verified, not assumed: the walk stops at the
    /// first ancestor that actually contains it.
    static func iosDirectory(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        var hops = 0
        while hops < 32 {
            var isDirectory: ObjCBool = false
            let candidate = url.appendingPathComponent("ElderlyAssistant")
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
            hops += 1
        }
        XCTFail("could not locate ios/ElderlyAssistant from \(file)")
        return URL(fileURLWithPath: "/dev/null")
    }

    /// Every `.swift` file under an `ios/`-relative directory, sorted for
    /// deterministic failure messages. Missing directory ⇒ explicit failure.
    static func swiftFiles(in relativeDirectory: String,
                           file: StaticString = #filePath) -> [URL] {
        let root = iosDirectory(file: file).appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else {
            XCTFail("no source directory at \(root.path)")
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        if files.isEmpty {
            XCTFail("no Swift sources under \(root.path)")
        }
        return files.sorted { $0.path < $1.path }
    }

    /// A file's text with comments removed and string literals preserved, so
    /// a documentation example is not mistaken for code and a code literal
    /// inside a string is still visible. Line structure is preserved (a
    /// block comment leaves its newlines behind) so line-oriented reporting
    /// stays honest.
    static func codeText(of url: URL) -> String {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("could not read \(url.path)")
            return ""
        }
        let characters = Array(source)
        var out = ""
        var index = 0
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var inMultilineString = false

        func peek(_ offset: Int) -> Character? {
            let i = index + offset
            return i < characters.count ? characters[i] : nil
        }

        while index < characters.count {
            let character = characters[index]

            if inLineComment {
                if character == "\n" { inLineComment = false; out.append(character) }
                index += 1
                continue
            }
            if inBlockComment {
                if character == "*", peek(1) == "/" { inBlockComment = false; index += 2; continue }
                if character == "\n" { out.append(character) }
                index += 1
                continue
            }
            if inMultilineString {
                if character == "\"", peek(1) == "\"", peek(2) == "\"" {
                    out.append("\"\"\""); inMultilineString = false; index += 3; continue
                }
                out.append(character)
                index += 1
                continue
            }
            if inString {
                out.append(character)
                if character == "\\", let next = peek(1) {
                    out.append(next); index += 2; continue
                }
                if character == "\"" { inString = false }
                index += 1
                continue
            }

            if character == "\"", peek(1) == "\"", peek(2) == "\"" {
                out.append("\"\"\""); inMultilineString = true; index += 3; continue
            }
            if character == "/", peek(1) == "/" { inLineComment = true; index += 2; continue }
            if character == "/", peek(1) == "*" { inBlockComment = true; index += 2; continue }
            if character == "\"" { inString = true; out.append(character); index += 1; continue }

            out.append(character)
            index += 1
        }
        return out
    }

    /// The `ios/`-relative path of a file, for readable failure messages.
    static func relativePath(of url: URL, file: StaticString = #filePath) -> String {
        let root = iosDirectory(file: file).path
        guard url.path.hasPrefix(root) else { return url.path }
        return String(url.path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    /// The first line in `text` matching `pattern`, or nil. Line numbers are
    /// 1-based, matching an editor.
    ///
    /// Each line is materialised as a `String` **before** its `NSRange` is
    /// taken: a `Substring`'s indices do not belong to the copy, and an
    /// `NSRange` built from the former and applied to the latter traps at
    /// run time (`NSRange(_:in:)` requires the view it was built from).
    static func firstMatch(of pattern: String,
                           in text: String) -> (line: Int, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return nil
        }
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineText = String(line)
            let range = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
            if regex.firstMatch(in: lineText, options: [], range: range) != nil {
                return (offset + 1, lineText)
            }
        }
        return nil
    }
}
