// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI
import UIKit

public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor

public extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

public extension PlatformImage {
    var tonearmCGImage: CGImage? {
        cgImage
    }

    var platformScale: CGFloat {
        scale
    }
}

public extension View {
    @ViewBuilder
    func compactNavigationTitle() -> some View {
        self.navigationBarTitleDisplayMode(.inline)
    }

    /// Native large navigation title.
    @ViewBuilder
    func largeNavigationTitle() -> some View {
        self.navigationBarTitleDisplayMode(.large)
    }

    /// Hides the navigation bar only when `condition` holds, so an embedded
    /// child never suppresses its parent's native chrome.
    /// Uses a stable modifier (not an if/else branch) so toggling never changes the view's
    /// structural identity — otherwise a focused child field is torn down and loses focus.
    func hiddenNavigationBar(when condition: Bool) -> some View {
        self.toolbar(condition ? .hidden : .automatic, for: .navigationBar)
    }

    /// These screens draw their own header, so the navigation bar is hidden.
    @ViewBuilder
    func hiddenNavigationBar() -> some View {
        self.toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    func platformAutocapitalization(_ autocapitalization: PlatformAutocapitalization) -> some View {
        self.textInputAutocapitalization(autocapitalization.uiKit)
    }
}

public enum PlatformAutocapitalization {
    case never, words, sentences, characters

    var uiKit: TextInputAutocapitalization {
        switch self {
        case .never: return .never
        case .words: return .words
        case .sentences: return .sentences
        case .characters: return .characters
        }
    }
}
