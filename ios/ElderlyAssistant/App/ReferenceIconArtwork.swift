import SwiftUI

/// Artwork cropped from the supplied design's icon sheet. Original colours
/// are preserved; theme surfaces and accessible labels belong to the caller.
struct ReferenceIconArtwork: View {
    let name: String
    let diameter: CGFloat

    var body: some View {
        Image("referenceIcon.\(name)")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    static func name(for systemImage: String) -> String? {
        switch systemImage {
        case "phone", "phone.fill": return "phone"
        case "pills", "pills.fill", "pill", "pill.fill": return "medicine"
        case "map", "map.fill", "mappin", "mappin.circle.fill": return "location"
        case "newspaper", "newspaper.fill", "rectangle.stack.fill", "doc.text.fill": return "news"
        case "gear", "gearshape", "gearshape.fill", "camera.viewfinder": return "settings"
        case "text.viewfinder", "character.bubble", "character.bubble.fill", "character.book.closed.fill": return "translate"
        case "clock", "clock.fill": return "clock"
        case "camera", "camera.fill": return "camera"
        case "square.grid.3x3.fill", "circle.grid.3x3.fill": return "more"
        case "cloud.sun", "cloud.sun.fill": return "weather"
        case "calculator", "calculator.fill": return "calculator"
        case "photo", "photo.fill", "photo.on.rectangle": return "photo"
        case "cart", "cart.fill": return "shopping"
        case "house", "house.fill": return "home"
        case "fuelpump", "fuelpump.fill": return "fuel"
        case "fork.knife": return "food"
        case "cross.case", "cross.case.fill", "cross.circle.fill": return "medical"
        case "shield", "shield.fill", "lock.shield.fill": return "shield"
        case "questionmark.circle", "questionmark.circle.fill": return "help"
        default: return nil
        }
    }
}
