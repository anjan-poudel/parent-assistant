import SwiftUI
import UIKit
// [RESPONSIVENESS] (2026-10-14) `CGImageSourceCreateThumbnailAtIndex` —
// the ImageIO decode path `downsampled(from:maxPixelEdge:)` uses.
import ImageIO

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
    private static var longWeekdaySymbolLists: [String: [String]] = [:]

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

    /// The locale's FULL weekday names, indexed from Sunday ("Tuesday") —
    /// the lookup the Events leaf's weekly-recurrence line
    /// (`events.repeats.weekly`) needs. The long list, not
    /// `shortWeekdaySymbols`: the composition promises the word, and
    /// swapping in the short form would change visible copy.
    ///
    /// [RESPONSIVENESS] (2026-10-14) EventsView's `weekdayName` used to
    /// allocate a fresh `DateFormatter` per weekly-recurrence row per
    /// body pass — this cache is the same fix `shortWeekdaySymbols`
    /// already carries. Built inside ONE critical section with its own
    /// formatter for the same non-recursive-lock reason as the short
    /// variant.
    static func longWeekdaySymbols(locale: Locale) -> [String] {
        let key = cacheKey(for: locale)
        lock.lock()
        defer { lock.unlock() }
        if let cached = longWeekdaySymbolLists[key] { return cached }
        let symbols = makeFormatter(locale: locale) {
            $0.dateStyle = .short
            $0.timeStyle = .none
        }.weekdaySymbols ?? []
        longWeekdaySymbolLists[key] = symbols
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
///
/// ## Face key families and the invalidation contract (T-157)
///
/// Curated-contact faces enter under one of two key families, chosen so
/// the two sources can never collide (design-l1 §10.1, design-l2 §1.9):
///
/// - `"contact:<filename>"` — an APP-LOCAL stored thumbnail. The file
///   name is the version: replacing or clearing a contact's photo
///   changes the name, so the new photo is a cache MISS, never a stale
///   serve.
/// - `"sysphoto:<identifier>:<token>"` — a SYSTEM photo from the linked
///   address-book record, where `<token>` is the 16-hex sha256 prefix
///   of the resolved bytes. The token is the bytes' version: new bytes
///   (an external edit, picked up on the next foreground refresh) hash
///   differently, so the key changes and the old entry is simply never
///   asked for again.
///
/// The `faceEpoch` counter deliberately does NOT appear in these keys:
/// it exists to re-trigger RESOLUTION (via the coordinator's face
/// identity, which callers pass as `.task(id:)`), while cache validity
/// is decided by content — an epoch bump whose re-resolve reads the
/// same bytes must hit the cache, not duplicate it. No invalidation API
/// is needed: entries are derivable, bounded (count + decoded-byte
/// cost) and safe to evict at any moment.
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

    /// `data` decoded DIRECTLY at the target size via ImageIO — the path
    /// for bytes that may be tens of megapixels (a picked camera-roll
    /// photo). `UIImage(data:)` decodes the FULL bitmap first (a 48 MP
    /// photo is ~190 MB resident at the decode peak) and only then can
    /// `downsampled(_:maxPixelEdge:)` shrink it; ImageIO's thumbnail
    /// path never materializes the full-size bitmap, so both the decode
    /// cost and the peak memory collapse to the size actually kept.
    ///
    /// [RESPONSIVENESS] (2026-10-14) The other half of the win is where
    /// this runs: it is a pure function of `data`, so callers run it on
    /// a background task (`Task.detached`) and the main thread never
    /// pays the decode of an image it is about to throw away.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` bakes the EXIF
    /// orientation into the pixels (what drawing the old path produced,
    /// so the visible result is identical); ImageIO never upscales, so
    /// an image already within `maxPixelEdge` comes back at native size
    /// — the same never-upscale rule as `downsampled(_:maxPixelEdge:)`.
    /// Returns nil for undecodable bytes; callers treat that as "no
    /// photo", exactly like the old `UIImage(data:)` guard.
    static func downsampled(from data: Data, maxPixelEdge: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode during creation, not lazily on first draw — the
            // first draw happens on the main thread, the creation here
            // does not.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelEdge.rounded(.up)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

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
    /// This is the APP-LOCAL (`contact:<filename>`) branch of the
    /// coordinator's face path; a system-photo face enters through
    /// `thumbnail(forKey:)` under the `sysphoto:` family instead (see
    /// the class doc's key-family note).
    ///
    /// - Parameters:
    ///   - diameter: the circle's width in points.
    ///   - resolve: the app-local file read
    ///     (`ContactPhotoStore.load(named:)` via the coordinator's
    ///     `faceThumbnail(for:diameter:displayScale:)`) — called only
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
