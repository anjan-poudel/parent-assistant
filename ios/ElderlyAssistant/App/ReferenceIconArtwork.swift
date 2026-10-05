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
            .interpolation(.high)
            .scaledToFit()
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
