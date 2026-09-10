import SwiftUI
import UIKit

/// Caches that keep repeatable, expensive work OUT of view evaluation
/// (design review P2 — `docs/ios-swiftui-startup-review.md`,
/// §"Remove repeated work from view evaluation").
///
/// Two kinds of repeated work showed up in view bodies: constructing a
/// `DateFormatter` per row per render, and reading + fully decoding an
/// image file per row per render. Both are pure functions of their
/// inputs, so both are cached here — keyed by the input that changes the
/// answer (the locale, or the image plus its rendered size) and BOUNDED,
/// so a long session cannot grow memory without limit.
///
/// Neither cache is a data store: every entry is derivable from disk or
/// locale at any moment, so an eviction is always safe and a miss always
/// re-derives.

// MARK: - Locale-keyed formatters

/// `DateFormatter` construction is expensive enough to show up in a
/// scroll trace, and a view that builds one per row per body evaluation
/// builds the same formatter hundreds of times for the same answer. The
/// app only ever asks for the ACTIVE locale's formatters, so one instance
/// per (kind, locale) is all that is ever needed.
///
/// Thread safety: `DateFormatter` is safe to *format* from multiple
/// threads (since iOS 7), and the dictionaries here are guarded by a
/// lock so a background test or an off-main caller cannot interleave a
/// read with a write.
enum LocaleFormatters {

    private static let lock = NSLock()
    private static var shortDates: [String: DateFormatter] = [:]
    private static var shortTimes: [String: DateFormatter] = [:]
    private static var weekdaySymbolLists: [String: [String]] = [:]

    /// Short localized date, no time ("12 Sep 2026" / "१२ भदौ").
    static func shortDate(locale: Locale) -> DateFormatter {
        cached(in: &shortDates, locale: locale) { formatter in
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
    }

    /// Short localized time of day, no date ("7:00 AM").
    static func shortTime(locale: Locale) -> DateFormatter {
        cached(in: &shortTimes, locale: locale) { formatter in
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        }
    }

    /// The locale's short weekday symbols, indexed from Sunday — the
    /// lookup a weekly routine's "Sun, Tue · 9:00 AM" summary needs.
    ///
    /// Built inside ONE critical section with its own formatter: the
    /// symbols could be read off the cached `shortDate` formatter, but
    /// `cached(in:)` takes this same non-recursive lock, so reaching for
    /// it here would deadlock the thread that first asks.
    static func shortWeekdaySymbols(locale: Locale) -> [String] {
        let key = cacheKey(for: locale)
        lock.lock()
        defer { lock.unlock() }
        if let cached = weekdaySymbolLists[key] { return cached }
        let symbols = makeFormatter(locale: locale) {
            $0.dateStyle = .short
            $0.timeStyle = .none
        }.shortWeekdaySymbols ?? []
        weekdaySymbolLists[key] = symbols
        return symbols
    }

    private static func cached(in store: inout [String: DateFormatter],
                               locale: Locale,
                               configure: (DateFormatter) -> Void) -> DateFormatter {
        let key = cacheKey(for: locale)
        lock.lock()
        defer { lock.unlock() }
        if let existing = store[key] { return existing }
        let formatter = makeFormatter(locale: locale, configure: configure)
        store[key] = formatter
        return formatter
    }

    /// One configured formatter. Never touches the lock — callers build
    /// inside their own critical section, so a cache lookup cannot
    /// re-enter it.
    private static func makeFormatter(locale: Locale,
                                      configure: (DateFormatter) -> Void) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        configure(formatter)
        return formatter
    }

    /// One key per locale identity — the identifier plus the calendar,
    /// so a device that switches its calendar mid-session cannot pin a
    /// formatter built for the old one.
    private static func cacheKey(for locale: Locale) -> String {
        "\(locale.identifier)|\(Calendar.current.identifier)"
    }
}

// MARK: - Bounded, downsampled image cache

/// The decoded-image cache behind the small circular thumbnails the app
/// draws (contact photos, manual diagrams).
///
/// Full-size decoded bitmaps are the app's largest easy memory win: a
/// 512×512 contact JPEG costs ~1 MB decoded, while the 44pt circle it is
/// drawn into needs ~0.07 MB. Everything cached here is therefore
/// downsampled to the size it is actually rendered at, and the cache is
/// bounded by both entry count and total cost, so scrolling a long list
/// can neither hitch on repeated decodes nor grow memory without limit.
final class DownsampledImageCache {

    static let shared = DownsampledImageCache()

    private let cache = NSCache<NSString, UIImage>()

    /// - Parameters:
    ///   - countLimit: maximum entries; well past any screen's row count.
    ///   - totalCostLimit: maximum bytes of DECODED image, so one huge
    ///     image cannot evict everything else or bloat the app.
    init(countLimit: Int = 96, totalCostLimit: Int = 12 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    /// The downsampled image for `key`, or nil when `load` produced
    /// nothing (a missing or unreadable file — callers fall back to
    /// their placeholder).
    ///
    /// - Parameters:
    ///   - key: identity of the SOURCE image (a file name, a bundled
    ///     resource name). The rendered size is folded in automatically,
    ///     so the same source drawn at two sizes caches two thumbnails.
    ///   - pointSize: the longest edge the image is drawn at, in points.
    ///   - displayScale: the screen scale to decode for.
    ///   - load: how to obtain the source image on a miss. Called at most
    ///     once per (key, size) — never on a hit.
    func thumbnail(forKey key: String,
                   pointSize: CGFloat,
                   displayScale: CGFloat,
                   load: () -> UIImage?) -> UIImage? {
        let pixelEdge = max(1, (pointSize * displayScale).rounded(.up))
        let cacheKey = "\(key)@\(Int(pixelEdge))" as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let source = load(),
              let thumb = Self.downsampled(source, maxPixelEdge: pixelEdge) else {
            return nil
        }
        cache.setObject(thumb, forKey: cacheKey, cost: Self.cost(of: thumb))
        return thumb
    }

    /// Drops every cached thumbnail (used by tests, and by the memory
    /// warning path in `ElderlyAssistantApp` if one is ever wired).
    func removeAll() {
        cache.removeAllObjects()
    }

    // MARK: Downsampling

    /// `image` re-rendered so its longest edge is at most `maxPixelEdge`
    /// PIXELS; never upscaled. Returns the image itself when it is
    /// already small enough, so a second render is not paid for nothing.
    static func downsampled(_ image: UIImage, maxPixelEdge: CGFloat) -> UIImage? {
        let pixelSize = CGSize(width: image.size.width * image.scale,
                               height: image.size.height * image.scale)
        let longestEdge = max(pixelSize.width, pixelSize.height)
        guard longestEdge > maxPixelEdge, longestEdge > 0 else { return image }

        let ratio = maxPixelEdge / longestEdge
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1                       // one output pixel per requested pixel
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: (pixelSize.width * ratio).rounded(),
                         height: (pixelSize.height * ratio).rounded()),
            format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero,
                                  size: CGSize(width: (pixelSize.width * ratio).rounded(),
                                               height: (pixelSize.height * ratio).rounded())))
        }
    }

    /// Decoded byte cost of a thumbnail — the number `NSCache` evicts by.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

// MARK: - Contact faces

extension DownsampledImageCache {

    /// The face thumbnail for a curated contact, at the diameter it is
    /// drawn — keyed by the STORED FILE, so the same person's face is
    /// decoded once for the whole app (the family list, the phone tiles,
    /// a search row) and every later draw is a memory hit.
    ///
    /// - Parameters:
    ///   - diameter: the circle's width in points.
    ///   - resolve: the coordinator's `contactPhoto(for:)` — called only
    ///     on a miss, never for a contact with no photo on file.
    func contactFace(for contact: FamilyContact,
                     diameter: CGFloat,
                     displayScale: CGFloat,
                     resolve: () -> UIImage?) -> UIImage? {
        guard let filename = contact.photoFilename, !filename.isEmpty else { return nil }
        return thumbnail(forKey: "contact:\(filename)",
                         pointSize: diameter,
                         displayScale: displayScale,
                         load: resolve)
    }
}
