import SwiftUI

struct ArtworkView: View {
    var image: UIImage?
    var seed: String
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(gradient)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var gradient: LinearGradient {
        var hasher = Hasher()
        hasher.combine(seed)
        let h = abs(hasher.finalize())
        let hue = Double(h % 360) / 360.0
        let base = Color(hue: hue, saturation: 0.45, brightness: 0.42)
        let dark = Color(hue: hue, saturation: 0.55, brightness: 0.14)
        return LinearGradient(colors: [base, dark], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
