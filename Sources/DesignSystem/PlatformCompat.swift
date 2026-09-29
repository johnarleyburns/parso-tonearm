import SwiftUI
import UIKit

public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor

public extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}

public extension PlatformImage {
    var tonearmCGImage: CGImage? { cgImage }
    var platformScale: CGFloat { scale }
}

public extension View {
    func compactNavigationTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }

    func platformAutocapitalization(_ autocapitalization: PlatformAutocapitalization) -> some View {
        textInputAutocapitalization(autocapitalization.uiKit)
    }
}

public enum PlatformAutocapitalization {
    case never, words, sentences, characters

    var uiKit: TextInputAutocapitalization {
        switch self {
        case .never: .never
        case .words: .words
        case .sentences: .sentences
        case .characters: .characters
        }
    }
}
