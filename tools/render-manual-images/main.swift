// render-manual-images — programmatic diagram renderer for the in-app
// user manual (user-manual-in-app task, 2026-09-09).
//
// Draws clean, senior-friendly DIAGRAMS (NOT screenshots — they are
// labelled as sketches in-app and watermarked here) for the bundled
// manual's section cards. Pure AppKit/CoreGraphics, no third-party
// dependencies; runs on macOS with the system Swift toolchain:
//
//   swiftc -O tools/render-manual-images/main.swift -o /tmp/render-manual-images
//   /tmp/render-manual-images ios/ElderlyAssistant/Resources/ManualText/images
//
// (The output argument is optional and defaults to the path above,
// resolved relative to the current directory.)
//
// Output: ten 750×500 PNGs mirroring the app's DesignTokens palette
// (cream background, white cards, traffic-light state colors, warm
// amber avatar gradient). Every diagram carries bilingual (en + नेपाली)
// labels because the manual itself is bilingual, and a corner watermark
// stating plainly that it is a sketch, not the real screen.

import AppKit
import CoreGraphics

// MARK: - Palette (mirrors ios/ElderlyAssistant/App/DesignTokens.swift)

enum P {
    static let background = NSColor(red: 0.980, green: 0.953, blue: 0.914, alpha: 1) // #FAF3E9
    static let card = NSColor.white
    static let accent = NSColor(red: 0.165, green: 0.498, blue: 0.384, alpha: 1)     // #2A7F62
    static let textPrimary = NSColor(red: 0.239, green: 0.184, blue: 0.141, alpha: 1) // #3D2F24
    static let textSecondary = NSColor(red: 0.541, green: 0.459, blue: 0.384, alpha: 1) // #8A7562
    static let stateIdle = NSColor(red: 0.231, green: 0.431, blue: 0.647, alpha: 1)   // #3B6EA5
    static let stateListening = NSColor(red: 0.659, green: 0.384, blue: 0.047, alpha: 1) // #A8620C
    static let stateTranscribing = NSColor(red: 0.561, green: 0.322, blue: 0.031, alpha: 1) // #8F5208
    static let stateUnderstanding = NSColor(red: 0.478, green: 0.290, blue: 0.059, alpha: 1) // #7A4A0F
    static let stateSpeaking = NSColor(red: 0.180, green: 0.478, blue: 0.094, alpha: 1)  // #2E7A18
    static let stateError = NSColor(red: 0.753, green: 0.184, blue: 0.165, alpha: 1)    // #C02F2A
    static let stateStopped = NSColor(red: 0.306, green: 0.384, blue: 0.478, alpha: 1)  // #4E627A
    static let warmGlowStart = NSColor(red: 0.965, green: 0.698, blue: 0.365, alpha: 1) // #F6B25E
    static let warmGlowEnd = NSColor(red: 0.851, green: 0.510, blue: 0.180, alpha: 1)   // #D9822E
    static let dockMeds = NSColor(red: 0.165, green: 0.498, blue: 0.384, alpha: 1)
    static let dockReminders = NSColor(red: 0.706, green: 0.392, blue: 0.118, alpha: 1) // #B4641E
    static let dockCall = NSColor(red: 0.761, green: 0.329, blue: 0.122, alpha: 1)      // #C2541F
    static let dockAppliance = NSColor(red: 0.541, green: 0.427, blue: 0.231, alpha: 1) // #8A6D3B
    static let dockDirections = NSColor(red: 0.106, green: 0.522, blue: 0.639, alpha: 1) // #1B85A3
    static let dockFeeds = NSColor(red: 0.557, green: 0.235, blue: 0.435, alpha: 1)     // #8E3C6F
    static let whatsAppGreen = NSColor(red: 0.145, green: 0.827, blue: 0.4, alpha: 1)
    static let userBubble = NSColor(red: 0.902, green: 0.945, blue: 0.925, alpha: 1)
    static let cardLine = NSColor(red: 0.850, green: 0.830, blue: 0.800, alpha: 1)
}

let W: CGFloat = 750
let H: CGFloat = 500

// MARK: - Canvas

final class Canvas {
    let rep: NSBitmapImageRep

    init() {
        rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
        // Flip so we draw with a top-left origin.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: H)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
    }

    func end() {
        NSGraphicsContext.restoreGraphicsState()
    }

    func save(to url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("PNG encode failed for \(url.path)")
        }
        do { try data.write(to: url) } catch { fatalError("write failed: \(error)") }
    }
}

// MARK: - Drawing helpers (top-left origin)

func fill(_ color: NSColor, _ rect: CGRect) {
    color.setFill()
    NSBezierPath(rect: rect).fill()
}

func rounded(_ rect: CGRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil,
             lineWidth: CGFloat = 0, shadow: Bool = false) {
    if shadow {
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.06)
        sh.shadowBlurRadius = 6
        sh.shadowOffset = NSMakeSize(0, -2)
        sh.set()
    }
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func circle(center: CGPoint, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil,
            lineWidth: CGFloat = 0) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                      width: radius * 2, height: radius * 2)
    let path = NSBezierPath(ovalIn: rect)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func ring(center: CGPoint, radius: CGFloat, color: NSColor, lineWidth: CGFloat) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                      width: radius * 2, height: radius * 2)
    let path = NSBezierPath(ovalIn: rect)
    color.setStroke()
    path.lineWidth = lineWidth
    path.stroke()
}

func line(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: from)
    path.line(to: to)
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

func arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat = 3) {
    line(from: from, to: to, color: color, width: width)
    let angle = atan2(to.y - from.y, to.x - from.x)
    let head: CGFloat = 10
    let path = NSBezierPath()
    path.move(to: to)
    path.line(to: CGPoint(x: to.x - head * cos(angle - 0.42), y: to.y - head * sin(angle - 0.42)))
    path.line(to: CGPoint(x: to.x - head * cos(angle + 0.42), y: to.y - head * sin(angle + 0.42)))
    path.close()
    color.setFill()
    path.fill()
}

func attrs(_ size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = P.textPrimary,
           align: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    return [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph]
}

func measure(_ text: String, _ a: [NSAttributedString.Key: Any]) -> CGSize {
    (text as NSString).size(withAttributes: a)
}

func text(_ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = P.textPrimary, align: NSTextAlignment = .left) {
    let a = attrs(size, weight: weight, color: color, align: align)
    (s as NSString).draw(at: p, withAttributes: a)
}

/// Centered text at `center` (x-centered on `cx`, top at `y`).
@discardableResult
func textCentered(_ s: String, cx: CGFloat, y: CGFloat, size: CGFloat,
                  weight: NSFont.Weight = .regular, color: NSColor = P.textPrimary) -> CGFloat {
    let a = attrs(size, weight: weight, color: color, align: .center)
    let sz = measure(s, a)
    let rect = CGRect(x: cx - sz.width / 2, y: y, width: sz.width, height: sz.height)
    (s as NSString).draw(in: rect, withAttributes: a)
    return sz.height
}

/// Bilingual label: English bold on top, Nepali smaller underneath.
/// Returns the y just below the pair.
@discardableResult
func bilingual(en: String, ne: String, cx: CGFloat, y: CGFloat, enSize: CGFloat,
               neSize: CGFloat, color: NSColor = P.textPrimary,
               enWeight: NSFont.Weight = .bold) -> CGFloat {
    let enH = textCentered(en, cx: cx, y: y, size: enSize, weight: enWeight, color: color)
    let neH = textCentered(ne, cx: cx, y: y + enH + 2, size: neSize, weight: .regular,
                           color: P.textSecondary)
    return y + enH + 2 + neH
}

/// The honesty watermark — every diagram declares it is a sketch.
func watermark() {
    let s = "Sketch diagram — not the real screen · स्केच चित्र मात्र, वास्तविक स्क्रिन होइन"
    let a = attrs(11, weight: .regular, color: P.textSecondary.withAlphaComponent(0.75), align: .right)
    let sz = measure(s, a)
    (s as NSString).draw(in: CGRect(x: W - sz.width - 14, y: H - sz.height - 10,
                                    width: sz.width, height: sz.height), withAttributes: a)
}

/// Page title block at the top of a diagram.
@discardableResult
func pageTitle(en: String, ne: String) -> CGFloat {
    let y = textCentered(en, cx: W / 2, y: 18, size: 26, weight: .bold)
    let y2 = textCentered(ne, cx: W / 2, y: y + 4, size: 15, weight: .regular,
                          color: P.textSecondary)
    return y2 + 8
}

func newCanvas() -> Canvas {
    let c = Canvas()
    fill(P.background, CGRect(x: 0, y: 0, width: W, height: H))
    return c
}

// MARK: - Diagram 1 — talk-button-states.png

func drawTalkButtonStates() {
    let c = newCanvas()
    _ = pageTitle(en: "The Talk button — one colour, one meaning",
                  ne: "बोल्ने बटन — हरेक रङको अर्थ")

    struct State { let color: NSColor; let en: String; let ne: String; let meaning: String }
    let states: [State] = [
        State(color: P.stateIdle, en: "Talk", ne: "बोल्नुहोस्", meaning: "REST — ready, tap it · आराम — तयार छ"),
        State(color: P.stateListening, en: "Listening…", ne: "सुन्दै छु…", meaning: "WAIT — it hears you · कुरिरहनुहोस्"),
        State(color: P.stateSpeaking, en: "Speaking", ne: "बोल्दै छु", meaning: "GO — replying · जवाफ दिँदै"),
        State(color: P.stateError, en: "Try again", ne: "फेरि प्रयास", meaning: "STOP — something failed · केही बिग्रियो"),
        State(color: P.stateStopped, en: "Voice off", ne: "आवाज बन्द", meaning: "OFF — tap to restart · थिचेर सुरु गर्नुहोस्"),
    ]
    let radius: CGFloat = 52
    let spacing: CGFloat = 150
    let startX = W / 2 - CGFloat(states.count - 1) / 2 * spacing
    let centerY: CGFloat = 205
    for (i, s) in states.enumerated() {
        let cx = startX + CGFloat(i) * spacing
        // Breathing rings for the resting state, halo for the busy ones.
        if i == 0 {
            ring(center: CGPoint(x: cx, y: centerY), radius: radius + 14, color: P.stateIdle.withAlphaComponent(0.25), lineWidth: 2)
            ring(center: CGPoint(x: cx, y: centerY), radius: radius + 26, color: P.stateIdle.withAlphaComponent(0.12), lineWidth: 2)
        } else {
            ring(center: CGPoint(x: cx, y: centerY), radius: radius + 8, color: s.color.withAlphaComponent(0.28), lineWidth: 7)
        }
        circle(center: CGPoint(x: cx, y: centerY), radius: radius, fill: s.color)
        _ = textCentered(s.en, cx: cx, y: centerY - 16, size: 17, weight: .bold, color: .white)
        _ = textCentered(s.ne, cx: cx, y: centerY + 10, size: 12, weight: .regular,
                         color: NSColor.white.withAlphaComponent(0.92))
        _ = textCentered(s.meaning, cx: cx, y: centerY + radius + 16, size: 11.5, weight: .semibold,
                         color: P.textSecondary)
    }
    // White glyphs keep contrast — note the ≥4.5:1 rule the real app enforces.
    _ = textCentered("White writing on every colour stays easy to read · सेतो अक्षर हरेक रङमा सजिलै पढिन्छ",
                     cx: W / 2, y: centerY + radius + 52, size: 12, weight: .regular, color: P.textSecondary)
    watermark()
    c.end()
    c.save(to: outputURL("talk-button-states.png"))
}

// MARK: - Diagram 2 — home-screen-layout.png

func drawHomeScreenLayout() {
    let c = newCanvas()
    _ = pageTitle(en: "The home screen", ne: "होम स्क्रिन")

    // Phone frame on the left.
    let phone = CGRect(x: 64, y: 34, width: 268, height: 430)
    rounded(phone, radius: 34, fill: P.background, stroke: P.cardLine, lineWidth: 2)

    // Top bar.
    let topY = phone.minY + 16
    circle(center: CGPoint(x: phone.minX + 34, y: topY + 16), radius: 14, fill: P.card, stroke: P.cardLine, lineWidth: 1)
    text("⚙", at: CGPoint(x: phone.minX + 28, y: topY + 11), size: 14)
    textCentered("Good morning, 8:05", cx: phone.midX, y: topY + 14, size: 11, weight: .bold)
    textCentered("शुभ प्रभात", cx: phone.midX, y: topY + 28, size: 9, color: P.textSecondary)
    circle(center: CGPoint(x: phone.maxX - 52, y: topY + 16), radius: 14, fill: P.card, stroke: P.cardLine, lineWidth: 1)
    text("🔔", at: CGPoint(x: phone.maxX - 58, y: topY + 11), size: 14)
    circle(center: CGPoint(x: phone.maxX - 24, y: topY + 16), radius: 14, fill: .white, stroke: P.stateError, lineWidth: 1.5)
    text("!", at: CGPoint(x: phone.maxX - 29, y: topY + 12), size: 13, weight: .bold, color: P.stateError)

    // Quick apps row.
    let qaY = topY + 46
    for i in 0..<4 {
        rounded(CGRect(x: phone.minX + 18 + CGFloat(i) * 60, y: qaY, width: 48, height: 48),
                radius: 12, fill: P.card)
    }
    text("+", at: CGPoint(x: phone.minX + 18 + 3 * 60 + 18, y: qaY + 14), size: 16, weight: .bold, color: P.accent)

    // Talk hero.
    let heroCenter = CGPoint(x: phone.midX, y: qaY + 112)
    ring(center: heroCenter, radius: 66, color: P.stateIdle.withAlphaComponent(0.10), lineWidth: 3)
    ring(center: heroCenter, radius: 50, color: P.stateIdle.withAlphaComponent(0.18), lineWidth: 3)
    circle(center: heroCenter, radius: 40, fill: P.stateIdle)
    _ = textCentered("Talk", cx: heroCenter.x, y: heroCenter.y - 11, size: 15, weight: .bold, color: .white)
    _ = textCentered("बोल्नुहोस्", cx: heroCenter.x, y: heroCenter.y + 7, size: 10, color: NSColor.white.withAlphaComponent(0.92))
    textCentered("I'm ready · तयार छु", cx: phone.midX, y: heroCenter.y + 46, size: 9, color: P.textSecondary)

    // Hint pill.
    let pill = CGRect(x: phone.minX + 24, y: heroCenter.y + 64, width: phone.width - 48, height: 22)
    rounded(pill, radius: 11, fill: P.card)
    textCentered("Try saying… · यसो भन्नुहोस्…", cx: phone.midX, y: pill.minY + 5, size: 9, color: P.textSecondary)

    // Dock.
    let dockRect = CGRect(x: phone.minX + 12, y: phone.maxY - 78, width: phone.width - 24, height: 60)
    rounded(dockRect, radius: 16, fill: NSColor.white.withAlphaComponent(0.75))
    let dockLabels = [("Med.", "औषधि", P.dockMeds), ("Rem.", "सम्झना", P.dockReminders),
                      ("Call", "फोन", P.dockCall), ("Show", "देखाऊ", P.dockAppliance),
                      ("Dir.", "बाटो", P.dockDirections), ("Feeds", "फिड", P.dockFeeds)]
    let slot = dockRect.width / 6
    for (i, item) in dockLabels.enumerated() {
        let cx = dockRect.minX + slot * (CGFloat(i) + 0.5)
        circle(center: CGPoint(x: cx, y: dockRect.minY + 18), radius: 11, fill: item.2)
        _ = textCentered(item.0, cx: cx, y: dockRect.minY + 34, size: 8.5, weight: .semibold)
        _ = textCentered(item.1, cx: cx, y: dockRect.minY + 45, size: 8, color: P.textSecondary)
    }

    // Legend on the right.
    let lx = phone.maxX + 28
    var ly: CGFloat = 64
    let legend: [(String, String)] = [
        ("Top bar — settings, clock, bell, emergency", "माथिको पट्टी — सेटिङ, घडी, घण्टी, आपतकालीन"),
        ("Quick apps — your favourite apps", "द्रुत एपहरू — मनपर्ने एपहरू"),
        ("The Talk button — the traffic light", "बोल्ने बटन — ट्राफिक-लाइट"),
        ("The dock — Medication, Reminders, Call, Show Me, Directions, Feeds",
         "डक — औषधि, सम्झना, फोन, देखाउनुहोस्, बाटो, फिड"),
    ]
    for (i, item) in legend.enumerated() {
        circle(center: CGPoint(x: lx + 12, y: ly + 12), radius: 12, fill: P.accent)
        _ = textCentered("\(i + 1)", cx: lx + 12, y: ly + 7, size: 13, weight: .bold, color: .white)
        let enSz = measure(item.0, attrs(13, weight: .semibold)).width
        _ = textCentered(item.0, cx: lx + 34 + enSz / 2, y: ly + 4, size: 13, weight: .semibold)
        _ = textCentered(item.1, cx: lx + 34 + enSz / 2, y: ly + 20, size: 10.5, color: P.textSecondary)
        ly += 62
    }
    watermark()
    c.end()
    c.save(to: outputURL("home-screen-layout.png"))
}

// MARK: - Diagram 3 — voice-flow-chain.png

func drawVoiceFlowChain() {
    let c = newCanvas()
    _ = pageTitle(en: "One turn, four steps", ne: "एक पालो, चार चरण")

    struct Step { let color: NSColor; let en: String; let ne: String; let note: String }
    let steps: [Step] = [
        Step(color: P.stateListening, en: "Listening", ne: "सुन्दै", note: "you speak · तपाईं बोल्नुहुन्छ"),
        Step(color: P.stateTranscribing, en: "Writing", ne: "लेख्दै", note: "your words appear · शब्द लेखिन्छन्"),
        Step(color: P.stateUnderstanding, en: "Thinking", ne: "बुझ्दै", note: "what did you mean? · के भन्नुभयो?"),
        Step(color: P.stateSpeaking, en: "Speaking", ne: "बोल्दै", note: "the reply · जवाफ"),
    ]
    let boxW: CGFloat = 140
    let boxH: CGFloat = 118
    let gap: CGFloat = 44
    let total = CGFloat(steps.count) * boxW + CGFloat(steps.count - 1) * gap
    var x = (W - total) / 2
    let y: CGFloat = 150
    for (i, s) in steps.enumerated() {
        rounded(CGRect(x: x, y: y, width: boxW, height: boxH), radius: 16, fill: s.color)
        _ = textCentered(s.en, cx: x + boxW / 2, y: y + 22, size: 19, weight: .bold, color: .white)
        _ = textCentered(s.ne, cx: x + boxW / 2, y: y + 48, size: 13, color: NSColor.white.withAlphaComponent(0.92))
        _ = textCentered(s.note, cx: x + boxW / 2, y: y + 68, size: 10.5, color: NSColor.white.withAlphaComponent(0.9))
        if i < steps.count - 1 {
            arrow(from: CGPoint(x: x + boxW + 8, y: y + boxH / 2),
                  to: CGPoint(x: x + boxW + gap - 8, y: y + boxH / 2),
                  color: P.textSecondary)
        }
        x += boxW + gap
    }
    _ = textCentered("Tap, or say the wake phrase, and this happens by itself · बटन थिच्दा वा वेक वाक्य भन्दा यो आफैं हुन्छ",
                     cx: W / 2, y: y + boxH + 22, size: 13, weight: .regular, color: P.textSecondary)
    watermark()
    c.end()
    c.save(to: outputURL("voice-flow-chain.png"))
}

// MARK: - Diagram 4 — updates-screen.png

func drawUpdatesScreen() {
    let c = newCanvas()
    _ = pageTitle(en: "Updates — the bell opens three sections", ne: "अपडेटहरू — घण्टीले तीन खण्ड खोल्छ")

    struct Section { let titleEn: String; let titleNe: String; let icon: String; let rows: [(String, String)] }
    let sections: [Section] = [
        Section(titleEn: "Notifications", titleNe: "सूचनाहरू", icon: "🔔",
                rows: [("Today's briefing", "आजको बिहानको सारांश"),
                       ("Medication status", "औषधिको अवस्था")]),
        Section(titleEn: "Today", titleNe: "आज", icon: "📅",
                rows: [("आइतबार, भदौ २१, २०८३", "पञ्चमी"),
                       ("Next: औषधि at 8:00", "अर्को: ८ बजे औषधि")]),
        Section(titleEn: "Activity", titleNe: "गतिविधि", icon: "📝",
                rows: [("“Set a timer for 5 minutes”", "· 8:02 am"),
                       ("“Timer started for 5 minutes.”", "· 8:02 am")]),
    ]
    let cardW: CGFloat = 220
    let gap: CGFloat = 24
    var x = (W - (cardW * 3 + gap * 2)) / 2
    let y: CGFloat = 90
    for s in sections {
        rounded(CGRect(x: x, y: y, width: cardW, height: 330), radius: 18, fill: P.card, shadow: true)
        _ = textCentered(s.titleEn, cx: x + cardW / 2, y: y + 16, size: 16, weight: .bold)
        _ = textCentered(s.titleNe, cx: x + cardW / 2, y: y + 37, size: 12, color: P.textSecondary)
        var ry = y + 74
        for row in s.rows {
            rounded(CGRect(x: x + 14, y: ry, width: cardW - 28, height: 56), radius: 12,
                    fill: P.background)
            _ = textCentered(row.0, cx: x + cardW / 2, y: ry + 12, size: 11.5, weight: .semibold)
            _ = textCentered(row.1, cx: x + cardW / 2, y: ry + 29, size: 10, color: P.textSecondary)
            ry += 68
        }
        x += cardW + gap
    }
    _ = textCentered("The badge on the bell always matches the Notifications list · घण्टीको चिन्ह सधैं सूचनाको सूचीसँग मिल्छ",
                     cx: W / 2, y: y + 330 + 14, size: 12.5, color: P.textSecondary)
    watermark()
    c.end()
    c.save(to: outputURL("updates-screen.png"))
}

// MARK: - Diagram 5 — confirmation-chips.png

func drawConfirmationChips() {
    let c = newCanvas()
    _ = pageTitle(en: "Sahayak always asks before recording", ne: "सहायकले लेख्नुअघि सधैं सोध्छ")

    let card = CGRect(x: 90, y: 92, width: W - 180, height: 300)
    rounded(card, radius: 20, fill: P.card, shadow: true)
    _ = textCentered("Please confirm", cx: W / 2, y: card.minY + 22, size: 15, weight: .bold,
                     color: P.textSecondary)
    _ = textCentered("Did you take your medicine?", cx: W / 2, y: card.minY + 48, size: 22,
                     weight: .bold)
    _ = textCentered("औषधि खानुभयो?", cx: W / 2, y: card.minY + 78, size: 15,
                     weight: .regular, color: P.textSecondary)

    let chipW: CGFloat = 210
    let chipH: CGFloat = 66
    let chipY = card.minY + 130
    let chipX1 = W / 2 - chipW - 26
    let chipX2 = W / 2 + 26
    rounded(CGRect(x: chipX1, y: chipY, width: chipW, height: chipH), radius: 10,
            fill: P.accent)
    _ = textCentered("Yes · हो", cx: chipX1 + chipW / 2, y: chipY + 20, size: 24,
                     weight: .bold, color: .white)
    rounded(CGRect(x: chipX2, y: chipY, width: chipW, height: chipH), radius: 10,
            fill: P.card, stroke: P.textSecondary, lineWidth: 2)
    _ = textCentered("No · होइन", cx: chipX2 + chipW / 2, y: chipY + 20, size: 24,
                     weight: .bold, color: P.textSecondary)

    _ = textCentered("Answer with your voice, or tap a button · आवाजबाट वा बटन थिचेर जवाफ दिनुहोस्",
                     cx: W / 2, y: chipY + chipH + 18, size: 14, color: P.textSecondary)
    _ = textCentered("A double-dose guard keeps a second “taken” from counting twice · दोहोरो-खुराक रोकथामले दोस्रो “खाएँ” दोहोर्‍याएर गन्दैन",
                     cx: W / 2, y: chipY + chipH + 42, size: 11.5, color: P.textSecondary)
    watermark()
    c.end()
    c.save(to: outputURL("confirmation-chips.png"))
}

// MARK: - Diagram 6 — calendar-card.png

func drawCalendarCard() {
    let c = newCanvas()
    _ = pageTitle(en: "Calendar — today in the Nepali calendar", ne: "पात्रो — नेपाली पात्रोमा आज")

    let card = CGRect(x: 130, y: 92, width: W - 260, height: 310)
    rounded(card, radius: 20, fill: P.card, shadow: true)
    _ = textCentered("आइतबार", cx: W / 2, y: card.minY + 24, size: 16, weight: .semibold,
                     color: P.textSecondary)
    _ = textCentered("भदौ २१, २०८३", cx: W / 2, y: card.minY + 52, size: 44, weight: .bold)
    _ = textCentered("पञ्चमी", cx: W / 2, y: card.minY + 116, size: 22, weight: .bold,
                     color: P.accent)
    _ = textCentered("8 September 2026", cx: W / 2, y: card.minY + 148, size: 14,
                     color: P.textSecondary)

    let fest = CGRect(x: card.minX + 34, y: card.minY + 196, width: card.width - 68, height: 56)
    rounded(fest, radius: 12, fill: P.background)
    _ = textCentered("✦ Haritalika Teej · त्रितिया", cx: W / 2, y: fest.minY + 18, size: 15,
                     weight: .semibold, color: P.textPrimary)

    _ = textCentered("Every day shows its tithi; festivals show their dates · हरेक दिनको तिथि; चाडपर्वको मितिसहित",
                     cx: W / 2, y: card.maxY + 14, size: 13, color: P.textSecondary)
    watermark()
    c.end()
    c.save(to: outputURL("calendar-card.png"))
}

// MARK: - Diagram 7 — phone-screen.png

func drawPhoneScreen() {
    let c = newCanvas()
    _ = pageTitle(en: "The Phone screen — your people, one tap away",
                  ne: "फोन स्क्रिन — तपाईंका मान्छे, एक थिचाइमा")

    let phone = CGRect(x: 80, y: 40, width: 300, height: 410)
    rounded(phone, radius: 30, fill: P.background, stroke: P.cardLine, lineWidth: 2)

    // Family tile.
    let tile = CGRect(x: phone.minX + 16, y: phone.minY + 20, width: phone.width - 32, height: 76)
    rounded(tile, radius: 16, fill: P.card)
    let avatar = CGPoint(x: tile.minX + 38, y: tile.minY + 38)
    // Warm initials gradient (two stacked circles of the two tones).
    circle(center: avatar, radius: 22, fill: P.warmGlowStart)
    circle(center: CGPoint(x: avatar.x, y: avatar.y + 12), radius: 14, fill: P.warmGlowEnd)
    circle(center: avatar, radius: 22, fill: P.warmGlowStart.withAlphaComponent(0.35))
    _ = textCentered("M", cx: avatar.x, y: avatar.y - 9, size: 18, weight: .bold, color: .white)
    text("Maiya", at: CGPoint(x: tile.minX + 70, y: tile.minY + 14), size: 16, weight: .bold)
    text("छोरी · Daughter", at: CGPoint(x: tile.minX + 70, y: tile.minY + 38), size: 11,
         color: P.textSecondary)
    circle(center: CGPoint(x: tile.maxX - 56, y: tile.minY + 38), radius: 16, fill: P.dockCall)
    textCentered("V", cx: tile.maxX - 56, y: tile.minY + 29, size: 15, weight: .bold, color: .white)
    circle(center: CGPoint(x: tile.maxX - 22, y: tile.minY + 38), radius: 16, fill: P.accent)
    textCentered("P", cx: tile.maxX - 22, y: tile.minY + 29, size: 15, weight: .bold, color: .white)

    // Search pill.
    let pill = CGRect(x: phone.minX + 16, y: tile.maxY + 14, width: phone.width - 32, height: 44)
    rounded(pill, radius: 22, fill: P.card)
    textCentered("🔍  Search all contacts", cx: pill.minX + 92, y: pill.minY + 13, size: 12.5,
                 weight: .semibold)
    circle(center: CGPoint(x: pill.maxX - 26, y: pill.minY + 22), radius: 13, fill: P.accent)
    textCentered("🎙", cx: pill.maxX - 26, y: pill.minY + 15, size: 13)

    // Recent activity card.
    let hist = CGRect(x: phone.minX + 16, y: pill.maxY + 14, width: phone.width - 32, height: 54)
    rounded(hist, radius: 16, fill: P.card)
    textCentered("↶  Unanswered call · नउठाएको कल", cx: hist.minX + 108, y: hist.minY + 18,
                 size: 12, weight: .semibold)

    // Legend right.
    let lx = phone.maxX + 26
    let legend: [(String, String)] = [
        ("Family & friends — photo, video call, audio call", "परिवार र साथीहरू — फोटो, भिडियो कल, अडियो कल"),
        ("Search the whole phone book (or speak a name)", "पूरा फोन-बुक खोज्नुहोस् (वा नाम बोल्नुहोस्)"),
        ("Recent activity — tap to call again", "हालसालैको गतिविधि — थिचेर फेरि फोन"),
        ("Missed calls are anonymous — the row opens the Phone app", "छुटेका कल अज्ञात — पङ्क्तिले फोन एप खोल्छ"),
    ]
    var ly: CGFloat = 66
    for (i, item) in legend.enumerated() {
        circle(center: CGPoint(x: lx + 12, y: ly + 12), radius: 12, fill: P.accent)
        _ = textCentered("\(i + 1)", cx: lx + 12, y: ly + 7, size: 13, weight: .bold, color: .white)
        let sz = measure(item.0, attrs(12.5, weight: .semibold)).width
        let maxW = W - (lx + 40) - 20
        let a = attrs(12.5, weight: .semibold)
        var en = item.0
        while measure(en, a).width > maxW && en.contains(" ") {
            en = String(en.dropLast())
        }
        _ = textCentered(en, cx: lx + 34 + min(sz, maxW) / 2, y: ly + 4, size: 12.5, weight: .semibold)
        _ = textCentered(item.1, cx: lx + 34 + min(sz, maxW) / 2, y: ly + 22, size: 10, color: P.textSecondary)
        ly += 76
    }
    watermark()
    c.end()
    c.save(to: outputURL("phone-screen.png"))
}

// MARK: - Diagram 8 — feed-cards.png

func drawFeedCards() {
    let c = newCanvas()
    _ = pageTitle(en: "Feeds — one card, one action", ne: "फिड — एउटा कार्ड, एउटा काम")

    let cardW: CGFloat = 210
    let gap: CGFloat = 30
    var x = (W - (cardW * 3 + gap * 2)) / 2
    let y: CGFloat = 96
    let cardH: CGFloat = 300

    // Text card.
    rounded(CGRect(x: x, y: y, width: cardW, height: cardH), radius: 16, fill: P.card, shadow: true)
    _ = textCentered("Text · लेख", cx: x + cardW / 2, y: y + 12, size: 13, weight: .bold, color: P.textSecondary)
    for i in 0..<3 {
        let barW = cardW - 60 - CGFloat(i * 12)
        rounded(CGRect(x: x + 24, y: y + 42 + CGFloat(i) * 22, width: barW, height: 12),
                radius: 6, fill: P.userBubble)
    }
    let pillW: CGFloat = 120
    rounded(CGRect(x: x + cardW / 2 - pillW / 2, y: y + cardH - 62, width: pillW, height: 38),
            radius: 19, fill: P.accent)
    _ = textCentered("Read aloud", cx: x + cardW / 2, y: y + cardH - 51, size: 12.5,
                     weight: .bold, color: .white)
    x += cardW + gap

    // Image card.
    rounded(CGRect(x: x, y: y, width: cardW, height: cardH), radius: 16, fill: P.card, shadow: true)
    _ = textCentered("Picture · तस्बिर", cx: x + cardW / 2, y: y + 12, size: 13, weight: .bold, color: P.textSecondary)
    let imgRect = CGRect(x: x + 16, y: y + 40, width: cardW - 32, height: 140)
    rounded(imgRect, radius: 12, fill: P.background)
    // Simple mountain glyph.
    let tri = NSBezierPath()
    tri.move(to: CGPoint(x: imgRect.minX + 30, y: imgRect.maxY - 16))
    tri.line(to: CGPoint(x: imgRect.midX, y: imgRect.minY + 22))
    tri.line(to: CGPoint(x: imgRect.maxX - 30, y: imgRect.maxY - 16))
    tri.close()
    P.accent.withAlphaComponent(0.65).setFill()
    tri.fill()
    circle(center: CGPoint(x: imgRect.maxX - 42, y: imgRect.minY + 34), radius: 12,
           fill: P.warmGlowStart)
    rounded(CGRect(x: x + 24, y: imgRect.maxY + 16, width: cardW - 70, height: 12),
            radius: 6, fill: P.userBubble)
    _ = textCentered("The photo is the content · तस्बिर नै कुरा हो", cx: x + cardW / 2,
                     y: y + cardH - 48, size: 10.5, color: P.textSecondary)
    x += cardW + gap

    // Video card.
    rounded(CGRect(x: x, y: y, width: cardW, height: cardH), radius: 16, fill: P.card, shadow: true)
    _ = textCentered("Video · भिडियो", cx: x + cardW / 2, y: y + 12, size: 13, weight: .bold, color: P.textSecondary)
    let stage = CGRect(x: x + 16, y: y + 40, width: cardW - 32, height: 140)
    rounded(stage, radius: 12, fill: NSColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1))
    let play = NSBezierPath()
    let pc = CGPoint(x: stage.midX, y: stage.midY)
    play.move(to: CGPoint(x: pc.x - 14, y: pc.y - 20))
    play.line(to: CGPoint(x: pc.x - 14, y: pc.y + 20))
    play.line(to: CGPoint(x: pc.x + 22, y: pc.y))
    play.close()
    NSColor.white.withAlphaComponent(0.9).setFill()
    play.fill()
    let pill2W: CGFloat = 90
    rounded(CGRect(x: x + cardW / 2 - pill2W / 2, y: y + cardH - 62, width: pill2W, height: 38),
            radius: 19, fill: P.accent)
    _ = textCentered("Play", cx: x + cardW / 2, y: y + cardH - 51, size: 12.5, weight: .bold, color: .white)

    _ = textCentered("Nothing ever plays by itself — the tap is your consent · केही आफैं चल्दैन — तपाईंको थिचाइ नै स्वीकृति हो",
                     cx: W / 2, y: y + cardH + 18, size: 13, color: P.textSecondary)
    watermark()
    c.end()
    c.save(to: outputURL("feed-cards.png"))
}

// MARK: - Diagram 9 — show-me-camera.png

func drawShowMeCamera() {
    let c = newCanvas()
    _ = pageTitle(en: "Show Me — photograph the appliance", ne: "देखाउनुहोस् — उपकरणको फोटो खिच्नुहोस्")

    let frame = CGRect(x: 130, y: 84, width: 490, height: 300)
    rounded(frame, radius: 20, fill: NSColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1))
    // Corner brackets.
    let bw: CGFloat = 34, bt: CGFloat = 7
    for (bx, by, xs, ys) in [(frame.minX, frame.minY, 1, 1), (frame.maxX, frame.minY, -1, 1),
                             (frame.minX, frame.maxY, 1, -1), (frame.maxX, frame.maxY, -1, -1)] {
        fill(.white, CGRect(x: bx + (xs > 0 ? 0 : -bw), y: by + (ys > 0 ? 0 : -bt), width: bw, height: bt))
        fill(.white, CGRect(x: bx + (xs > 0 ? 0 : -bt), y: by + (ys > 0 ? 0 : -bw), width: bt, height: bw))
    }
    // Washing machine glyph.
    let machine = CGRect(x: frame.midX - 62, y: frame.midY - 78, width: 124, height: 150)
    rounded(machine, radius: 12, fill: NSColor.white.withAlphaComponent(0.92))
    circle(center: CGPoint(x: machine.midX, y: machine.minY + 42), radius: 26,
           fill: NSColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1),
           stroke: NSColor(red: 0.62, green: 0.65, blue: 0.70, alpha: 1), lineWidth: 5)
    circle(center: CGPoint(x: machine.midX - 26, y: machine.maxY - 24), radius: 7,
           fill: NSColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 1))
    circle(center: CGPoint(x: machine.midX + 26, y: machine.maxY - 24), radius: 7,
           fill: NSColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 1))

    _ = textCentered("Take a clear photo of the appliance or its buttons · उपकरण वा बटनहरूको सफा फोटो खिच्नुहोस्",
                     cx: W / 2, y: frame.maxY + 16, size: 14, color: P.textSecondary)
    let action = CGRect(x: W / 2 - 110, y: frame.maxY + 40, width: 220, height: 46)
    rounded(action, radius: 23, fill: P.accent)
    _ = textCentered("Take a photo · फोटो खिच्नुहोस्", cx: W / 2, y: action.minY + 13,
                     size: 15, weight: .bold, color: .white)
    watermark()
    c.end()
    c.save(to: outputURL("show-me-camera.png"))
}

// MARK: - Diagram 10 — alarms-timers.png

func drawAlarmsTimers() {
    let c = newCanvas()
    _ = pageTitle(en: "Alarms & timers — voice first, list here", ne: "अलार्म र टाइमर — आवाजले राख्ने, सूची यहाँ")

    let cardW: CGFloat = 320
    let x1: CGFloat = 46
    let x2 = W - 46 - cardW
    let y: CGFloat = 96
    let cardH: CGFloat = 230

    // Alarm card.
    rounded(CGRect(x: x1, y: y, width: cardW, height: cardH), radius: 18, fill: P.card, shadow: true)
    _ = textCentered("Alarm · अलार्म", cx: x1 + cardW / 2, y: y + 14, size: 14, weight: .bold, color: P.textSecondary)
    let alarmIcon = CGPoint(x: x1 + 44, y: y + 66)
    circle(center: alarmIcon, radius: 20, fill: P.accent)
    // Alarm bells.
    line(from: CGPoint(x: alarmIcon.x - 12, y: alarmIcon.y + 8), to: CGPoint(x: alarmIcon.x - 14, y: alarmIcon.y - 2), color: .white, width: 3)
    line(from: CGPoint(x: alarmIcon.x + 12, y: alarmIcon.y + 8), to: CGPoint(x: alarmIcon.x + 14, y: alarmIcon.y - 2), color: .white, width: 3)
    text("6:00 AM", at: CGPoint(x: x1 + 80, y: y + 46), size: 24, weight: .bold)
    text("बिहान ६:०० · yoga", at: CGPoint(x: x1 + 80, y: y + 80), size: 12, color: P.textSecondary)
    // Toggle (on).
    let toggle = CGRect(x: x1 + cardW - 76, y: y + 44, width: 52, height: 28)
    rounded(toggle, radius: 14, fill: P.accent)
    circle(center: CGPoint(x: toggle.maxX - 15, y: toggle.midY), radius: 11, fill: .white)
    text("✕", at: CGPoint(x: x1 + cardW - 104, y: y + 48), size: 16, weight: .bold, color: P.stateError)
    _ = textCentered("Rings daily · दिनहुँ बज्छ", cx: x1 + cardW / 2, y: y + 118, size: 12, color: P.textSecondary)
    _ = textCentered("“Alarm set for 6 in the morning.”", cx: x1 + cardW / 2, y: y + 142, size: 12.5,
                     weight: .semibold, color: P.accent)

    // Timer card.
    rounded(CGRect(x: x2, y: y, width: cardW, height: cardH), radius: 18, fill: P.card, shadow: true)
    _ = textCentered("Timer · टाइमर", cx: x2 + cardW / 2, y: y + 14, size: 14, weight: .bold, color: P.textSecondary)
    let timerIcon = CGPoint(x: x2 + 44, y: y + 66)
    circle(center: timerIcon, radius: 20, fill: P.dockReminders, stroke: .white, lineWidth: 4)
    line(from: CGPoint(x: timerIcon.x, y: timerIcon.y + 8), to: CGPoint(x: timerIcon.x, y: timerIcon.y + 1), color: .white, width: 3)
    line(from: CGPoint(x: timerIcon.x, y: timerIcon.y), to: CGPoint(x: timerIcon.x + 9, y: timerIcon.y), color: .white, width: 3)
    text("4:59", at: CGPoint(x: x2 + 80, y: y + 46), size: 24, weight: .bold)
    text("चिया · Tea", at: CGPoint(x: x2 + 80, y: y + 80), size: 12, color: P.textSecondary)
    circle(center: CGPoint(x: x2 + cardW - 44, y: y + 58), radius: 14, fill: P.stateError.withAlphaComponent(0.15))
    text("✕", at: CGPoint(x: x2 + cardW - 50, y: y + 49), size: 15, weight: .bold, color: P.stateError)
    _ = textCentered("Counts down every second · सेकेन्ड-सेकेन्ड घट्छ", cx: x2 + cardW / 2, y: y + 118, size: 12, color: P.textSecondary)
    _ = textCentered("“Timer finished.”", cx: x2 + cardW / 2, y: y + 142, size: 12.5, weight: .semibold, color: P.accent)

    _ = textCentered("Honest note: alarms ring through this app's notifications — iPhone doesn't let apps set the Clock app's alarms · इमानदारी: अलार्म यस एपकै सूचनाबाट बज्छ — आईफोनले Clock एपमा लेख्न दिँदैन",
                     cx: W / 2, y: y + cardH + 18, size: 12.5, color: P.textSecondary)
    watermark()
    c.end()
    c.save(to: outputURL("alarms-timers.png"))
}

// MARK: - Output

var outputDirectory: URL!

func outputURL(_ name: String) -> URL {
    outputDirectory.appendingPathComponent(name)
}

func main() {
    let arg = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "ios/ElderlyAssistant/Resources/ManualText/images"
    outputDirectory = URL(fileURLWithPath: arg)
    try? FileManager.default.createDirectory(at: outputDirectory,
                                             withIntermediateDirectories: true)

    let renderers: [(String, () -> Void)] = [
        ("talk-button-states.png", drawTalkButtonStates),
        ("home-screen-layout.png", drawHomeScreenLayout),
        ("voice-flow-chain.png", drawVoiceFlowChain),
        ("updates-screen.png", drawUpdatesScreen),
        ("confirmation-chips.png", drawConfirmationChips),
        ("calendar-card.png", drawCalendarCard),
        ("phone-screen.png", drawPhoneScreen),
        ("feed-cards.png", drawFeedCards),
        ("show-me-camera.png", drawShowMeCamera),
        ("alarms-timers.png", drawAlarmsTimers),
    ]
    for (name, render) in renderers {
        render()
        print("✓ \(name)")
    }
    print("Done — \(renderers.count) diagrams written to \(outputDirectory.path)")
}

main()
